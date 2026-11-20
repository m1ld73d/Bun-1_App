import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/board_manager.dart';
import '../services/crypto_service.dart';
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
    // The dialog owns its text controller (see _RenameDialog) and talks to
    // the board itself; it returns true when the new name was saved.
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RenameDialog(
        manager: widget.manager,
        initialName: board.name,
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Saved on board. New name is advertised '
            'after the next disconnect.'),
      ));
    }
  }

  Future<void> _editKey() async {
    // The dialog owns its text controller and only returns the key; saving
    // happens after it is closed, so nothing rebuilds underneath it.
    final key = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KeyDialog(initialKey: widget.manager.aesKeyHex),
    );
    if (key == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.manager.setAesKey(key);
      messenger.showSnackBar(const SnackBar(
        content: Text('Key saved. Every device must use the '
            'same key to read your messages.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save key: $e')));
    }
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

          // ── Encryption section ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              '// encryption',
              style: TextStyle(
                  color: cs.onSurface, fontWeight: FontWeight.w700),
            ),
          ),
          ListTile(
            leading: _IconBox(
                icon: Icons.lock_sharp, active: !manager.usesDefaultKey),
            title: const Text('aes-256 key'),
            subtitle: Text(
              manager.usesDefaultKey
                  ? 'default key (public) - set your own'
                  : 'custom key  ${manager.aesKeyHex.substring(0, 4)}'
                      '...${manager.aesKeyHex.substring(60)}',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.outline),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit_sharp),
              tooltip: 'Edit encryption key',
              onPressed: _editKey,
            ),
            onTap: _editKey,
          ),
          SwitchListTile(
            secondary: const _IconBox(icon: Icons.visibility_sharp, active: false),
            title: const Text('show undecryptable'),
            subtitle: Text(
              'show messages that failed to decrypt',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.outline),
            ),
            value: manager.showUndecryptable,
            onChanged: manager.setShowUndecryptable,
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

// ── Encryption key dialog ──────────────────────────────────────────────────────

class _KeyDialog extends StatefulWidget {
  final String initialKey;
  const _KeyDialog({required this.initialKey});

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialKey);
  String? _error;
  bool _copied = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final key = _ctrl.text.trim();
    final error = MessageCrypto.validateKey(key);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, key);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _ctrl.text.trim()));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('encryption key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLength: 64,
              minLines: 2,
              maxLines: 3,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
              ],
              onChanged: (_) {
                if (_error != null || _copied) {
                  setState(() {
                    _error = null;
                    _copied = false;
                  });
                }
              },
              decoration: InputDecoration(
                hintText: '> 64 hex characters',
                errorText: _error,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _ctrl.text = MessageCrypto.generateKey();
                    _error = null;
                    _copied = false;
                  }),
                  child: const Text('generate'),
                ),
                TextButton(
                  onPressed: _copy,
                  child: Text(_copied ? 'copied' : 'copy'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'AES-256, 64 hex characters. All devices that should '
              'read your messages need the same key.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('save')),
      ],
    );
  }
}

// ── Rename dialog ──────────────────────────────────────────────────────────────

class _RenameDialog extends StatefulWidget {
  final BoardManager manager;
  final String initialName;
  const _RenameDialog({required this.manager, required this.initialName});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialName);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _ctrl.text.trim();
    final invalid = BoardManager.validateName(name);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (name == widget.initialName) {
      Navigator.pop(context, false);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.manager.renameActiveBoard(name);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('rename board'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            enabled: !_busy,
            maxLength: BoardManager.maxNameLength,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '> name',
              errorText: _error,
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
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('save'),
        ),
      ],
    );
  }
}
