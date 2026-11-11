import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/board_manager.dart';
import 'theme.dart';

void main() => runApp(const LoraApp());

class LoraApp extends StatefulWidget {
  const LoraApp({super.key});

  @override
  State<LoraApp> createState() => _LoraAppState();
}

class _LoraAppState extends State<LoraApp> {
  final _manager = BoardManager();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _manager.load().then((_) {
      setState(() => _loaded = true);
      // Auto-connect to the last active board on launch.
      if (_manager.activeBoard != null) {
        _manager.connect();
      }
    });
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoRa Chat',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      home: _loaded
          ? HomeScreen(manager: _manager)
          : const Scaffold(
              body: BunnyBackground(
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
    );
  }
}
