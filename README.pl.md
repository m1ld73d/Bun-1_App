# Bun-1 App

[![en](https://img.shields.io/badge/lang-en-blue)](https://github.com/m1ld73d/Bun-1_App/blob/main/README.md)
[![pl](https://img.shields.io/badge/lang-PL-red)](https://github.com/m1ld73d/Bun-1_App/blob/main/README.pl.md)

Aplikacja czatu do płytek ESP32 LoRa, sterowana przez Bluetooth Low Energy.

To następca projektu [Bun-1 Communicator](https://github.com/kielbassa/Bun-1_Communicator).


Projekt składa się z dwóch części:
- `firmware/` - firmware ESP32 (PlatformIO), który przekazuje tekst między telefonem (BLE) a radiem LoRa
- aplikacja Flutter (`lib/`) z czatem, zarządzaniem płytkami, kontami i szyfrowaniem

Wykorzystuje:
- radio LoRa do bezprzewodowej komunikacji między płytkami
- Bluetooth Low Energy (Nordic UART Service) między telefonem a płytką
- wyświetlacz OLED do nazwy płytki, statusu połączenia oraz ostatnio wysłanego i odebranego pakietu
- szyfrowanie AES-256 i X25519 wykonywane w aplikacji
- pamięć nieulotną (NVS) na płytce do zapisania nazwy urządzenia

## Funkcje

- ekran czatu z historią wiadomości dla każdej płytki (przechowywaną, dopóki aplikacja działa)
- kilka zapisanych płytek, z których jedna jest aktywna; aplikacja łączy się z nią ponownie
- skanowanie pobliskich płytek i dodawanie ich z poziomu aplikacji
- zmiana nazwy płytki z aplikacji (nazwa jest zapisywana w pamięci flash płytki)
- szyfrowanie w aplikacji, a płytka tylko przekazuje tekst:
  - tryb **everyone**: AES-256-CBC ze wspólnym kluczem ustawianym w Settings (zgodny z Bun-1 Communicator)
  - tryb **kontaktów**: osobny klucz dla każdej pary użytkowników (wymiana kluczy X25519 + AES-GCM)
- konta użytkowników: nazwa i para kluczy tworzone przy pierwszym uruchomieniu
- parowanie z innymi użytkownikami przez LoRa, potwierdzane 4-cyfrowym kodem
- nazwa nadawcy nad każdą wiadomością od kontaktu
- opcjonalne wyświetlanie wiadomości, których nie udało się odszyfrować

## Sprzęt

Zalecana płytka (bez zmian):
- `ttgo-lora32-v1`

Piny skonfigurowane w kodzie:
- OLED / I2C: `SDA=4`, `SCL=15`, `RST=16`
- LoRa: `SCK=5`, `MISO=19`, `MOSI=27`, `SS=18`, `RST=14`, `DIO0=26`
- Częstotliwość LoRa: `866 MHz`
- Przycisk `GPIO0` nie jest używany przez firmware (to tylko przycisk BOOT potrzebny przy wgrywaniu)

## Oprogramowanie

### Firmware

Zbudowany przy pomocy PlatformIO, używając pliku `firmware/platformio.ini`.

Zależności:
- `sandeepmistry/LoRa@^0.8.0`
- `adafruit/Adafruit SSD1306@^2.5.9`
- `adafruit/Adafruit GFX Library@^1.11.9`
- `h2zero/NimBLE-Arduino@^2.1.0`

### Aplikacja

Zbudowana we Flutterze (Dart `^3.13.7`).

Zależności:
- `flutter_blue_plus` - Bluetooth Low Energy
- `permission_handler` - uprawnienia Bluetooth
- `shared_preferences` - zapisane płytki, klucz, konto i ustawienia
- `pointycastle` - AES-256-CBC dla trybu wspólnego klucza
- `cryptography` - X25519, HKDF i AES-GCM dla kont

Wymagania do zbudowania na Androidzie:
- Flutter SDK (stable) i Android Studio z wtyczką Flutter
- Android SDK Platform 37 (`compileSdk = 37`)
- JDK 17
- telefon z Bluetooth Low Energy (uprawnienia do skanowania i łączenia Bluetooth są proszone przy pierwszym użyciu)

## Obsługa

1. Zbuduj i wgraj firmware za pomocą PlatformIO (z folderu `firmware`):
   ```bash
   pio run
   pio run -t upload
   ```
   Jeśli wgrywanie zawiesza się na `Connecting...`, przytrzymaj przycisk BOOT na płytce.
2. Zbuduj i uruchom aplikację (z głównego folderu projektu):
   ```bash
   flutter pub get
   flutter run --release
   ```
   Żeby dostać plik do instalacji: `flutter build apk --release`. Wynik jest w `build/app/outputs/flutter-apk/`.
3. Płytka pokazuje na OLED swoją nazwę (domyślnie `LoRaNode-xxxx`) oraz `BLE: czekam...`, dopóki telefon się nie połączy.
4. W aplikacji wejdź w **Settings** i wybierz **+ add new board**. Zeskanuj, dotknij swojej płytki, aby ją dodać, a potem wybierz ją na liście **// my boards**, aby się połączyć.

### Wysyłanie i odbieranie wiadomości

- Wpisz wiadomość na dole głównego ekranu i wyślij. Pole działa tylko wtedy, gdy płytka jest połączona.
- Nad polem przycisk **to:** wybiera adresata: **everyone (shared key)** albo jeden z kontaktów.
- Odebrane wiadomości pojawiają się w czacie wraz z siłą sygnału (RSSI). Wiadomości od kontaktów mają nazwę nadawcy.
- Wiadomość może mieć do około 111 bajtów tekstu (mniej przy długiej nazwie użytkownika, a polskie litery zajmują po 2 bajty).

### Konta i kontakty

- **// account** w Settings pokazuje Twoją nazwę użytkownika i id (8 znaków hex). Dotknij, aby zmienić nazwę (do 16 bajtów). Kontakty zobaczą nową nazwę przy Twojej następnej wiadomości.
- Aby dodać kontakt, obie osoby łączą się ze swoimi płytkami i jednocześnie otwierają **// contacts → + add contact**. Urządzenia znajdują się przez LoRa i oba pokazują 4-cyfrowy kod. Jeśli kody są takie same, potwierdźcie na obu telefonach. Jeśli się różnią, odrzućcie.
- Po sparowaniu wiadomości wysłane do tego kontaktu może odczytać tylko Wasza dwójka.
- Usunięcie kontaktu kasuje jego klucz. Aby znowu rozmawiać, trzeba sparować się od nowa.

### Wspólny klucz (tryb everyone)

- **// encryption → aes-256 key** edytuje wspólny klucz AES-256: 64 znaki hex, z przyciskami **generate** i **copy**.
- Każde urządzenie, które ma czytać wiadomości „everyone", musi mieć ten sam klucz. Klucz domyślny jest publiczny (taki sam jak w Bun-1 Communicator), więc ustaw własny.
- **show undecryptable** decyduje, czy wiadomości, których nie udało się odszyfrować, są pokazywane jako `[decrypt failed] ...`, czy ukrywane. Wiadomości zaadresowane do innych osób są zawsze ukrywane.

### Zmiana nazwy płytki

- Połącz się z płytką, a potem użyj ikony ołówka przy niej na liście **// my boards**. Nazwa (do 20 znaków ASCII) jest zapisywana na płytce i widoczna na liście skanowania po najbliższym rozłączeniu.

## Protokół

BLE używa Nordic UART Service (`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`); dane to tekst, jedna linia na wiadomość, zakończona `\n`.

Aplikacja do płytki:
- `<tekst>` - wysyłany jako pakiet LoRa (maks. 224 znaki, dłuższy jest ucinany)
- `\x01NAME|<nazwa>` - zmiana nazwy płytki

Płytka do aplikacji:
- `RX|<rssi>|<payload>` - odebrano pakiet LoRa
- `NAME|<nazwa>` albo `NAMEERR|<powód>` - wynik zmiany nazwy

Dane w pakietach LoRa (to, co płytka wysyła i odbiera):
- ciąg hex - wiadomość na wspólnym kluczu: AES-256-CBC, stały IV, PKCS#7, jak w Bun-1 Communicator
- `#H<base64>` - hello do parowania: klucz publiczny i nazwa użytkownika
- `#M<base64>` - wiadomość do jednego kontaktu: id nadawcy, id odbiorcy, nonce, szyfrogram AES-GCM

Płytka nigdy nie widzi kluczy ani tekstu jawnego, więc jej OLED pokazuje zaszyfrowane dane.

## Uwagi

- Tryb wspólnego klucza używa stałego wektora inicjalizującego (IV) dla AES-CBC (zostawionego dla zgodności z Bun-1 Communicator): ta sama wiadomość zawsze daje ten sam szyfrogram i nie ma kontroli integralności. Jest to odpowiednie do nauki i projektów hobbystycznych, ale nie do produkcyjnego bezpieczeństwa. Wiadomości do kontaktów używają losowego nonce i AES-GCM.
- 4-cyfrowy kod parowania to skromne zabezpieczenie. Ktoś w zasięgu radia, kto aktywnie wmiesza się w parowanie, mógłby podmienić klucze. Paruj się tylko z osobami, które widzisz.
- Klucz prywatny i wspólny klucz są zapisane w `SharedPreferences` aplikacji, bez dodatkowego szyfrowania.
- Każde urządzenie w zasięgu radia odbiera każdy pakiet LoRa; przy kontaktach widzi tylko zaszyfrowane dane oraz id nadawcy i odbiorcy.
- Płytka przyjmuje dowolnego klienta BLE (nie ma parowania ani PIN-u BLE), a naraz może być połączony tylko jeden telefon.
- Historia czatu nie jest zapisywana; znika po zamknięciu aplikacji.
- Po odinstalowaniu aplikacji tracisz klucz prywatny i musisz sparować się z kontaktami od nowa.
- Jeśli Gradle na Windowsie zgłasza `this and base files have different roots`, trzymaj projekt i cache pakietów Fluttera na tym samym dysku (albo zostaw `kotlin.incremental=false` w `android/gradle.properties`, tak jak w tym repozytorium).

## Struktura projektu

- `firmware/src/main.cpp` - firmware: przekaźnik BLE do LoRa, status na OLED, nazwa płytki w NVS
- `firmware/platformio.ini` - konfiguracja budowania firmware i zależności
- `lib/main.dart` - punkt wejścia aplikacji
- `lib/screens/home_screen.dart` - ekran czatu
- `lib/screens/scan_screen.dart` - skanowanie płytek
- `lib/screens/settings_screen.dart` - płytki, konto, kontakty, szyfrowanie
- `lib/services/board_manager.dart` - połączenie Bluetooth, wiadomości, kontakty, parowanie
- `lib/services/crypto_service.dart` - AES-256-CBC (wspólny klucz, zgodny ze starym firmware)
- `lib/services/identity_crypto.dart` - X25519, HKDF, AES-GCM i kod parowania
- `lib/models/` - `Board` i `Contact`
- `lib/constants.dart` - UUID-y BLE
- `test/` - testy obu trybów szyfrowania
