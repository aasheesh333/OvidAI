import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2PermissionsStatus { loading, ready, empty, error }

enum V2PermissionAccess { granted, notAsked, blocked }

/// One device permission Ovid may need, with a plain-language reason.
@immutable
class V2PermissionItem {
  const V2PermissionItem({
    required this.id,
    required this.name,
    required this.reason,
    required this.status,
    required this.icon,
  });

  final String id;
  final String name;
  final String reason;
  final V2PermissionAccess status;
  final IconData icon;
}

/// Injected state for the Permissions screen.
@immutable
class V2PermissionsPageData {
  const V2PermissionsPageData({
    this.status = V2PermissionsStatus.ready,
    this.permissions = const <V2PermissionItem>[],
    this.onRequest,
    this.onOpenSettings,
    this.onOpenSettingsFor,
    this.onResetAll,
    this.onRefresh,
    this.onRetry,
    this.errorMessage = 'We could not load your permissions.',
  });

  final V2PermissionsStatus status;
  final List<V2PermissionItem> permissions;

  /// Called with the permission id when the user taps Request. The caller
  /// runs the real OS request dialog.
  final ValueChanged<String>? onRequest;
  final VoidCallback? onOpenSettings;

  /// Opens the Android settings page for one permission (camera, microphone,
  /// photos, notifications, files) instead of the app's own page. Falls back
  /// to [onOpenSettings] when a caller cannot target a single permission.
  final ValueChanged<String>? onOpenSettingsFor;

  /// Revokes every device permission Ovid asked for. Android asks again the
  /// next time a task needs one.
  final VoidCallback? onResetAll;

  /// Re-reads the real permission state. Called when the app returns to the
  /// foreground, because the user may have changed a grant in Android
  /// settings while this screen was open.
  final VoidCallback? onRefresh;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Camera, microphone, photos, notifications and files, with plain reasons.
///
/// Every row must reflect what Android reports. The page itself only renders
/// the injected status; the route reloads it when the app resumes so a grant
/// made in system settings shows up without reopening the screen.
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key, required this.data});

  final V2PermissionsPageData data;

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with WidgetsBindingObserver {
  V2PermissionsPageData get data => widget.data;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) data.onRefresh?.call();
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Permissions'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.status == V2PermissionsStatus.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 5));
    }
    if (data.status == V2PermissionsStatus.error) {
      return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
    }
    if (data.status == V2PermissionsStatus.empty || data.permissions.isEmpty) {
      return OEmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'No permissions to review',
        message: 'Ovid has not needed anything on this device yet.',
        action: OButton(
          label: 'Open Android settings',
          icon: Icons.settings_outlined,
          onPressed: data.onOpenSettings,
        ),
      );
    }
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _explainer(context),
            _permissionList(context),
            _resetSection(context),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _explainer(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: OCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                Icons.lock_outline_rounded,
                size: 21,
                color: c.accent,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ovid only asks when it needs something.',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    'You can say no at any time. Ovid will ask again only if a '
                    'task needs it.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionList(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Device access',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < data.permissions.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  _permissionRow(context, data.permissions[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionRow(BuildContext context, V2PermissionItem item) {
    final c = OColors.of(context);
    final (statusLabel, statusColor) = switch (item.status) {
      V2PermissionAccess.granted => ('Granted', c.success),
      V2PermissionAccess.notAsked => ('Not asked', c.textMuted),
      V2PermissionAccess.blocked => ('Blocked', c.danger),
    };
    final statusBackground = switch (item.status) {
      V2PermissionAccess.granted => c.success.withValues(alpha: 0.12),
      V2PermissionAccess.notAsked => c.surfaceAlt,
      V2PermissionAccess.blocked => c.danger.withValues(alpha: 0.12),
    };
    final canOpen =
        data.onOpenSettingsFor != null || data.onOpenSettings != null;
    final action = item.status == V2PermissionAccess.notAsked
        ? OButton(
            key: ValueKey<String>('permission-request-${item.id}'),
            label: 'Request',
            semanticLabel: 'Request ${item.name} access',
            variant: OButtonVariant.ghost,
            onPressed: data.onRequest == null ? null : () => _request(item.id),
          )
        : OButton(
            key: ValueKey<String>('permission-settings-${item.id}'),
            label: 'Open settings',
            semanticLabel: 'Open settings for ${item.name}',
            variant: OButtonVariant.ghost,
            onPressed: canOpen ? () => _openSettings(item.id) : null,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  item.icon,
                  size: 19,
                  color: item.status == V2PermissionAccess.blocked
                      ? c.danger
                      : c.textMuted,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: OType.body.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.reason,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              _pill(
                context,
                label: statusLabel,
                foreground: statusColor,
                background: statusBackground,
              ),
              action,
            ],
          ),
        ],
      ),
    );
  }

  /// Asks the OS for one permission, then reloads so the row shows the real
  /// answer instead of the old snapshot.
  void _request(String id) {
    data.onRequest?.call(id);
    data.onRefresh?.call();
  }

  void _openSettings(String id) {
    final perPermission = data.onOpenSettingsFor;
    if (perPermission != null) {
      perPermission(id);
      return;
    }
    data.onOpenSettings?.call();
  }

  Widget _pill(
    BuildContext context, {
    required String label,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: OSpace.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: foreground,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resetSection(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Reset',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: OListRow(
              key: const ValueKey('reset-all-permissions-row'),
              icon: Icons.restart_alt_rounded,
              title: 'Reset all permissions',
              subtitle:
                  'Revoke camera, microphone, photos, notifications and files',
              danger: true,
              enabled: data.onResetAll != null,
              onTap: data.onResetAll == null
                  ? null
                  : () => _confirmResetAll(context),
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'Android asks again the next time a task needs one. '
            'Chats and files are not deleted.',
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmResetAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final c = OColors.of(context);
        final names = data.permissions.map((item) => item.name).join(', ');
        return AlertDialog(
          scrollable: true,
          backgroundColor: c.surface,
          icon: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.danger.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.restart_alt_rounded, color: c.danger),
          ),
          title: Text(
            'Reset all permissions?',
            style: OType.h2.copyWith(color: c.text),
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                names.isEmpty
                    ? 'Ovid will lose every device permission it has.'
                    : 'Ovid will lose access to $names.',
                style: OType.bodySm.copyWith(color: c.text),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                'Android asks again the next time a task needs one. '
                'This does not delete chats, files or memory.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('reset-all-permissions-confirm'),
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: c.danger,
                foregroundColor: c.onDanger,
                minimumSize: const Size(0, OSpace.touch),
              ),
              child: const Text('Reset all'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) data.onResetAll?.call();
  }

  Widget _footer(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OButton(
          label: 'Open Android settings',
          icon: Icons.settings_outlined,
          variant: OButtonVariant.secondary,
          expand: true,
          onPressed: data.onOpenSettings,
        ),
        if (data.onRefresh != null) ...[
          const SizedBox(height: OSpace.s),
          OButton(
            key: const ValueKey<String>('permissions-refresh'),
            label: 'Refresh status',
            icon: Icons.refresh_rounded,
            variant: OButtonVariant.ghost,
            expand: true,
            onPressed: data.onRefresh,
          ),
        ],
        const SizedBox(height: OSpace.m),
        Text(
          'Ovid uses these only while it works on your request. '
          'You can change them any time in Android settings.',
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(color: c.textFaint),
        ),
      ],
    );
  }
}
