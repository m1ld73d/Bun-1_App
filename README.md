# Bun-1 App

[![en](https://img.shields.io/badge/lang-en-blue)](https://github.com/m1ld73d/Bun-1_App/blob/main/README.md)
[![pl](https://img.shields.io/badge/lang-PL-red)](https://github.com/m1ld73d/Bun-1_App/blob/main/README.pl.md)

Chat app for ESP32 LoRa boards, controlled over Bluetooth Low Energy.

This is the successor of [Bun-1 Communicator](https://github.com/kielbassa/Bun-1_Communicator).

The project consists of two parts:
- `firmware/` - ESP32 firmware (PlatformIO) that relays text between the phone (BLE) and the LoRa radio
- the Flutter app (`lib/`) with the chat, board management, accounts and encryption

It uses:
- LoRa radio for wireless messaging between boards
- Bluetooth Low Energy (Nordic UART Service) between the phone and the board
- OLED display for board name, connection status and the last sent and received packet
- AES-256 and X25519 encryption done in the app
- non-volatile storage (NVS) on the board for the device name

## Features

- chat screen with message history per board (kept while the app is running)
- several boards can be saved, one is active at a time; the app reconnects to it
- scanning for nearby boards and adding them from the app
- renaming a board from the app (the name is stored in the board's flash)
- encryption done in the app, the board only forwards text:
  - **everyone** mode: AES-256-CBC with a shared key set in Settings (compatible with Bun-1 Communicator)
  - **contacts** mode: a separate key for every pair of users (X25519 key exchange + AES-GCM)
- user accounts: username and key pair created on first launch
- pairing with other users over LoRa, confirmed with a 4-digit code
- sender name shown above every message from a contact
- optional display of messages that could not be decrypted

## Hardware

Recommended board (unchanged):
- `ttgo-lora32-v1`

Configured pins in code:
- OLED / I2C: `SDA=4`, `SCL=15`, `RST=16`
- LoRa: `SCK=5`, `MISO=19`, `MOSI=27`, `SS=18`, `RST=14`, `DIO0=26`
- LoRa frequency: `866 MHz`
- Button `GPIO0` is not used by the firmware (it is only the BOOT button used when flashing)

## Software

### Firmware

Built with PlatformIO using `firmware/platformio.ini`.

Dependencies:
- `sandeepmistry/LoRa@^0.8.0`
- `adafruit/Adafruit SSD1306@^2.5.9`
- `adafruit/Adafruit GFX Library@^1.11.9`
- `h2zero/NimBLE-Arduino@^2.1.0`

### App

Built with Flutter (Dart `^3.13.7`).

Dependencies:
- `flutter_blue_plus` - Bluetooth Low Energy
- `permission_handler` - Bluetooth permissions
- `shared_preferences` - saved boards, key, account and settings
- `pointycastle` - AES-256-CBC for the shared key mode
- `cryptography` - X25519, HKDF and AES-GCM for accounts

Requirements for building on Android:
- Flutter SDK (stable) and Android Studio with the Flutter plugin
- Android SDK Platform 37 (`compileSdk = 37`)
- JDK 17
- a phone with Bluetooth Low Energy (Bluetooth scan and connect permissions are requested on first use)

## Usage

1. Build and upload the firmware with PlatformIO (from the `firmware` folder):
   ```bash
   pio run
   pio run -t upload
   ```
   If the upload hangs on `Connecting...`, hold the BOOT button on the board.
2. Build and run the app (from the project root):
   ```bash
   flutter pub get
   flutter run --release
   ```
   To get an installable file: `flutter build apk --release`. The result is in `build/app/outputs/flutter-apk/`.
3. The board shows its name on the OLED (by default `LoRaNode-xxxx`) and `BLE: czekam...` until a phone connects.
4. In the app open **Settings** and choose **+ add new board**. Scan, tap your board to add it, then select it in **// my boards** to connect.

### Sending and receiving messages

- Type a message at the bottom of the main screen and send it. The field works only when a board is connected.
- Above the field the button **to:** selects who the message is for: **everyone (shared key)** or one of your contacts.
- Received messages appear in the chat with their signal strength (RSSI). Messages from contacts show the sender's name.
- A message can have up to about 111 bytes of text (fewer with a long username, and Polish letters take 2 bytes each).

### Accounts and contacts

- **// account** in Settings shows your username and your id (8 hex characters). Tap it to change the username (up to 16 bytes). Your contacts see the new name with your next message.
- To add a contact, both people connect to their boards and open **// contacts → + add contact** at the same time. The devices find each other over LoRa and both show a 4-digit code. If the codes are the same, confirm on both phones. If they differ, reject.
- After pairing, messages sent to that contact are readable only by the two of you.
- Removing a contact deletes their key. To talk again you have to pair again.

### Shared key (everyone mode)

- **// encryption → aes-256 key** edits the shared AES-256 key: 64 hex characters, with **generate** and **copy** buttons.
- Every device that should read "everyone" messages needs the same key. The default key is public (the same as in Bun-1 Communicator), so set your own.
- **show undecryptable** decides whether messages that could not be decrypted are shown as `[decrypt failed] ...` or hidden. Messages addressed to other people are always hidden.

### Renaming a board

- Connect to the board, then use the pencil icon next to it in **// my boards**. The name (up to 20 ASCII characters) is saved on the board and shows in the scan list after the next disconnect.

## Protocol

BLE uses the Nordic UART Service (`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`); data is text, one line per message, ended with `\n`.

App to board:
- `<text>` - sent as a LoRa packet (max 224 characters, longer is cut)
- `\x01NAME|<name>` - rename the board

Board to app:
- `RX|<rssi>|<payload>` - a LoRa packet was received
- `NAME|<name>` or `NAMEERR|<reason>` - result of the rename

LoRa payloads (what the board sends and receives):
- hex string - shared key message: AES-256-CBC, fixed IV, PKCS#7, as in Bun-1 Communicator
- `#H<base64>` - pairing hello: public key and username
- `#M<base64>` - message for one contact: sender id, recipient id, nonce, AES-GCM ciphertext

The board never sees keys or plain text, so its OLED shows the encrypted payloads.

## Notes

- The shared key mode uses a fixed IV for AES-CBC (kept for compatibility with Bun-1 Communicator): the same message always gives the same ciphertext and there is no integrity check. This is fine for learning and hobby use, not for production security. Contact messages use a random nonce and AES-GCM.
- A 4-digit pairing code is a modest protection. Someone in radio range who actively interferes with the pairing could swap the keys. Pair only with people you can see.
- The private key and the shared key are stored in the app's `SharedPreferences`, without extra encryption.
- Every device in radio range receives every LoRa packet; with contacts they can only see the encrypted payload and the sender and recipient ids.
- The board accepts any BLE client (there is no BLE pairing or PIN), and only one phone can be connected at a time.
- Chat history is not saved; it is lost when the app is closed.
- If you uninstall the app, your private key is lost and you must pair with your contacts again.
- If Gradle fails on Windows with `this and base files have different roots`, keep the project and the Flutter pub cache on the same drive (or keep `kotlin.incremental=false` in `android/gradle.properties`, as in this repository).

## Project Structure

- `firmware/src/main.cpp` - firmware: BLE to LoRa relay, OLED status, board name in NVS
- `firmware/platformio.ini` - firmware build configuration and dependencies
- `lib/main.dart` - app entry point
- `lib/screens/home_screen.dart` - chat screen
- `lib/screens/scan_screen.dart` - scanning for boards
- `lib/screens/settings_screen.dart` - boards, account, contacts, encryption
- `lib/services/board_manager.dart` - Bluetooth connection, messages, contacts, pairing
- `lib/services/crypto_service.dart` - AES-256-CBC (shared key, compatible with the old firmware)
- `lib/services/identity_crypto.dart` - X25519, HKDF, AES-GCM and pairing code
- `lib/models/` - `Board` and `Contact`
- `lib/constants.dart` - BLE UUIDs
- `test/` - tests of both encryption modes
