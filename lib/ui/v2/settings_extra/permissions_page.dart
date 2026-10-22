import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';

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
    this.onRefresh,
    this.onRetry,
    this.errorMessage = 'We could not load your permissions.',
  });

  final V2PermissionsStatus status;
  final List<V2PermissionItem> permissions;

  /// Called with the permission id when the user taps Allow. The caller runs
  /// the real OS request dialog.
  final ValueChanged<String>? onRequest;
  final VoidCallback? onOpenSettings;

  /// Opens the Android settings page for one permission (camera, microphone,
  /// photos, notifications, files) instead of the app's own page. Falls back
  /// to [onOpenSettings] when a caller cannot target a single permission.
  final ValueChanged<String>? onOpenSettingsFor;

  /// Re-reads the real permission state. Called when the app returns to the
  /// foreground, because the user may have changed a grant in Android
  /// settings while this screen was open.
  final VoidCallback? onRefresh;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Camera, microphone, photos, notifications and files: one row each, with
/// the real status and one action.
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
    return OScreen(
      title: 'Permissions',
      actions: [
        if (data.onRefresh != null)
          OIconButton(
            key: const ValueKey<String>('permissions-refresh'),
            icon: Icons.refresh_rounded,
            semanticLabel: 'Refresh status',
            onPressed: data.onRefresh,
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final status = switch (data.status) {
      V2PermissionsStatus.loading => OStatus.loading,
      V2PermissionsStatus.error => OStatus.error,
      V2PermissionsStatus.empty => OStatus.empty,
      V2PermissionsStatus.ready => data.permissions.isEmpty
          ? OStatus.empty
          : OStatus.content,
    };
    return OStateView(
      status: status,
      errorMessage: data.errorMessage,
      onRetry: data.onRetry,
      emptyTitle: 'No permissions to review',
      emptyBody: 'Nothing has needed access yet.',
      emptyActionLabel: 'Open settings',
      onEmptyAction: data.onOpenSettings,
      skeletonRows: 5,
      child: ListView.separated(
        padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
        itemCount: data.permissions.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          indent: v2SettingsRowDividerIndent,
          color: OColors.of(context).hairline,
        ),
        itemBuilder: (context, index) =>
            _permissionRow(context, data.permissions[index]),
      ),
    );
  }

  /// One permission, one action. A not-asked permission asks; anything else
  /// opens its Android settings page. The status pill is the row's value.
  Widget _permissionRow(BuildContext context, V2PermissionItem item) {
    final (statusLabel, tone) = switch (item.status) {
      V2PermissionAccess.granted => ('Granted', OPillTone.success),
      V2PermissionAccess.notAsked => ('Not asked', OPillTone.neutral),
      V2PermissionAccess.blocked => ('Blocked', OPillTone.danger),
    };
    final canOpen =
        data.onOpenSettingsFor != null || data.onOpenSettings != null;
    final notAsked = item.status == V2PermissionAccess.notAsked;
    final onTap = notAsked
        ? (data.onRequest == null ? null : () => _request(item.id))
        : (canOpen ? () => _openSettings(item.id) : null);

    return V2SettingsRow(
      key: ValueKey<String>(
        notAsked
            ? 'permission-request-${item.id}'
            : 'permission-settings-${item.id}',
      ),
      icon: item.icon,
      danger: item.status == V2PermissionAccess.blocked,
      title: item.name,
      showChevron: false,
      stacksTrailing: true,
      enabled: onTap != null || item.status == V2PermissionAccess.granted,
      onTap: onTap,
      trailing: OPill(label: statusLabel, tone: tone, dot: true),
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
}
