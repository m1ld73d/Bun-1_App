import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

final nusService = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
final nusRx = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // app -> ESP
final nusTx = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // ESP -> app

void main() => runApp(const LoraApp());

class LoraApp extends StatelessWidget {
  const LoraApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LoRa Chat',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const ScanPage(),
      );
}

// ======================= Ekran skanowania =======================

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  Future<void> _scan() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    try {
      await FlutterBluePlus.startScan(
        withServices: [nusService],
        timeout: const Duration(seconds: 8),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Błąd skanowania: $e')));
    }
  }

  void _open(BluetoothDevice device) {
    FlutterBluePlus.stopScan();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatPage(device: device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Urządzenia LoRa')),
      body: StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        initialData: const [],
        builder: (context, snap) {
          final results = snap.data ?? [];
          if (results.isEmpty) {
            return const Center(
                child: Text('Naciśnij „Szukaj”, aby znaleźć płytkę'));
          }
          return ListView(
            children: [
              for (final r in results)
                ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(r.advertisementData.advName.isNotEmpty
                      ? r.advertisementData.advName
                      : r.device.remoteId.str),
                  subtitle: Text('${r.device.remoteId}  •  ${r.rssi} dBm'),
                  onTap: () => _open(r.device),
                ),
            ],
          );
        },
      ),
      floatingActionButton: StreamBuilder<bool>(
        stream: FlutterBluePlus.isScanning,
        initialData: false,
        builder: (context, snap) {
          final scanning = snap.data ?? false;
          return FloatingActionButton.extended(
            onPressed: scanning ? FlutterBluePlus.stopScan : _scan,
            icon: Icon(scanning ? Icons.stop : Icons.search),
            label: Text(scanning ? 'Stop' : 'Szukaj'),
          );
        },
      ),
    );
  }
}

// ======================= Ekran czatu =======================

class ChatMessage {
  final bool mine;
  final String text;
  final int? rssi;
  final DateTime time = DateTime.now();
  ChatMessage(this.mine, this.text, {this.rssi});
}

class ChatPage extends StatefulWidget {
  final BluetoothDevice device;
  const ChatPage({super.key, required this.device});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  final List<int> _buf = [];

  BluetoothCharacteristic? _rx;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  String _status = 'Łączenie...';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final d = widget.device;
      await d.connect(
        timeout: const Duration(seconds: 15),
        license: License.free,
      );

      _stateSub = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _ready = false;
            _status = 'Rozłączono';
          });
        }
      });

      if (Platform.isAndroid) {
        await d.requestMtu(247);
      }

      final services = await d.discoverServices();
      final svc = services.firstWhere((s) => s.uuid == nusService);
      _rx = svc.characteristics.firstWhere((c) => c.uuid == nusRx);
      final tx = svc.characteristics.firstWhere((c) => c.uuid == nusTx);

      await tx.setNotifyValue(true);
      _dataSub = tx.onValueReceived.listen(_onData);

      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Połączono';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Błąd: $e');
    }
  }

  // Skleja kawałki w linie zakończone '\n'
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
    // format: RX|rssi|tekst
    final parts = line.split('|');
    if (parts[0] == 'RX' && parts.length >= 3) {
      setState(() {
        _messages.add(ChatMessage(
          false,
          parts.sublist(2).join('|'),
          rssi: int.tryParse(parts[1]),
        ));
      });
      _scrollDown();
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim().replaceAll('\n', ' ');
    final rx = _rx;
    if (text.isEmpty || !_ready || rx == null) return;
    _ctrl.clear();

    setState(() => _messages.add(ChatMessage(true, text)));
    _scrollDown();

    final bytes = utf8.encode('$text\n');
    final chunk = max(20, widget.device.mtuNow - 3);
    try {
      for (var i = 0; i < bytes.length; i += chunk) {
        await rx.write(bytes.sublist(i, min(i + chunk, bytes.length)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Błąd wysyłania: $e')));
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _stateSub?.cancel();
    widget.device.disconnect();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName.isNotEmpty
            ? widget.device.platformName
            : 'LoRa'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_status, style: Theme.of(context).textTheme.labelMedium),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                return Align(
                  alignment:
                      m.mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: m.mine
                          ? cs.primaryContainer
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.text),
                        const SizedBox(height: 2),
                        Text(
                          '${_hhmm(m.time)}${m.rssi != null ? '  •  ${m.rssi} dBm' : ''}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      enabled: _ready,
                      maxLength: 100,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Wiadomość LoRa...',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _ready ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}