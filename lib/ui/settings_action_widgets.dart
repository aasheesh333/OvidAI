import 'package:flutter/material.dart';
import '../core/settings_actions.dart';
import '../core/theme.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// Settings actions allow long labels to wrap at large accessibility text sizes.
/// Unlike compact toolbar controls, these have a minimum rather than fixed height.
class SettingsActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  const SettingsActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ],
    );
    final style = TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    if (primary || danger) {
      return FilledButton(
        onPressed: onPressed,
        style: style.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => (danger ? Aether.danger : Aether.accent).withValues(
              alpha: states.contains(WidgetState.disabled) ? .4 : 1,
            ),
          ),
        ),
        child: child,
      );
    }
    return OutlinedButton(onPressed: onPressed, style: style, child: child);
  }
}

class SettingsSwitchTile extends StatefulWidget {
  final IconData icon;
  final String title, subtitleOn, subtitleOff;
  final Listenable listenable;
  final bool Function() getter;
  final Future<void> Function(bool)? setter;
  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitleOn,
    required this.subtitleOff,
    required this.listenable,
    required this.getter,
    this.setter,
  });
  @override
  State<SettingsSwitchTile> createState() => _SettingsSwitchTileState();
}

class _SettingsSwitchTileState extends State<SettingsSwitchTile> {
  bool _busy = false;
  String? _error;
  bool? _retryValue;
  Future<void> _save(bool value) async {
    if (_busy || widget.setter == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.setter!(value);
      _retryValue = null;
    } catch (_) {
      _retryValue = value;
      _error =
          'Could not save ${widget.title}. Change may be session-only. Tap to retry.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.listenable,
    // A11Y: one semantics node, so TalkBack reads "<title>, <subtitle>,
    // switch, on/off" instead of an unlabeled "Switch, off".
    builder: (_, _) => MergeSemantics(
      child: ListTile(
      dense: true,
      leading: Icon(widget.icon, size: 19, color: Aether.textMuted),
      title: Text(widget.title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        _error ??
            (_busy
                ? 'Saving…'
                : widget.getter()
                ? widget.subtitleOn
                : widget.subtitleOff),
        style: TextStyle(
          fontSize: 12.5,
          color: _error == null ? Aether.textFaint : Aether.danger,
        ),
      ),
      trailing: Switch(
        value: widget.getter(),
        activeTrackColor: Aether.accent,
        onChanged: _busy || widget.setter == null ? null : _save,
      ),
      onTap: _busy || widget.setter == null
          ? null
          : () => _save(_retryValue ?? !widget.getter()),
    ),
    ),
  );
}

class SettingsResetScreen extends StatefulWidget {
  final Future<SettingsResetResult> Function()? reset;

  /// Opens chat export; offered as "Export my chats first" in the confirm.
  final VoidCallback? onExport;

  /// Opens the account-deletion flow — the only path that deletes CLOUD data
  /// (SE-003). Offered as a separate, clearly labelled action.
  final VoidCallback? onDeleteAccount;
  const SettingsResetScreen({
    super.key,
    this.reset,
    this.onExport,
    this.onDeleteAccount,
  });
  @override
  State<SettingsResetScreen> createState() => _SettingsResetScreenState();
}

class _SettingsResetScreenState extends State<SettingsResetScreen> {
  bool _busy = false;
  String? _result;
  Future<void> _delete() async {
    if (_busy) return;
    final reset = widget.reset ?? SettingsActions.resetAll;
    if (reset == null) return;
    final onExport = widget.onExport;
    final confirmed = await showAetherConfirmDialog(
      context,
      title: 'Clear this device?',
      message:
          'This removes from THIS device: cached chats and their search '
          'index, unsent drafts, settings, API keys and tokens saved on the '
          'device, image receipts, and local backups. It also stops this '
          "device's notifications and signs you out.\n\n"
          'Not deleted: your Ovid account and everything in Ovid Cloud — '
          'your chats, files, schedules and shared links come back when you '
          'sign in again. To delete those, use Delete my account. '
          'Clearing this device cannot be undone.',
      confirmLabel: 'Clear this device',
      typeToConfirm: 'DELETE',
      extra: onExport == null
          ? null
          : Builder(
              builder: (dialogContext) => OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Export my chats first'),
                onPressed: () {
                  Navigator.pop(dialogContext, false);
                  onExport();
                },
              ),
            ),
    );
    if (!confirmed || !mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final report = await reset();
      if (!mounted) return;
      if (report.success) {
        const done =
            'This device was cleared. Your cloud chats are kept in Ovid Cloud.';
        setState(() => _result = done);
        // The reset signs out, so the gate under this stack now shows the
        // login screen. Return there instead of leaving signed-out settings
        // screens on top.
        messenger?.showSnackBar(const SnackBar(content: Text(done)));
        navigator.popUntil((route) => route.isFirst);
        return;
      }
      setState(
        () => _result =
            'Incomplete reset. ${report.completed.length} store(s) completed.\n'
            '${report.failures.entries.map((e) => '${e.key}: ${e.value}').join('\n')}'
            '${report.failures.isEmpty ? '\nCompletion could not be verified.' : ''}\nRetry to finish.',
      );
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _result = 'Reset failed; some data may remain. Retry to finish.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = (widget.reset ?? SettingsActions.resetAll) != null;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Clear this device'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AetherSectionTitle(
            eyebrow: 'This device',
            subtitle: 'Signs out and removes local cache. Your cloud chats '
                'are kept.',
          ),
          const SizedBox(height: 12),
          AetherCard(
            title: const Text('Clear this device'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _busy
                      ? 'Deletion in progress'
                      : available
                      ? 'Ready'
                      : 'Unavailable',
                  style: AetherType.label,
                ),
                const SizedBox(height: 8),
                Text(
                  available
                      ? 'Removes cached chats, drafts, settings and keys stored on this device, and signs you out. Everything in Ovid Cloud stays in your account. Any incomplete removal is reported for retry.'
                      : 'Clearing this device is unavailable in this build. Nothing has been deleted.',
                  style: AetherType.body,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SettingsActionButton(
            label: _busy ? 'Clearing…' : 'Clear this device',
            icon: Icons.phonelink_erase_outlined,
            danger: true,
            onPressed: _busy || !available ? null : _delete,
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(
              semanticsLabel: 'Clearing this device',
            ),
          ],
          if (widget.onDeleteAccount != null) ...[
            const SizedBox(height: 24),
            AetherCard(
              title: const Text('Delete my cloud data'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your chats, files, schedules, shared links and saved '
                    'keys live in Ovid Cloud. Deleting them means deleting '
                    'your Ovid account.',
                    style: AetherType.body,
                  ),
                  const SizedBox(height: 12),
                  SettingsActionButton(
                    key: const ValueKey('reset-delete-account'),
                    label: 'Delete my account…',
                    icon: Icons.person_remove_outlined,
                    onPressed: _busy ? null : widget.onDeleteAccount,
                  ),
                ],
              ),
            ),
          ],
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SelectableText(_result!, style: AetherType.body),
            ),
        ],
      ),
    );
  }
}
