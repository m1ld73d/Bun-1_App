import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/board.dart';
import '../models/contact.dart';
import 'crypto_service.dart';
import 'identity_crypto.dart';

class ChatMessage {
  final bool mine;
  final String text;
  final int? rssi;

  /// Sender's name (received messages) or recipient's name (sent messages);
  /// null when unknown, e.g. a message sent with the shared key.
  final String? label;
  final DateTime time;

  ChatMessage(this.mine, this.text, {this.rssi, this.label})
      : time = DateTime.now();
}

enum ConnectionStatus { disconnected, connecting, connected }

class BoardManager extends ChangeNotifier {
  // ── State ─────────────────────────────────────────────────────────────────

  final List<Board> _boards = [];
  Board? _activeBoard;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  /// Per-board message history (keyed by board ID).
  final Map<String, List<ChatMessage>> _boardMessages = {};

  /// Partial-line reassembly buffer.
  final List<int> _buf = [];

  /// Pending rename request, completed when the board acknowledges it.
  Completer<void>? _renameCompleter;

  /// AES-256 key (64 hex chars) used to encrypt/decrypt messages in the app.
  String _aesKeyHex = MessageCrypto.defaultKeyHex;

  /// Whether received messages that could not be decrypted are shown in the
  /// chat (as "[decrypt failed] <raw text>") or silently dropped.
  bool _showUndecryptable = true;

  // ── Account, contacts, pairing ────────────────────────────────────────────

  /// Private key of this user (32 bytes) and the matching public key.
  Uint8List? _seed;
  Uint8List? _myPub;
  String _username = '';

  final List<Contact> _contacts = [];

  /// Key id (hex) of the contact messages are sent to; null = everyone,
  /// using the shared AES key.
  String? _recipientId;

  bool _pairing = false;
  Timer? _pairTimer;
  Hello? _pairPeer;
  final Set<String> _rejectedPeers = {};

  // ── Public getters ────────────────────────────────────────────────────────

  List<Board> get boards => List.unmodifiable(_boards);
  Board? get activeBoard => _activeBoard;
  ConnectionStatus get status => _status;
  bool get isConnected => _status == ConnectionStatus.connected;

  String get aesKeyHex => _aesKeyHex;
  bool get usesDefaultKey => _aesKeyHex == MessageCrypto.defaultKeyHex;
  bool get showUndecryptable => _showUndecryptable;

  String get username => _username;

  /// Short id of this account (8 hex chars); contacts see the same id.
  String get myIdHex =>
      _myPub == null ? '' : IdentityCrypto.keyIdHex(_myPub!);

  List<Contact> get contacts => List.unmodifiable(_contacts);

  /// Contact that messages are sent to, or null for "everyone" (shared key).
  Contact? get recipient {
    final id = _recipientId;
    if (id == null) return null;
    for (final c in _contacts) {
      if (c.idHex == id) return c;
    }
    return null;
  }

  bool get pairing => _pairing;

  /// Device found while pairing, waiting for the 4-digit code check.
  Hello? get pairPeer => _pairPeer;

  /// 4-digit code both devices must show for the same pairing.
  String? get pairCode => (_pairPeer != null && _myPub != null)
      ? IdentityCrypto.sas(_myPub!, _pairPeer!.pub)
      : null;

  List<ChatMessage> get messages =>
      _activeBoard != null ? (_boardMessages[_activeBoard!.id] ?? const []) : const [];

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final savedKey = prefs.getString('aesKey');
    if (savedKey != null && MessageCrypto.validateKey(savedKey) == null) {
      _aesKeyHex = savedKey.toLowerCase();
    }
    _showUndecryptable = prefs.getBool('showUndecryptable') ?? true;

    // Account: the private key is created on first launch.
    final seedB64 = prefs.getString('idSeed');
    Uint8List? seed;
    if (seedB64 != null) {
      try {
        final s = base64.decode(seedB64);
        if (s.length == 32) seed = s;
      } catch (_) {}
    }
    if (seed == null) {
      seed = IdentityCrypto.generateSeed();
      await prefs.setString('idSeed', base64.encode(seed));
    }
    _seed = seed;
    _myPub = await IdentityCrypto.publicKey(seed);
    _username = prefs.getString('username') ??
        'user-${IdentityCrypto.keyIdHex(_myPub!).substring(0, 4)}';

    for (final s in prefs.getStringList('contacts') ?? const <String>[]) {
      try {
        _contacts
            .add(Contact.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    _recipientId = prefs.getString('recipient');

    final raw = prefs.getStringList('boards') ?? [];
    _boards.addAll(
      raw.map((s) => Board.fromJson(jsonDecode(s) as Map<String, dynamic>)),
    );

    final activeId = prefs.getString('activeBoard');
    if (activeId != null) {
      Board? found;
      for (final b in _boards) {
        if (b.id == activeId) {
          found = b;
          break;
        }
      }
      _activeBoard = found ?? (_boards.isNotEmpty ? _boards.first : null);
    } else if (_boards.isNotEmpty) {
      _activeBoard = _boards.first;
    }

    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'boards',
      _boards.map((b) => jsonEncode(b.toJson())).toList(),
    );
    if (_activeBoard != null) {
      await prefs.setString('activeBoard', _activeBoard!.id);
    } else {
      await prefs.remove('activeBoard');
    }
  }

  // ── Board management ──────────────────────────────────────────────────────

  /// Registers a board without changing the active board or connection.
  Future<void> addBoard(Board board) async {
    if (!_boards.any((b) => b.id == board.id)) {
      _boards.add(board);
      await _save();
      notifyListeners();
    }
  }

  /// Removes a board. If it was active, switches to the next available board.
  Future<void> removeBoard(Board board) async {
    final wasActive = _activeBoard?.id == board.id;

    _boards.removeWhere((b) => b.id == board.id);
    _boardMessages.remove(board.id);

    if (wasActive) {
      await _teardownConnection();
      _activeBoard = _boards.isNotEmpty ? _boards.first : null;
      await _save();
      notifyListeners();
      if (_activeBoard != null) {
        // ignore: unawaited_futures
        connect();
      }
    } else {
      await _save();
      notifyListeners();
    }
  }

  /// Switches the active board and reconnects. Reconnects in place if same board.
  Future<void> setActiveBoard(Board board) async {
    if (_activeBoard?.id == board.id) {
      // Same board — reconnect if currently disconnected.
      if (_status == ConnectionStatus.disconnected) {
        await connect();
      }
      return;
    }

    await _teardownConnection();
    _activeBoard = board;
    await _save();
    notifyListeners();
    await connect();
  }

  // ── Bluetooth connection ──────────────────────────────────────────────────

  Future<void> connect() async {
    final board = _activeBoard;
    if (board == null || _status == ConnectionStatus.connecting) return;

    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      _device = BluetoothDevice(remoteId: DeviceIdentifier(board.id));

      await _device!.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
      );

      _connSub = _device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _status = ConnectionStatus.disconnected;
          _rxChar = null;
          notifyListeners();
        }
      });

      if (Platform.isAndroid) {
        await _device!.requestMtu(247);
      }

      final services = await _device!.discoverServices();
      final svc = services.firstWhere((s) => s.uuid == nusService);
      _rxChar = svc.characteristics.firstWhere((c) => c.uuid == nusRx);
      final tx  = svc.characteristics.firstWhere((c) => c.uuid == nusTx);

      await tx.setNotifyValue(true);
      _dataSub = tx.onValueReceived.listen(_onData);

      _status = ConnectionStatus.connected;
      notifyListeners();
    } catch (_) {
      _status = ConnectionStatus.disconnected;
      _rxChar = null;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _teardownConnection();
    notifyListeners();
  }

  /// Cleans up subscriptions and BLE connection without notifying listeners.
  Future<void> _teardownConnection() async {
    await _dataSub?.cancel();
    await _connSub?.cancel();
    _dataSub = null;
    _connSub = null;
    _rxChar = null;
    _buf.clear();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _status = ConnectionStatus.disconnected;
  }

  // ── Data handling ─────────────────────────────────────────────────────────

  void _onData(List<int> data) {
    _buf.addAll(data);
    int idx;
    while ((idx = _buf.indexOf(10)) != -1) {
      final bytes = _buf.sublist(0, idx);
      _buf.removeRange(0, idx + 1);
      final line = utf8.decode(bytes, allowMalformed: true).trim();
      if (line.isNotEmpty) _handleLine(line);
    }
  }

  void _handleLine(String line) {
    // Expected formats from ESP:
    //   RX|rssi|message text
    //   NAME|new name     (rename acknowledged and stored in board NVS)
    //   NAMEERR|reason    (rename rejected)
    final parts = line.split('|');
    if (parts[0] == 'NAME' && parts.length >= 2) {
      _setActiveBoardName(parts.sublist(1).join('|'));
      _renameCompleter?.complete();
      _renameCompleter = null;
      return;
    }
    if (parts[0] == 'NAMEERR') {
      _renameCompleter?.completeError(
          'Board rejected the name (${parts.length > 1 ? parts[1] : 'error'})');
      _renameCompleter = null;
      return;
    }
    if (parts[0] == 'RX' && parts.length >= 3) {
      // ignore: unawaited_futures
      _handleRx(int.tryParse(parts[1]), parts.sublist(2).join('|'));
    }
  }

  /// Handles one LoRa payload forwarded by the board. Payload kinds:
  ///   `#H...`  hello from a device that is pairing
  ///   `#M...`  message encrypted for one contact (X25519 + AES-GCM)
  ///   other    hex ciphertext made with the shared AES key (older format)
  Future<void> _handleRx(int? rssi, String payload) async {
    final boardId = _activeBoard?.id;
    if (boardId == null) return;

    if (payload.startsWith('#H')) {
      _onHello(payload);
      return;
    }

    String? text;
    String? label;

    if (payload.startsWith('#M')) {
      final packet = IdentityCrypto.parseMessage(payload);
      final myPub = _myPub;
      final seed = _seed;
      if (packet != null && myPub != null && seed != null) {
        // Radio is broadcast: ignore messages meant for other people.
        if (!IdentityCrypto.sameBytes(
            packet.recipientId, IdentityCrypto.keyId(myPub))) {
          return;
        }
        Contact? sender;
        for (final c in _contacts) {
          if (IdentityCrypto.sameBytes(
              IdentityCrypto.keyId(c.pub), packet.senderId)) {
            sender = c;
            break;
          }
        }
        if (sender != null) {
          final m = await IdentityCrypto.decryptMessage(
            seed: seed,
            myPub: myPub,
            theirPub: sender.pub,
            packet: packet,
          );
          if (m != null) {
            text = m.text;
            label = m.name.isEmpty ? sender.name : m.name;
            if (m.name.isNotEmpty && m.name != sender.name) {
              _updateContactName(sender, m.name);
            }
          }
        }
      }
    } else {
      text = MessageCrypto.decrypt(payload, _aesKeyHex);
    }

    if (text == null) {
      // Wrong key, unknown sender, damaged, or sent without encryption.
      if (!_showUndecryptable) return;
      text = '[decrypt failed] $payload';
    }
    if (_activeBoard?.id != boardId) return; // board changed while decrypting

    _boardMessages
        .putIfAbsent(boardId, () => [])
        .add(ChatMessage(false, text, rssi: rssi, label: label));
    notifyListeners();
  }

  /// Sends a message over BLE. Throws on failure so callers can show errors.
  /// With a contact selected it is encrypted for that contact only;
  /// otherwise the shared AES key is used.
  Future<void> sendMessage(String text) async {
    final board = _activeBoard;
    if (text.isEmpty || !isConnected || board == null) return;

    // Encrypt first, so a too-long message is rejected before it shows up in
    // the chat. The board just forwards this text over LoRa.
    final to = recipient;
    final String payload;
    final String label;
    if (to == null) {
      payload = MessageCrypto.encrypt(text, _aesKeyHex);
      label = 'everyone';
    } else {
      final seed = _seed;
      final myPub = _myPub;
      if (seed == null || myPub == null) throw 'Account is not ready yet';
      payload = await IdentityCrypto.encryptMessage(
        seed: seed,
        myPub: myPub,
        theirPub: to.pub,
        name: _username,
        text: text,
      );
      label = to.name;
    }

    _boardMessages
        .putIfAbsent(board.id, () => [])
        .add(ChatMessage(true, text, label: label));
    notifyListeners();

    await _writeLine(payload);
  }

  // ── Account and contacts ──────────────────────────────────────────────────

  /// Changes the username other people see next to your messages.
  Future<void> setUsername(String name) async {
    final error = IdentityCrypto.validateName(name);
    if (error != null) throw error;
    _username = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', _username);
    notifyListeners();
  }

  /// Selects who messages are sent to; null = everyone (shared key).
  Future<void> setRecipient(Contact? contact) async {
    _recipientId = contact?.idHex;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (_recipientId == null) {
      await prefs.remove('recipient');
    } else {
      await prefs.setString('recipient', _recipientId!);
    }
  }

  Future<void> removeContact(Contact contact) async {
    _contacts.removeWhere((c) => IdentityCrypto.sameBytes(c.pub, contact.pub));
    if (_recipientId == contact.idHex) _recipientId = null;
    await _saveContacts();
    notifyListeners();
  }

  void _updateContactName(Contact contact, String name) {
    final i =
        _contacts.indexWhere((c) => IdentityCrypto.sameBytes(c.pub, contact.pub));
    if (i == -1) return;
    _contacts[i] = contact.withName(name);
    // ignore: unawaited_futures
    _saveContacts();
  }

  Future<void> _saveContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'contacts',
      _contacts.map((c) => jsonEncode(c.toJson())).toList(),
    );
    if (_recipientId == null) {
      await prefs.remove('recipient');
    } else {
      await prefs.setString('recipient', _recipientId!);
    }
  }

  // ── Pairing ───────────────────────────────────────────────────────────────
  //
  // Both people open "add contact". Each device broadcasts a hello with its
  // public key. When a hello arrives, both devices show the same 4-digit code;
  // if the people agree it matches, each confirms and saves the other as a
  // contact. Nothing secret is sent over the air - only public keys.

  void startPairing() {
    if (_pairing) return;
    _pairing = true;
    _pairPeer = null;
    _rejectedPeers.clear();
    _sendHello();
    _scheduleHello();
    notifyListeners();
  }

  void _scheduleHello() {
    _pairTimer?.cancel();
    // Random delay so two devices do not keep colliding on the same instant.
    final ms = 3000 + Random().nextInt(3000);
    _pairTimer = Timer(Duration(milliseconds: ms), () {
      if (!_pairing) return;
      _sendHello();
      _scheduleHello();
    });
  }

  void _sendHello() {
    final pub = _myPub;
    if (pub == null || !isConnected) return;
    _writeLine(IdentityCrypto.helloPayload(pub, _username)).catchError((_) {});
  }

  void _onHello(String payload) {
    if (!_pairing || _pairPeer != null) return;
    final hello = IdentityCrypto.parseHello(payload);
    final myPub = _myPub;
    if (hello == null || myPub == null) return;
    if (IdentityCrypto.sameBytes(hello.pub, myPub)) return;
    if (_rejectedPeers.contains(IdentityCrypto.keyIdHex(hello.pub))) return;
    _pairPeer = hello;
    notifyListeners();
  }

  /// Stops pairing. Pass `notify: false` when called while a widget is being
  /// disposed (notifying then would rebuild other widgets mid-teardown).
  void stopPairing({bool notify = true}) {
    if (!_pairing && _pairPeer == null) return;
    _pairing = false;
    _pairTimer?.cancel();
    _pairTimer = null;
    _pairPeer = null;
    if (notify) notifyListeners();
  }

  /// The codes did not match: ignore this device and keep looking.
  void rejectPairPeer() {
    final peer = _pairPeer;
    if (peer == null) return;
    _rejectedPeers.add(IdentityCrypto.keyIdHex(peer.pub));
    _pairPeer = null;
    notifyListeners();
  }

  /// The codes matched: save the other device as a contact and stop pairing.
  /// Returns the contact's name.
  Future<String> confirmPairPeer() async {
    final peer = _pairPeer;
    if (peer == null) throw 'No device to pair with';
    final name = peer.name.trim().isEmpty
        ? 'user-${IdentityCrypto.keyIdHex(peer.pub).substring(0, 4)}'
        : peer.name.trim();
    final contact = Contact(name: name, pub: peer.pub);

    final i =
        _contacts.indexWhere((c) => IdentityCrypto.sameBytes(c.pub, peer.pub));
    if (i == -1) {
      _contacts.add(contact);
    } else {
      _contacts[i] = contact;
    }
    stopPairing(notify: false);
    await _saveContacts();
    notifyListeners();
    return name;
  }

  // ── Encryption key ────────────────────────────────────────────────────────

  /// Turns the display of undecryptable messages on or off (saved).
  Future<void> setShowUndecryptable(bool value) async {
    _showUndecryptable = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showUndecryptable', value);
  }

  /// Saves a new AES-256 key (64 hex chars). Every device that should read
  /// your messages needs the same key. Throws a message if [hex] is invalid.
  Future<void> setAesKey(String hex) async {
    final key = hex.trim().toLowerCase();
    final error = MessageCrypto.validateKey(key);
    if (error != null) throw error;

    _aesKeyHex = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('aesKey', key);
    notifyListeners();
  }

  Future<void> _writeLine(String line) async {
    final rx     = _rxChar;
    final device = _device;
    if (rx == null || device == null) throw 'Not connected';

    final bytes = utf8.encode('$line\n');
    final chunk = max(20, device.mtuNow - 3);
    for (var i = 0; i < bytes.length; i += chunk) {
      await rx.write(bytes.sublist(i, min(i + chunk, bytes.length)));
    }
  }

  // ── Rename ────────────────────────────────────────────────────────────────

  static const maxNameLength = 20;

  /// Returns an error message, or null if [name] is acceptable to the firmware.
  static String? validateName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Name cannot be empty';
    if (n.length > maxNameLength) return 'Max $maxNameLength characters';
    if (!RegExp(r'^[\x20-\x7E]+$').hasMatch(n) || n.contains('|')) {
      return 'Use plain ASCII, no "|"';
    }
    return null;
  }

  /// Renames the connected board. The name is stored in the board's flash
  /// (NVS), shown on its OLED, and advertised over BLE. Throws if the board is
  /// not connected, rejects the name, or does not answer in time.
  Future<void> renameActiveBoard(String newName) async {
    final name = newName.trim();
    final error = validateName(name);
    if (error != null) throw error;
    if (!isConnected) throw 'Connect to the board first';
    if (_renameCompleter != null) throw 'Rename already in progress';

    final completer = Completer<void>();
    _renameCompleter = completer;
    try {
      await _writeLine('\x01NAME|$name');
      await completer.future.timeout(const Duration(seconds: 5),
          onTimeout: () => throw 'Board did not respond');
    } finally {
      if (identical(_renameCompleter, completer)) _renameCompleter = null;
    }
  }

  void _setActiveBoardName(String name) {
    final active = _activeBoard;
    if (active == null || active.name == name) return;
    final renamed = Board(id: active.id, name: name);
    final i = _boards.indexWhere((b) => b.id == active.id);
    if (i != -1) _boards[i] = renamed;
    _activeBoard = renamed;
    _save();
    notifyListeners();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _pairTimer?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
