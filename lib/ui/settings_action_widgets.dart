import 'package:flutter/material.dart';
import '../core/settings_actions.dart';
import '../core/theme.dart';
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
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              (danger ? Aether.danger : Aether.accent)
                  .withValues(alpha: states.contains(WidgetState.disabled) ? .4 : 1)),
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
    builder: (_, _) => ListTile(
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
          fontSize: 11.5,
          color: _error == null ? Aether.textFaint : Aether.dangerC,
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
  );
}

class SettingsResetScreen extends StatefulWidget {
  final Future<SettingsResetResult> Function()? reset;
  const SettingsResetScreen({super.key, this.reset});
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Delete ALL data?'),
        content: const Text(
          'Remove app-owned chats, credentials, settings and local data. This cannot be undone. External user folders are excluded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final report = await reset();
      if (!mounted) return;
      setState(
        () => _result = report.success
            ? 'All data deleted.'
            : 'Incomplete reset. ${report.completed.length} store(s) completed.\n'
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
      appBar: AppBar(title: const Text('Delete app data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AetherSectionTitle(
            eyebrow: 'Reset',
            subtitle: 'Permanent, local-only erase of app-owned data.',
          ),
          const SizedBox(height: 12),
          AetherCard(
            title: const Text('Delete app data'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _busy ? 'Deletion in progress' : available ? 'Ready' : 'Unavailable',
                  style: AetherType.label,
                ),
                const SizedBox(height: 8),
                Text(
              available
                  ? 'Deletes app-owned data after stopping active writers. Any incomplete removal is reported for retry.'
                  : 'Full reset unavailable in this build: the verified all-store reset worker is not connected. No data has been deleted.',
              style: AetherType.body,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SettingsActionButton(
            label: _busy ? 'Deleting…' : 'Delete all data',
            icon: Icons.delete_forever_outlined,
            danger: true,
            onPressed: _busy || !available ? null : _delete,
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(semanticsLabel: 'Deleting app data'),
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
