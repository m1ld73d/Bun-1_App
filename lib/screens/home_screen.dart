import 'package:flutter/material.dart';

import '../services/board_manager.dart';
import '../theme.dart';
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

  IconData _statusIcon(ConnectionStatus status) => switch (status) {
        ConnectionStatus.connected => Icons.bluetooth_connected_sharp,
        ConnectionStatus.connecting => Icons.bluetooth_searching_sharp,
        ConnectionStatus.disconnected => Icons.bluetooth_disabled_sharp,
      };

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final board   = manager.activeBoard;
    final cs      = Theme.of(context).colorScheme;

    Widget titleWidget;
    if (board == null) {
      titleWidget = Text('No board', style: TextStyle(color: cs.outline));
    } else {
      final connected = manager.isConnected;
      titleWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_statusIcon(manager.status), size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(board.name, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          // filled square = connected, hollow = not
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: connected ? cs.primary : Colors.transparent,
              border: Border.all(color: cs.primary, width: 1.5),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: titleWidget,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_sharp),
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
      body: BunnyBackground(
        child: Column(
        children: [
          // ── Chat area ────────────────────────────────────────────────────
          Expanded(
            child: manager.messages.isEmpty
                ? Center(
                    child: Text(
                      '// Nothing to show yet',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        backgroundColor: cs.surface,
                      ),
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
          _RecipientBar(manager: manager),
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
                            ? '> message'
                            : board == null
                                ? '> add a board in settings'
                                : manager.status ==
                                        ConnectionStatus.connecting
                                    ? '> connecting...'
                                    : '> disconnected',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: manager.isConnected ? _send : null,
                    icon: const Icon(Icons.arrow_forward_sharp),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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
        // mine: outlined on page colour; theirs: inverted solid block
        decoration: BoxDecoration(
          color: m.mine ? cs.surface : cs.primary,
          border: Border.all(color: cs.primary, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.label != null) ...[
              Text(
                m.mine ? '-> ${m.label}' : m.label!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: m.mine ? cs.onSurface : cs.onPrimary,
                ),
              ),
              const SizedBox(height: 2),
            ],
            Text(
              m.text,
              style: TextStyle(color: m.mine ? cs.onSurface : cs.onPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              '${_hhmm(m.time)}${m.rssi != null ? '  |  ${m.rssi} dBm' : ''}',
              style: TextStyle(
                fontSize: 10,
                color: m.mine ? cs.outline : cs.onPrimary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Recipient selector ─────────────────────────────────────────────────────────

/// "to: <name>" button above the input bar. Picks the contact messages are
/// encrypted for, or "everyone" (shared AES key).
class _RecipientBar extends StatelessWidget {
  final BoardManager manager;
  const _RecipientBar({required this.manager});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = manager.recipient;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<String>(
          tooltip: 'Choose who to send to',
          onSelected: (id) {
            if (id.isEmpty) {
              manager.setRecipient(null);
              return;
            }
            for (final c in manager.contacts) {
              if (c.idHex == id) {
                manager.setRecipient(c);
                return;
              }
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem<String>(
              value: '',
              child: Text('everyone (shared key)'),
            ),
            for (final c in manager.contacts)
              PopupMenuItem<String>(value: c.idHex, child: Text(c.name)),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border.all(color: cs.primary),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('to: ${current?.name ?? 'everyone (shared key)'}'),
                const Icon(Icons.arrow_drop_down_sharp),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
