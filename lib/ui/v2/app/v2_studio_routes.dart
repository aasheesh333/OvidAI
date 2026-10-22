import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/chat_integration_ports.dart';
import '../../../core/cloud/studio_files.dart';
import '../../../core/cloud/studio_remote_client.dart';
import '../../../core/state.dart';
import '../../design/o_components.dart';
import '../../studio_errors.dart';
import '../studio/branch_picker_sheet.dart';
import '../studio/changes_page.dart';
import '../studio/live_preview_page.dart';
import '../studio/studio_workspace_page.dart';
import 'v2_work_routes.dart';

/// Routes for the Studio workspace extras.
///
/// Repository and branch data come from the installed [StudioBindingPort].
/// When no port is installed the screens open in their empty state instead of
/// showing a repository that is not really bound.
///
/// Files, open tabs and editor buffers come from [StudioRemoteClient], the
/// app's cloud-workspace service. There is no git status/diff or preview
/// client on the app side yet, so changed counts, the sync badge and the
/// changes list stay empty rather than inventing numbers.
class V2StudioRoutes {
  const V2StudioRoutes._();

  static Future<void> openWorkspace(
    BuildContext context,
    String repo,
    String branch, {
    String? sessionId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _StudioWorkspaceHost(
          repo: repo,
          branch: branch,
          sessionId: sessionId,
        ),
      ),
    );
  }

  /// Opens the branch picker sheet for [repo]. [onSelect] receives the branch
  /// name the user picked; null when the port has no branches to offer.
  static Future<void> openBranchPicker(
    BuildContext context,
    String repo,
    String branch,
    ValueChanged<String>? onSelect,
  ) async {
    final port = StudioBindingPort.instance;
    var data = branchPickerDataFor(
      currentBranch: branch,
      branches: const [],
      portReady: port?.ready ?? false,
    );
    if (port != null && port.ready) {
      try {
        final branches = await port.listBranches(repo);
        data = branchPickerDataFor(
          currentBranch: branch,
          branches: branches,
          portReady: true,
        );
      } catch (_) {
        data = branchPickerDataFor(
          currentBranch: branch,
          branches: const [],
          portReady: true,
          failed: true,
        );
      }
    }
    if (!context.mounted) return;
    await showOSheet<void>(
      context,
      builder: (sheetContext) => V2BranchPickerSheet(
        data: data,
        showHandle: false,
        onSelectBranch: (selected) {
          Navigator.of(sheetContext).pop();
          onSelect?.call(selected.name);
        },
      ),
    );
  }

  /// Opens the changes screen. There is no app-side diff source yet, so the
  /// screen shows its honest empty state; no commit/sync/copy handlers are
  /// supplied because there is nothing for them to act on.
  static Future<void> openChanges(
    BuildContext context,
    String repo,
    String branch,
  ) async {
    final port = StudioBindingPort.instance;
    final data = changesDataFor(
      branch: branch,
      portReady: port?.ready ?? false,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => V2ChangesPage(
          data: data,
          onBack: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// Opens the live preview screen. No preview client exists yet, so the
  /// screen keeps its waiting state and supplies no refresh/share/stop
  /// handlers (the page hides controls without a handler).
  static Future<void> openLivePreview(
    BuildContext context,
    String repo,
    String branch,
  ) async {
    final port = StudioBindingPort.instance;
    final data = livePreviewDataFor(
      repo: repo,
      portReady: port?.ready ?? false,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => V2LivePreviewPage(data: data)),
    );
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  /// The workspace opens on the bound repo/branch, with the real cloud
  /// workspace tree and the active editor buffer when the service has them.
  ///
  /// [snapshot] and [tabs] come from [StudioRemoteClient]; [loading] is true
  /// while the first tree read is in flight. Changed-file counts and
  /// [V2StudioWorkspaceData.syncCount] stay 0 because the app has no git
  /// status source to read them from.
  @visibleForTesting
  static V2StudioWorkspaceData workspaceDataFor({
    required String repo,
    required String branch,
    required bool portReady,
    StudioTreeSnapshot? snapshot,
    StudioTabsState tabs = StudioTabsState.empty,
    bool loading = false,
    String? errorMessage,
  }) {
    final name = repo.trim();
    final branchName = branch.trim();
    if (!portReady || name.isEmpty) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: '',
        status: V2WorkspaceStatus.empty,
      );
    }
    if (errorMessage != null) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: branchName,
        status: V2WorkspaceStatus.error,
        errorMessage: errorMessage,
      );
    }
    if (loading && snapshot == null) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: branchName,
        status: V2WorkspaceStatus.loading,
      );
    }

    final openPath = tabs.activePath ?? '';
    final content = openPath.isEmpty ? null : tabs.buffer[openPath];
    final rawLines = content == null || content.isEmpty
        ? const <String>[]
        : content.split('\n');
    return V2StudioWorkspaceData(
      repoName: name,
      branch: branchName,
      fileTree: snapshot == null
          ? const <V2FileNode>[]
          : fileNodesFrom(snapshot.root.children),
      openFileName: openPath.isEmpty ? '' : openPath.split('/').last,
      openFilePath: openPath,
      codeLines: [
        for (var i = 0; i < rawLines.length; i++)
          V2CodeLine(number: i + 1, text: rawLines[i]),
      ],
      saved: openPath.isEmpty || !tabs.dirtyPaths.contains(openPath),
    );
  }

  /// Maps the cloud workspace manifest onto the v2 tree.
  ///
  /// The v2 tree only represents folders through their children, so a folder
  /// the server pruned (or an empty one) is omitted rather than rendered as a
  /// tappable file that would fail to open.
  @visibleForTesting
  static List<V2FileNode> fileNodesFrom(List<FileNode> nodes) {
    final result = <V2FileNode>[];
    for (final node in nodes) {
      if (!node.isDir) {
        result.add(V2FileNode(name: node.name, path: node.path));
        continue;
      }
      final children = fileNodesFrom(node.children);
      if (children.isEmpty) continue;
      result.add(
        V2FileNode(name: node.name, path: node.path, children: children),
      );
    }
    return result;
  }

  /// Real branch names when the port can list them, empty otherwise.
  @visibleForTesting
  static V2BranchPickerData branchPickerDataFor({
    required String currentBranch,
    required List<String> branches,
    required bool portReady,
    bool failed = false,
  }) {
    final current = currentBranch.trim();
    if (failed) {
      return V2BranchPickerData(
        status: V2BranchPickerStatus.error,
        current: null,
        branches: const [],
        errorMessage:
            'We could not load branches for this repository. Check your '
            'connection and try again.',
      );
    }
    if (!portReady || branches.isEmpty) {
      return V2BranchPickerData(
        status: V2BranchPickerStatus.empty,
        current: null,
        branches: const [],
      );
    }
    return V2BranchPickerData(
      status: V2BranchPickerStatus.content,
      current: current.isEmpty ? null : V2Branch(name: current),
      branches: [
        for (final name in branches)
          V2Branch(name: name, isCurrent: name == current),
      ],
    );
  }

  /// No diff source exists yet, so the changes screen opens empty with the
  /// bound branch as its only real label.
  @visibleForTesting
  static V2ChangesData changesDataFor({
    required String branch,
    required bool portReady,
  }) {
    final label = portReady ? branch.trim() : '';
    return V2ChangesData(
      status: V2ChangesStatus.empty,
      branchLabel: label.isEmpty ? null : label,
    );
  }

  /// No preview URL source exists yet; the screen opens in its start state.
  @visibleForTesting
  static V2LivePreviewData livePreviewDataFor({
    required String repo,
    required bool portReady,
  }) {
    // No preview client is wired yet. The screen says so plainly and draws no
    // controls, rather than painting an empty frame that looks loaded.
    return V2LivePreviewData(
      status: V2PreviewStatus.unavailable,
      siteName: portReady ? repo.trim() : '',
      unavailableReason: 'Live preview is not connected yet.',
    );
  }
}

/// Human copy for a Studio failure. [StudioAccessException] already carries
/// a person-readable message; everything else goes through the shared mapper
/// so raw exception text never reaches a snackbar.
String _studioErrorText(Object error) => error is StudioAccessException
    ? error.message
    : StudioFailure.messageOf(error);

/// Hosts the workspace page so picking a branch rebuilds it with the chosen
/// branch; the screen itself stays presentational.
class _StudioWorkspaceHost extends StatefulWidget {
  const _StudioWorkspaceHost({
    required this.repo,
    required this.branch,
    this.sessionId,
  });

  final String repo;
  final String branch;
  final String? sessionId;

  @override
  State<_StudioWorkspaceHost> createState() => _StudioWorkspaceHostState();
}

class _StudioWorkspaceHostState extends State<_StudioWorkspaceHost> {
  late String _branch;

  /// False until the first tree read finishes, so the page shows its loading
  /// skeleton instead of an empty tree while the request is in flight.
  bool _loaded = false;
  bool _syncing = false;

  /// The cloud workspace is per user, not per chat (R2), so every Studio
  /// surface reads the same bucket.
  String get _workspaceKey =>
      studioWorkspaceKeyFor(AppState.I.sessionAccountId);

  StudioRemoteClient get _remote => StudioRemoteClient.I;

  @override
  void initState() {
    super.initState();
    _branch = widget.branch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(covariant _StudioWorkspaceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branch != widget.branch) _branch = widget.branch;
  }

  Future<void> _load() async {
    final port = StudioBindingPort.instance;
    if (!(port?.ready ?? false)) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    await _remote.refreshWorkspace(_workspaceKey);
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  /// Runs the port's real sync and reports what actually happened. A missing
  /// session or port is reported as such, never as a silent no-op.
  Future<void> _sync() async {
    if (_syncing) return;
    final sessionId = widget.sessionId;
    final port = StudioBindingPort.instance;
    if (sessionId == null) {
      showOSnack(context, 'Open Studio from a chat to sync.');
      return;
    }
    if (port == null || !port.ready) {
      showOSnack(context, 'Connect GitHub to sync.');
      return;
    }
    setState(() => _syncing = true);
    try {
      await port.syncLatest(sessionId);
      await _remote.refreshWorkspace(_workspaceKey);
      if (!mounted) return;
      showOSnack(context, 'Sync finished.');
    } catch (error) {
      if (!mounted) return;
      showOSnack(context, _studioErrorText(error));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Binds the chosen branch on the session too, so the chat's STUDIO gate and
  /// the workspace always name the same branch.
  Future<void> _switchBranch(String branch) async {
    final sessionId = widget.sessionId;
    final port = StudioBindingPort.instance;
    if (sessionId != null && port != null && port.ready) {
      try {
        await port.bind(sessionId, repo: widget.repo, branch: branch);
      } catch (error) {
        if (!mounted) return;
        showOSnack(context, _studioErrorText(error));
        return;
      }
    }
    if (!mounted) return;
    setState(() => _branch = branch);
    unawaited(_load());
  }

  Future<void> _selectFile(String path) async {
    try {
      await _remote.openStudioFile(_workspaceKey, path);
    } catch (error) {
      if (!mounted) return;
      showOSnack(context, _studioErrorText(error));
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _copyFile() async {
    final path = _remote.activeFilePath(_workspaceKey);
    final content = path == null
        ? null
        : _remote.fileBuffer(_workspaceKey)[path];
    if (content == null) {
      showOSnack(context, 'No file open.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    showOSnack(context, 'Copied file.');
  }

  Future<void> _pickRepo() async {
    await V2WorkRoutes.openRepoPicker(context);
    if (!mounted) return;
    final port = StudioBindingPort.instance;
    if (port?.ready ?? false) {
      setState(() => _loaded = false);
      await _load();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final port = StudioBindingPort.instance;
    final ready = port?.ready ?? false;
    return AnimatedBuilder(
      animation: Listenable.merge([
        _remote,
        _remote.tabsFor(_workspaceKey),
        ?port,
      ]),
      builder: (context, _) {
        final snapshot = ready ? _remote.snapshotFor(_workspaceKey) : null;
        final failure = ready ? _remote.treeFailure(_workspaceKey) : null;
        final noWorkspace = ready && _remote.hasNoWorkspace(_workspaceKey);
        final loading =
            ready && (!_loaded || _remote.treeLoading(_workspaceKey));
        final error = failure == null || noWorkspace
            ? null
            : StudioFailure.forTree(failure).message;
        return V2StudioWorkspacePage(
          data: V2StudioRoutes.workspaceDataFor(
            repo: widget.repo,
            branch: _branch,
            portReady: ready,
            snapshot: snapshot,
            tabs: ready
                ? _remote.tabsState(_workspaceKey)
                : StudioTabsState.empty,
            loading: loading,
            errorMessage: error,
          ),
          onBranchTap: () => V2StudioRoutes.openBranchPicker(
            context,
            widget.repo,
            _branch,
            (selected) => unawaited(_switchBranch(selected)),
          ),
          onSync: _sync,
          onSelectFile: (path) => unawaited(_selectFile(path)),
          onCommit: () =>
              V2StudioRoutes.openChanges(context, widget.repo, _branch),
          onPreview: () =>
              V2StudioRoutes.openLivePreview(context, widget.repo, _branch),
          onPickRepo: () => unawaited(_pickRepo()),
          onRetry: () => unawaited(_load()),
          onCopyFile: () => unawaited(_copyFile()),
        );
      },
    );
  }
}
