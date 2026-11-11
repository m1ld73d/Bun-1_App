#include <Arduino.h>
#include <Wire.h>
#include <SPI.h>
#include <LoRa.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <NimBLEDevice.h>
#include <Preferences.h>

// ---------- Piny ----------
#define PIN_OLED_SDA 4
#define PIN_OLED_SCL 15
#define PIN_OLED_RST 16
#define PIN_LORA_SCK 5
#define PIN_LORA_MISO 19
#define PIN_LORA_MOSI 27
#define PIN_LORA_SS 18
#define PIN_LORA_RST 14
#define PIN_LORA_DI0 26
#define LORA_FREQUENCY 866E6
#define MAX_MSG_LEN 100
#define MAX_NAME_LEN 20

// Linia sterujaca z aplikacji zaczyna sie od 0x01 (zwykle wiadomosci nie).
//   app -> ESP: <0x01>NAME|<nowa nazwa>
//   ESP -> app: NAME|<nazwa>   (zapisano)   /   NAMEERR|<powod>
#define CMD_PREFIX '\x01'

// ---------- BLE: Nordic UART Service ----------
#define NUS_SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // app -> ESP
#define NUS_TX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // ESP -> app

Adafruit_SSD1306 display(128, 64, &Wire, PIN_OLED_RST);

NimBLECharacteristic* txChar = nullptr;
volatile bool bleConnected = false;
volatile uint16_t bleChunk = 20;  // MTU - 3

String rxBuf = "";                // bajty odebrane z BLE
SemaphoreHandle_t rxLock;

Preferences prefs;                // NVS (pamiec nieulotna)
String boardName;

String lastTx = "-";
String lastRx = "-";
int lastRssi = 0;
bool screenDirty = true;

// ---------- Callbacki BLE ----------
class ServerCB : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
    bleChunk = 20;
    bleConnected = true;
    screenDirty = true;
  }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    bleConnected = false;
    screenDirty = true;
    NimBLEDevice::startAdvertising();
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override {
    bleChunk = mtu > 23 ? mtu - 3 : 20;
  }
};

class RxCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    auto v = c->getValue();
    xSemaphoreTake(rxLock, portMAX_DELAY);
    for (size_t i = 0; i < v.size(); i++) rxBuf += (char)v.data()[i];
    xSemaphoreGive(rxLock);
  }
};

void bleBegin(const char* name) {
  NimBLEDevice::init(name);
  NimBLEDevice::setMTU(247);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCB());

  NimBLEService* svc = server->createService(NUS_SERVICE_UUID);
  txChar = svc->createCharacteristic(NUS_TX_UUID, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* rxChar = svc->createCharacteristic(
      NUS_RX_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rxChar->setCallbacks(new RxCB());

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE_UUID);
  adv->enableScanResponse(true);
  adv->setName(name);
  adv->start();
}

// ---------- Nazwa plytki (NVS) ----------
bool nameValid(const String& n) {
  if (n.length() < 1 || n.length() > MAX_NAME_LEN) return false;
  for (size_t i = 0; i < n.length(); i++) {
    char c = n[i];
    if (c < 0x20 || c > 0x7E || c == '|') return false;
  }
  return true;
}

String defaultName() {
  uint32_t id = (uint32_t)(ESP.getEfuseMac() >> 24) & 0xFFFF;
  return "LoRaNode-" + String(id, HEX);
}

void loadName() {
  prefs.begin("bun1", true);
  boardName = prefs.getString("name", "");
  prefs.end();
  if (!nameValid(boardName)) boardName = defaultName();
}

// Zapisuje nazwe w NVS i odswieza reklamowana nazwe BLE.
// Nowa nazwa jest widoczna w skanie po rozlaczeniu (podczas polaczenia
// reklamowanie jest zatrzymane i startuje ponownie w onDisconnect).
void applyName(const String& n) {
  boardName = n;
  prefs.begin("bun1", false);
  prefs.putString("name", boardName);
  prefs.end();

  NimBLEDevice::setDeviceName(boardName.c_str());
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(boardName.c_str());
  if (adv->isAdvertising()) {
    adv->stop();
    adv->start();
  }
  screenDirty = true;
  Serial.println("Nowa nazwa: " + boardName);
}


// Wysyła linię do aplikacji w kawałkach <= MTU-3
void bleSendLine(const String& s) {
  if (!bleConnected || !txChar) return;
  String line = s + "\n";
  size_t pos = 0;
  while (pos < line.length() && bleConnected) {
    size_t n = min((size_t)bleChunk, line.length() - pos);
    txChar->setValue((const uint8_t*)line.c_str() + pos, n);
    txChar->notify();
    pos += n;
    delay(10);
  }
}

// Zwraca jedną kompletną linię z bufora (lub "")
String bleReadLine() {
  String line = "";
  xSemaphoreTake(rxLock, portMAX_DELAY);
  int idx = rxBuf.indexOf('\n');
  if (idx >= 0) {
    line = rxBuf.substring(0, idx);
    rxBuf.remove(0, idx + 1);
    line.trim();
  }
  xSemaphoreGive(rxLock);
  return line;
}

void handleCommand(String cmd) {
  // cmd bez znaku CMD_PREFIX
  if (cmd.startsWith("NAME|")) {
    String n = cmd.substring(5);
    n.trim();
    if (!nameValid(n)) {
      bleSendLine("NAMEERR|invalid");
      return;
    }
    applyName(n);
    bleSendLine("NAME|" + boardName);
  }
}

// ---------- OLED ----------
void drawScreen() {
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(boardName.substring(0, 21));
  display.println(bleConnected ? "BLE: polaczono" : "BLE: czekam...");
  display.println("---------------------");
  display.println("TX:");
  display.println(lastTx.substring(0, 21));
  display.print("RX (");
  display.print(lastRssi);
  display.println(" dBm):");
  display.println(lastRx.substring(0, 21));
  display.display();
  screenDirty = false;
}

// ---------- LoRa ----------
void loraSend(const String& msg) {
  LoRa.beginPacket();
  LoRa.print(msg);
  LoRa.endPacket();
  lastTx = msg;
  screenDirty = true;
  Serial.println("LoRa TX: " + msg);
}

void loraReceive() {
  int size = LoRa.parsePacket();
  if (!size) return;
  String msg = "";
  while (LoRa.available()) msg += (char)LoRa.read();
  msg.replace("\n", " ");
  lastRx = msg;
  lastRssi = LoRa.packetRssi();
  screenDirty = true;
  Serial.println("LoRa RX: " + msg);
  bleSendLine("RX|" + String(lastRssi) + "|" + msg);
}

// ---------- setup / loop ----------
void setup() {
  Serial.begin(115200);
  rxLock = xSemaphoreCreateMutex();

  // OLED
  pinMode(PIN_OLED_RST, OUTPUT);
  digitalWrite(PIN_OLED_RST, LOW);
  delay(20);
  digitalWrite(PIN_OLED_RST, HIGH);
  Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3c, false, false);
  display.setTextSize(1);
  display.setTextColor(WHITE);

  // LoRa
  SPI.begin(PIN_LORA_SCK, PIN_LORA_MISO, PIN_LORA_MOSI, PIN_LORA_SS);
  LoRa.setPins(PIN_LORA_SS, PIN_LORA_RST, PIN_LORA_DI0);
  if (!LoRa.begin(LORA_FREQUENCY)) {
    Serial.println("LoRa init failed!");
    display.clearDisplay();
    display.setCursor(0, 0);
    display.println("LoRa init failed!");
    display.display();
    while (true) delay(1000);
  }

  // BLE
  loadName();
  bleBegin(boardName.c_str());
  Serial.println("BLE: " + boardName);
}

void loop() {
  // wiadomość z aplikacji -> LoRa
  String line = bleReadLine();
  if (line.length() > 0 && line[0] == CMD_PREFIX) {
    handleCommand(line.substring(1));
  } else if (line.length() > 0) {
    if (line.length() > MAX_MSG_LEN) line = line.substring(0, MAX_MSG_LEN);
    loraSend(line);
  }

  // wiadomość z LoRa -> aplikacja
  loraReceive();

  if (screenDirty) drawScreen();
}