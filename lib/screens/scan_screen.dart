import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants.dart';
import '../models/board.dart';
import '../services/board_manager.dart';

class ScanScreen extends StatefulWidget {
  final BoardManager manager;
  const ScanScreen({super.key, required this.manager});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  /// Tracks which device IDs are currently being registered (shows a spinner).
  final Set<String> _registering = {};

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    try {
      await FlutterBluePlus.startScan(
        withServices: [nusService],
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan error: $e')),
      );
    }
  }

  Future<void> _register(ScanResult result) async {
    final id = result.device.remoteId.str;
    if (_registering.contains(id)) return;

    setState(() => _registering.add(id));
    FlutterBluePlus.stopScan();

    final name = result.advertisementData.advName.isNotEmpty
        ? result.advertisementData.advName
        : id;

    final board = Board(id: id, name: name);
    await widget.manager.addBoard(board);
    await widget.manager.setActiveBoard(board);

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Board'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: StreamBuilder<bool>(
            stream: FlutterBluePlus.isScanning,
            initialData: false,
            builder: (_, snap) => (snap.data ?? false)
                ? const LinearProgressIndicator()
                : const SizedBox.shrink(),
          ),
        ),
      ),
      body: StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        initialData: const [],
        builder: (_, snap) {
          final results = snap.data ?? [];

          if (results.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text('Scanning for LoRa boards…'),
                  SizedBox(height: 8),
                  Text(
                    'Make sure your ESP board is powered on.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: results.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r    = results[i];
              final id   = r.device.remoteId.str;
              final name = r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : id;
              final busy = _registering.contains(id);
              final alreadyAdded =
                  widget.manager.boards.any((b) => b.id == id);

              return ListTile(
                leading: const Icon(Icons.developer_board),
                title: Text(name),
                subtitle: Text('$id  •  ${r.rssi} dBm'),
                trailing: busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : alreadyAdded
                        ? const Chip(label: Text('Added'))
                        : const Icon(Icons.add_circle_outline),
                onTap: busy ? null : () => _register(r),
              );
            },
          );
        },
      ),
      floatingActionButton: StreamBuilder<bool>(
        stream: FlutterBluePlus.isScanning,
        initialData: false,
        builder: (_, snap) {
          final scanning = snap.data ?? false;
          return FloatingActionButton.extended(
            onPressed: scanning ? FlutterBluePlus.stopScan : _startScan,
            icon: Icon(scanning ? Icons.stop : Icons.search),
            label: Text(scanning ? 'Stop' : 'Scan again'),
          );
        },
      ),
    );
  }
}
