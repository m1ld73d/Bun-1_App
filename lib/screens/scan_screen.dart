import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants.dart';
import '../models/board.dart';
import '../services/board_manager.dart';
import '../theme.dart';

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
        title: const Text('add board'),
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
      body: BunnyBackground(
        child: StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        initialData: const [],
        builder: (_, snap) {
          final results = snap.data ?? [];

          if (results.isEmpty) {
            final cs = Theme.of(context).colorScheme;
            return Center(
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: cs.surface,
                  border: Border.all(color: cs.primary),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text('> scanning for boards...'),
                    SizedBox(height: 8),
                    Text('make sure your ESP is powered on'),
                  ],
                ),
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
                leading: const Icon(Icons.memory_sharp),
                title: Text(name),
                subtitle: Text('$id  •  ${r.rssi} dBm'),
                trailing: busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : alreadyAdded
                        ? const Chip(label: Text('added'))
                        : const Icon(Icons.add_sharp),
                onTap: busy ? null : () => _register(r),
              );
            },
          );
        },
      ),
      ),
      floatingActionButton: StreamBuilder<bool>(
        stream: FlutterBluePlus.isScanning,
        initialData: false,
        builder: (_, snap) {
          final scanning = snap.data ?? false;
          return FloatingActionButton.extended(
            onPressed: scanning ? FlutterBluePlus.stopScan : _startScan,
            icon: Icon(scanning ? Icons.stop_sharp : Icons.search_sharp),
            label: Text(scanning ? 'stop' : 'scan again'),
          );
        },
      ),
    );
  }
}
