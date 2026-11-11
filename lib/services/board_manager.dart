import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/board.dart';

class ChatMessage {
  final bool mine;
  final String text;
  final int? rssi;
  final DateTime time;

  ChatMessage(this.mine, this.text, {this.rssi}) : time = DateTime.now();
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

  // ── Public getters ────────────────────────────────────────────────────────

  List<Board> get boards => List.unmodifiable(_boards);
  Board? get activeBoard => _activeBoard;
  ConnectionStatus get status => _status;
  bool get isConnected => _status == ConnectionStatus.connected;

  List<ChatMessage> get messages =>
      _activeBoard != null ? (_boardMessages[_activeBoard!.id] ?? const []) : const [];

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

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
      final boardId = _activeBoard?.id;
      if (boardId == null) return;
      _boardMessages
          .putIfAbsent(boardId, () => [])
          .add(ChatMessage(false, parts.sublist(2).join('|'),
              rssi: int.tryParse(parts[1])));
      notifyListeners();
    }
  }

  /// Sends a message over BLE. Throws on write failure so callers can show errors.
  Future<void> sendMessage(String text) async {
    final board = _activeBoard;
    if (text.isEmpty || !isConnected || board == null) return;

    _boardMessages.putIfAbsent(board.id, () => []).add(ChatMessage(true, text));
    notifyListeners();

    await _writeLine(text);
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
    _dataSub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
