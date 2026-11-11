import 'package:flutter/material.dart';

import '../services/board_manager.dart';
import '../models/board.dart';
import '../theme.dart';
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

  Future<void> _rename(Board board) async {
    final ctrl = TextEditingController(text: board.name);
    String? error;
    bool busy = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> submit() async {
            final name = ctrl.text.trim();
            final invalid = BoardManager.validateName(name);
            if (invalid != null) {
              setLocal(() => error = invalid);
              return;
            }
            if (name == board.name) {
              Navigator.pop(ctx);
              return;
            }
            setLocal(() {
              busy = true;
              error = null;
            });
            try {
              await widget.manager.renameActiveBoard(name);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Saved on board. New name is advertised '
                      'after the next disconnect.'),
                ));
              }
            } catch (e) {
              setLocal(() {
                busy = false;
                error = '$e';
              });
            }
          }

          return AlertDialog(
            title: const Text('rename board'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  enabled: !busy,
                  maxLength: BoardManager.maxNameLength,
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                    hintText: '> name',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'stored in board memory and shown on its OLED',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: const Text('cancel'),
              ),
              FilledButton(
                onPressed: busy ? null : submit,
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('save'),
              ),
            ],
          );
        },
      ),
    );
    ctrl.dispose();
  }

  // ── Status helpers ─────────────────────────────────────────────────────────

  String _statusLabel(ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected    => 'connected',
        ConnectionStatus.connecting   => 'connecting...',
        ConnectionStatus.disconnected => 'disconnected',
      };

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final boards  = manager.boards;
    final cs      = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: BunnyBackground(
        child: ListView(
        children: [
          // ── My Boards section ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              '// my boards',
              style: TextStyle(
                  color: cs.onSurface, fontWeight: FontWeight.w700),
            ),
          ),

          if (boards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'No boards registered yet.',
                style: TextStyle(color: cs.outline),
              ),
            ),

          ...boards.map((board) {
            final isActive = manager.activeBoard?.id == board.id;
            return _BoardTile(
              board: board,
              isActive: isActive,
              statusLabel: isActive ? _statusLabel(manager.status) : null,
              connected: isActive && manager.isConnected,
              onTap: () => manager.setActiveBoard(board),
              onDelete: () => _confirmRemove(board),
              // Renaming talks to the board, so it needs a live connection.
              onRename: isActive && manager.isConnected
                  ? () => _rename(board)
                  : null,
            );
          }),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(),
          ),

          // ── Add new board ──────────────────────────────────────────────────
          ListTile(
            leading: _IconBox(icon: Icons.add_sharp, active: false),
            title: const Text('+ add new board'),
            subtitle: const Text('scan for boards via bluetooth'),
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
      ),
    );
  }
}

/// Square outlined icon holder; filled when active.
class _IconBox extends StatelessWidget {
  final IconData icon;
  final bool active;
  const _IconBox({required this.icon, required this.active});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: active ? cs.primary : cs.surface,
        border: Border.all(color: cs.primary),
      ),
      child: Icon(icon, color: active ? cs.onPrimary : cs.primary, size: 22),
    );
  }
}

// ── Board tile ─────────────────────────────────────────────────────────────────

class _BoardTile extends StatelessWidget {
  final Board board;
  final bool isActive;
  final String? statusLabel;
  final bool connected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onRename;

  const _BoardTile({
    required this.board,
    required this.isActive,
    required this.statusLabel,
    required this.connected,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      leading: _IconBox(icon: Icons.memory_sharp, active: isActive),
      title: Text(
        '${isActive ? '* ' : ''}${board.name}',
        style: TextStyle(
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w400),
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
                    color: connected ? cs.primary : Colors.transparent,
                    border: Border.all(color: cs.primary),
                  ),
                ),
                Text(
                  statusLabel!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_sharp),
            tooltip: onRename != null
                ? 'Rename board'
                : 'Connect to this board to rename it',
            onPressed: onRename,
          ),
          IconButton(
            icon: const Icon(Icons.close_sharp),
            tooltip: 'Remove board',
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
