import 'package:flutter/material.dart';

import '../services/board_manager.dart';
import '../models/board.dart';
import 'scan_screen.dart';

class SettingsScreen extends StatefulWidget {
  final BoardManager manager;
  const SettingsScreen({super.key, required this.manager});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChange);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChange);
    super.dispose();
  }

  void _onManagerChange() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmRemove(Board board) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove board?'),
        content: Text('Remove "${board.name}" from your devices?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.manager.removeBoard(board);
    }
  }

  // ── Status helpers ─────────────────────────────────────────────────────────

  String _statusLabel(ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected    => 'Connected',
        ConnectionStatus.connecting   => 'Connecting…',
        ConnectionStatus.disconnected => 'Disconnected',
      };

  Color _statusColor(ConnectionStatus s, ColorScheme cs) => switch (s) {
        ConnectionStatus.connected    => Colors.green,
        ConnectionStatus.connecting   => Colors.orange,
        ConnectionStatus.disconnected => cs.outline,
      };

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final boards  = manager.boards;
    final cs      = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ── My Boards section ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'My Boards',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: cs.primary),
            ),
          ),

          if (boards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'No boards registered yet. Tap "Add new board" below.',
                style: TextStyle(color: cs.outline),
              ),
            ),

          ...boards.map((board) {
            final isActive = manager.activeBoard?.id == board.id;
            return _BoardTile(
              board: board,
              isActive: isActive,
              statusLabel: isActive ? _statusLabel(manager.status) : null,
              statusColor:
                  isActive ? _statusColor(manager.status, cs) : null,
              onTap: () => manager.setActiveBoard(board),
              onDelete: () => _confirmRemove(board),
            );
          }),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(),
          ),

          // ── Add new board ──────────────────────────────────────────────────
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.primaryContainer,
              child: Icon(Icons.add, color: cs.primary),
            ),
            title: const Text('Add new board'),
            subtitle: const Text('Scan for nearby LoRa boards via Bluetooth'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ScanScreen(manager: manager),
              ),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Board tile ─────────────────────────────────────────────────────────────────

class _BoardTile extends StatelessWidget {
  final Board board;
  final bool isActive;
  final String? statusLabel;
  final Color? statusColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _BoardTile({
    required this.board,
    required this.isActive,
    required this.statusLabel,
    required this.statusColor,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            isActive ? cs.primaryContainer : cs.surfaceContainerHighest,
        child: Icon(
          Icons.developer_board,
          color: isActive ? cs.primary : cs.outline,
        ),
      ),
      title: Text(
        board.name,
        style: isActive
            ? TextStyle(fontWeight: FontWeight.w600, color: cs.primary)
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            board.id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.outline),
          ),
          if (isActive && statusLabel != null)
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 4, top: 2),
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(
                  statusLabel!,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: statusColor),
                ),
              ],
            ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        color: cs.error,
        tooltip: 'Remove board',
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}
