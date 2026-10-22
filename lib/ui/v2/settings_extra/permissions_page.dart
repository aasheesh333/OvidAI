import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2PermissionsStatus { loading, ready, empty, error }

/// What the operating system reports for one permission.
///
/// These are the four answers `permission_handler` can give, kept distinct
/// because the action differs: a permission that can still be asked for shows
/// the system dialog, a permanently denied one can only be changed in the OS
/// settings, and a granted one has no action at all.
enum V2PermissionAccess {
  /// Never requested. The system dialog can still be shown.
  notAsked,

  /// Requested once and refused. The system dialog can be shown again.
  denied,

  /// Refused for good (or restricted by device policy). Only the OS settings
  /// screen can change it, so asking again would be a no-op.
  permanentlyDenied,

  /// The OS granted it.
  granted;

  /// The pre-split name for [permanentlyDenied]. Call sites that predate the
  /// four-state model keep compiling; new code uses [permanentlyDenied].
  static const V2PermissionAccess blocked = permanentlyDenied;
}

/// One device permission Ovid may need, with the real OS state.
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

  /// Why the permission exists. Not rendered: the row is name + state on one
  /// line (contract §3), so this stays as caller-side documentation.
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

  /// The permissions the app actually asks for, each carrying the state the
  /// platform reported when this snapshot was read. Never a stored guess.
  final List<V2PermissionItem> permissions;

  /// Called with the permission id when the user taps an askable row. The
  /// caller runs the real OS request dialog.
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
/// the real status and at most one action.
///
/// Every row reflects what Android reports. The page only renders the injected
/// snapshot; the route re-reads it when the app resumes, so a grant made in
/// system settings shows up without reopening the screen.
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

  /// A permission changed outside the app (the request dialog or the OS
  /// settings screen) is only visible after re-reading the platform.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) data.onRefresh?.call();
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Permissions',
      // One 640 dp column: rows never stretch into a desktop line.
      maxWidth: 640,
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
      emptyTitle: 'No permissions found',
      emptyBody: 'The system reported no permissions.',
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

  /// One permission, one line: name and the state the OS reported. The row is
  /// the action only when there is something left to do — ask, or open the OS
  /// settings for a permission that can no longer be asked for. A granted
  /// permission has no action, so it is announced as plain information.
  Widget _permissionRow(BuildContext context, V2PermissionItem item) {
    final view = _rowView(item);
    final rowKey = switch (item.status) {
      V2PermissionAccess.notAsked ||
      V2PermissionAccess.denied => 'permission-request-${item.id}',
      V2PermissionAccess.permanentlyDenied => 'permission-settings-${item.id}',
      V2PermissionAccess.granted => 'permission-status-${item.id}',
    };
    return Semantics(
      container: true,
      // One node per row: "Camera, not asked, Requests camera access, button".
      // Without excludeSemantics TalkBack reads the title and the pill twice.
      label: '${item.name}, ${view.state}',
      hint: view.hint,
      button: view.onTap == null ? null : true,
      enabled: view.onTap == null ? null : true,
      onTap: view.onTap,
      excludeSemantics: true,
      child: V2SettingsRow(
        key: ValueKey<String>(rowKey),
        icon: item.icon,
        danger: item.status == V2PermissionAccess.permanentlyDenied,
        title: item.name,
        showChevron: false,
        stacksTrailing: true,
        onTap: view.onTap,
        trailing: OPill(label: view.label, tone: view.tone, dot: true),
      ),
    );
  }

  /// Maps the real state to its visible pill, spoken state and only legal
  /// action. Nothing here can act when the platform offers no next step.
  _PermissionRowView _rowView(V2PermissionItem item) {
    final canRequest = data.onRequest != null;
    final canOpenSettings =
        data.onOpenSettingsFor != null || data.onOpenSettings != null;
    final askHint = canRequest
        ? 'Requests ${item.name.toLowerCase()} access'
        : null;
    return switch (item.status) {
      V2PermissionAccess.notAsked => _PermissionRowView(
        label: 'Not asked',
        state: 'not asked',
        tone: OPillTone.neutral,
        hint: askHint,
        onTap: canRequest ? () => _request(item.id) : null,
      ),
      V2PermissionAccess.denied => _PermissionRowView(
        label: 'Denied',
        state: 'denied',
        tone: OPillTone.warn,
        hint: askHint,
        onTap: canRequest ? () => _request(item.id) : null,
      ),
      V2PermissionAccess.permanentlyDenied => _PermissionRowView(
        label: 'Blocked',
        state: 'blocked in system settings',
        tone: OPillTone.danger,
        hint: canOpenSettings ? 'Opens app settings to allow access' : null,
        onTap: canOpenSettings ? () => _openSettings(item.id) : null,
      ),
      V2PermissionAccess.granted => const _PermissionRowView(
        label: 'Granted',
        state: 'granted',
        tone: OPillTone.success,
      ),
    };
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

/// The rendered form of one permission state.
@immutable
class _PermissionRowView {
  const _PermissionRowView({
    required this.label,
    required this.state,
    required this.tone,
    this.hint,
    this.onTap,
  });

  /// The pill: three words at most (contract §3).
  final String label;

  /// The spoken state, part of the row's semantics label.
  final String state;
  final OPillTone tone;

  /// What the action will do, announced with the row.
  final String? hint;
  final VoidCallback? onTap;
}
