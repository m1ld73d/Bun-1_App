import 'package:flutter/material.dart';

import '../services/board_manager.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final BoardManager manager;
  const HomeScreen({super.key, required this.manager});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ctrl   = TextEditingController();
  final _scroll = ScrollController();
  int _prevMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _prevMessageCount = widget.manager.messages.length;
    widget.manager.addListener(_onManagerChange);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChange);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onManagerChange() {
    final count = widget.manager.messages.length;
    if (count > _prevMessageCount) {
      _prevMessageCount = count;
      _scrollToBottom();
    }
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim().replaceAll('\n', ' ');
    if (text.isEmpty) return;
    _ctrl.clear();
    try {
      await widget.manager.sendMessage(text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }

  // ── Status indicator ───────────────────────────────────────────────────────

  ({IconData icon, Color color, String label}) _statusInfo(
      ConnectionStatus status, String boardName) {
    return switch (status) {
      ConnectionStatus.connected => (
          icon: Icons.bluetooth_connected,
          color: Colors.green,
          label: boardName,
        ),
      ConnectionStatus.connecting => (
          icon: Icons.bluetooth_searching,
          color: Colors.orange,
          label: boardName,
        ),
      ConnectionStatus.disconnected => (
          icon: Icons.bluetooth_disabled,
          color: Colors.grey,
          label: boardName,
        ),
    };
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final board   = manager.activeBoard;
    final cs      = Theme.of(context).colorScheme;

    Widget titleWidget;
    if (board == null) {
      titleWidget = const Text('No board');
    } else {
      final info = _statusInfo(manager.status, board.name);
      titleWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(info.icon, color: info.color, size: 18),
          const SizedBox(width: 6),
          Text(info.label),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: titleWidget,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(manager: manager),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Chat area ────────────────────────────────────────────────────
          Expanded(
            child: manager.messages.isEmpty
                ? Center(
                    child: Text(
                      'Nothing to show yet',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: cs.outline),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 16),
                    itemCount: manager.messages.length,
                    itemBuilder: (_, i) =>
                        _ChatBubble(message: manager.messages[i], cs: cs),
                  ),
          ),

          // ── Input bar ────────────────────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      enabled: manager.isConnected,
                      maxLength: 100,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: manager.isConnected
                            ? 'LoRa message...'
                            : board == null
                                ? 'Add a board in Settings'
                                : manager.status ==
                                        ConnectionStatus.connecting
                                    ? 'Connecting…'
                                    : 'Disconnected',
                        border: const OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: manager.isConnected ? _send : null,
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

// ── Chat bubble ────────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final ColorScheme cs;

  const _ChatBubble({required this.message, required this.cs});

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final m = message;
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: m.mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(m.mine ? 16 : 4),
            bottomRight: Radius.circular(m.mine ? 4 : 16),
          ),
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
  }
}
