import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/chat_integration_ports.dart';
import '../../../core/cloud/studio_files.dart';
import '../../../core/cloud/studio_git_api.dart';
import '../../../core/cloud/studio_preview_client.dart';
import '../../../core/cloud/studio_remote_client.dart';
import '../../../core/state.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../../studio_errors.dart';
import '../studio/branch_picker_sheet.dart';
import '../studio/changes_page.dart';
import '../studio/live_preview_page.dart';
import '../studio/preview_web_view.dart';
import '../studio/studio_workspace_page.dart';
import 'v2_run_routes.dart';
import 'v2_work_routes.dart';

/// Routes for the Studio workspace extras.
///
/// Repository and branch data come from the installed [StudioBindingPort].
/// When no port is installed the screens open in their empty state instead of
/// showing a repository that is not really bound.
///
/// Files, open tabs and editor buffers come from [StudioRemoteClient]. Git
/// status/diff records come from the canonical gateway readers; unavailable
/// values stay null instead of becoming placeholder zeroes. Preview is a
/// separate ticket-bound native surface, never an arbitrary URL proxy.
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

  /// Opens real local status + diff when the session has a server binding.
  /// There is no commit gateway, so this remains a review-only surface.
  static Future<void> openChanges(
    BuildContext context,
    String repo,
    String branch, {
    String? sessionId,
    bool loadGit = false,
  }) async {
    final port = StudioBindingPort.instance;
    final canLoad = loadGit && sessionId != null && (port?.ready ?? false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => canLoad
            ? _StudioChangesHost(
                branch: branch,
                sessionId: sessionId,
                onBack: () => Navigator.of(routeContext).maybePop(),
              )
            : V2ChangesPage(
                data: changesDataFor(
                  branch: branch,
                  portReady: port?.ready ?? false,
                  errorMessage: 'Changes are unavailable for this workspace.',
                ),
                onBack: () => Navigator.of(routeContext).maybePop(),
              ),
      ),
    );
  }

  /// Opens the preview surface. Start is available only with an explicit
  /// server-issued [registration]; there is no script-name default and no
  /// host/port/upstream/command input. The current gateway has no capability
  /// route, so normal production navigation receives no start control.
  static Future<void> openLivePreview(
    BuildContext context,
    String repo,
    String branch, {
    String? sessionId,
    StudioPreviewRegistration? registration,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _StudioPreviewHost(
          repo: repo,
          sessionId: sessionId,
          registration: registration,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  /// The workspace opens on the bound repo/branch, with the real cloud
  /// workspace tree and the active editor buffer when the service has them.
  ///
  /// [snapshot] and [tabs] come from [StudioRemoteClient]; [loading] is true
  /// while the first tree read is in flight. [gitStatus] and [diff] supply
  /// actual records. Counts are emitted only for a complete, non-truncated
  /// patch whose status proves a clean tree; dirty/unknown/untracked coverage
  /// stays null rather than inventing a smaller change set.
  @visibleForTesting
  static V2StudioWorkspaceData workspaceDataFor({
    required String repo,
    required String branch,
    required bool portReady,
    StudioTreeSnapshot? snapshot,
    StudioTabsState tabs = StudioTabsState.empty,
    bool loading = false,
    bool gitAvailable = true,
    String? errorMessage,
    StudioGitStatus? gitStatus,
    StudioDiff? diff,
  }) {
    final name = repo.trim();
    final branchName = branch.trim();
    if (!portReady || name.isEmpty) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: '',
        status: V2WorkspaceStatus.empty,
        filesChanged: null,
        additions: null,
        deletions: null,
        syncCount: null,
      );
    }
    if (errorMessage != null) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: branchName,
        status: V2WorkspaceStatus.error,
        filesChanged: null,
        additions: null,
        deletions: null,
        syncCount: gitStatus?.behind,
        gitAvailable: gitAvailable,
        errorMessage: errorMessage,
      );
    }
    if (loading && snapshot == null) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: branchName,
        status: V2WorkspaceStatus.loading,
        filesChanged: null,
        additions: null,
        deletions: null,
        syncCount: gitStatus?.behind,
        gitAvailable: gitAvailable,
      );
    }

    final openPath = tabs.activePath ?? '';
    final content = openPath.isEmpty ? null : tabs.buffer[openPath];
    final rawLines = content == null || content.isEmpty
        ? const <String>[]
        : content.split('\n');
    final countsKnown =
        diff != null && !diff.truncated && gitStatus?.dirty == false;
    final changed = diff == null
        ? null
        : _changedFilesFromDiff(diff, countsUnknown: diff.truncated);
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
      filesChanged: changed == null || !countsKnown ? null : changed.length,
      additions: changed == null || !countsKnown
          ? null
          : _knownDiffTotal(changed.map((file) => file.additions)),
      deletions: changed == null || !countsKnown
          ? null
          : _knownDiffTotal(changed.map((file) => file.deletions)),
      syncCount: gitStatus?.behind,
      saved: openPath.isEmpty || !tabs.dirtyPaths.contains(openPath),
      gitAvailable: gitAvailable,
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

  /// Maps the real status/diff responses onto all four changes states.
  @visibleForTesting
  static V2ChangesData changesDataFor({
    required String branch,
    required bool portReady,
    StudioGitStatus? gitStatus,
    StudioDiff? diff,
    bool loading = false,
    String? errorMessage,
  }) {
    final label = portReady ? branch.trim() : '';
    final branchLabel = label.isEmpty ? null : label;
    if (errorMessage != null) {
      return V2ChangesData(
        status: V2ChangesStatus.error,
        branchLabel: branchLabel,
        behindCount: gitStatus?.behind,
        totalsKnown: false,
        errorMessage: errorMessage,
      );
    }
    if (loading) {
      return V2ChangesData(
        status: V2ChangesStatus.loading,
        branchLabel: branchLabel,
        behindCount: gitStatus?.behind,
        totalsKnown: false,
      );
    }
    if (diff == null) {
      return V2ChangesData(
        status: V2ChangesStatus.error,
        branchLabel: branchLabel,
        behindCount: gitStatus?.behind,
        totalsKnown: false,
        errorMessage: 'Changes have not been loaded.',
      );
    }
    final countsKnown = !diff.truncated && gitStatus?.dirty == false;
    final files = _changedFilesFromDiff(diff, countsUnknown: diff.truncated);
    final knownEmpty = files.isEmpty && countsKnown;
    return V2ChangesData(
      status: knownEmpty
          ? V2ChangesStatus.empty
          : files.isEmpty
          ? V2ChangesStatus.error
          : V2ChangesStatus.content,
      files: files,
      branchLabel: branchLabel,
      behindCount: gitStatus?.behind,
      totalsKnown: countsKnown,
      coverageWarning: files.isEmpty || countsKnown
          ? null
          : gitStatus?.dirty == true
          ? 'The full change set is unavailable. Untracked files and their '
                'contents are not included; overall totals are unknown.'
          : 'Complete diff coverage could not be verified. Untracked files '
                'and their contents may be missing; overall totals are unknown.',
      errorMessage: knownEmpty || files.isNotEmpty
          ? null
          : gitStatus?.dirty == true
          ? 'This repository has changes, but the full diff is not available.'
          : 'The complete change set is not available.',
    );
  }

  /// Fallback data when no server-bound project can start a preview. The
  /// stateful route host replaces this with real registration/launch data.
  @visibleForTesting
  static V2LivePreviewData livePreviewDataFor({
    required String repo,
    required bool portReady,
  }) {
    // Without a server-bound project the route keeps its honest unavailable
    // state; the stateful host adds real controls only when they can act.
    return V2LivePreviewData(
      status: V2PreviewStatus.unavailable,
      siteName: portReady ? repo.trim() : '',
      unavailableReason: 'Live preview is not connected yet.',
    );
  }
}

int? _knownDiffTotal(Iterable<int?> values) {
  var total = 0;
  for (final value in values) {
    if (value == null) return null;
    total += value;
  }
  return total;
}

List<V2ChangedFile> _changedFilesFromDiff(
  StudioDiff diff, {
  required bool countsUnknown,
}) {
  final parsed = <_ChangedFileBuilder>[];
  if (diff.parts.isEmpty) {
    parsed.addAll(_parseDiffBuilders(diff.patch));
  } else {
    for (final part in diff.parts) {
      parsed.addAll(
        _parseDiffBuilders(
          part.patch,
          scopeLabel: part.staged ? 'Staged' : 'Unstaged',
        ),
      );
    }
  }

  // A path is one row even when it appears in both source patches. Arithmetic
  // is the sum of actual stage-relative edits, not an invented net Git diff.
  final merged = <String, _ChangedFileBuilder>{};
  for (final file in parsed) {
    if (file.path.isEmpty) continue;
    final existing = merged[file.path];
    if (existing == null) {
      merged[file.path] = file;
    } else {
      existing.absorb(file);
    }
  }
  final files = merged.values.toList(growable: false);
  return <V2ChangedFile>[
    for (var index = 0; index < files.length; index++)
      files[index].build(
        countsUnknown: countsUnknown,
        initiallyExpanded: index == 0,
      ),
  ];
}

List<_ChangedFileBuilder> _parseDiffBuilders(
  String patch, {
  String? scopeLabel,
}) {
  final builders = <_ChangedFileBuilder>[];
  _ChangedFileBuilder? current;
  final lines = patch.split('\n');
  for (var index = 0; index < lines.length; index++) {
    if (index == lines.length - 1 && lines[index].isEmpty) break;
    final line = lines[index];
    if (line.startsWith('diff --git ')) {
      current = _ChangedFileBuilder(scopeLabel: scopeLabel)
        ..readFileMarker(line);
      builders.add(current);
      continue;
    }
    final file = current;
    if (file == null) continue;
    if (file.activeHunk == null &&
        (line.startsWith('--- ') || line.startsWith('+++ '))) {
      file.readFileMarker(line);
      continue;
    }
    final hunk = RegExp(
      r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@',
    ).firstMatch(line);
    if (hunk != null) {
      file.startHunk(
        line,
        int.parse(hunk.group(1)!),
        int.parse(hunk.group(2)!),
      );
      continue;
    }
    if (file.activeHunk != null) file.readDiffLine(line);
  }
  for (final builder in builders) {
    builder.finishHunk();
  }
  return builders;
}

class _ChangedFileBuilder {
  _ChangedFileBuilder({String? scopeLabel})
    : hunkScope = scopeLabel,
      hasStagedChanges = scopeLabel == 'Staged',
      hasUnstagedChanges = scopeLabel == 'Unstaged';

  final String? hunkScope;
  bool hasStagedChanges;
  bool hasUnstagedChanges;
  String path = '';
  String previousPath = '';
  int additions = 0;
  int deletions = 0;
  final List<V2DiffHunk> hunks = <V2DiffHunk>[];
  String? activeHunk;
  List<V2DiffLine> _lines = <V2DiffLine>[];
  int _oldLine = 0;
  int _newLine = 0;

  void readFileMarker(String line) {
    if (line.startsWith('diff --git ')) {
      final split = line.lastIndexOf(' b/');
      if (line.startsWith('diff --git a/') && split > 0) {
        previousPath = line.substring('diff --git a/'.length, split);
        path = line.substring(split + 3);
      }
      return;
    }
    final marker = line.substring(0, 4);
    var value = line.substring(4);
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    if (value == '/dev/null') return;
    if (value.startsWith('a/') || value.startsWith('b/')) {
      value = value.substring(2);
    }
    if (marker == '--- ') {
      previousPath = value;
      if (path.isEmpty) path = value;
    } else if (marker == '+++ ') {
      path = value;
    }
  }

  void startHunk(String header, int oldStart, int newStart) {
    finishHunk();
    activeHunk = header;
    _lines = <V2DiffLine>[];
    _oldLine = oldStart;
    _newLine = newStart;
  }

  void readDiffLine(String line) {
    if (line.startsWith('\\')) return;
    if (line.startsWith('+')) {
      additions++;
      _lines.add(
        V2DiffLine(
          kind: V2DiffKind.added,
          text: line.substring(1),
          newNumber: _newLine++,
        ),
      );
      return;
    }
    if (line.startsWith('-')) {
      deletions++;
      _lines.add(
        V2DiffLine(
          kind: V2DiffKind.removed,
          text: line.substring(1),
          oldNumber: _oldLine++,
        ),
      );
      return;
    }
    final text = line.startsWith(' ') ? line.substring(1) : line;
    _lines.add(
      V2DiffLine(
        kind: V2DiffKind.context,
        text: text,
        oldNumber: _oldLine++,
        newNumber: _newLine++,
      ),
    );
  }

  void finishHunk() {
    final header = activeHunk;
    if (header == null) return;
    hunks.add(
      V2DiffHunk(
        header: header,
        lines: List<V2DiffLine>.of(_lines),
        scopeLabel: hunkScope,
      ),
    );
    activeHunk = null;
    _lines = <V2DiffLine>[];
  }

  void absorb(_ChangedFileBuilder other) {
    additions += other.additions;
    deletions += other.deletions;
    hunks.addAll(other.hunks);
    hasStagedChanges = hasStagedChanges || other.hasStagedChanges;
    hasUnstagedChanges = hasUnstagedChanges || other.hasUnstagedChanges;
  }

  String? get scopeLabel {
    if (hasStagedChanges && hasUnstagedChanges) return 'Staged + unstaged';
    if (hasStagedChanges) return 'Staged';
    if (hasUnstagedChanges) return 'Unstaged';
    return null;
  }

  V2ChangedFile build({
    required bool countsUnknown,
    required bool initiallyExpanded,
  }) {
    finishHunk();
    final slash = path.lastIndexOf('/');
    return V2ChangedFile(
      path: path,
      directory: slash <= 0 ? '' : path.substring(0, slash),
      additions: countsUnknown ? null : additions,
      deletions: countsUnknown ? null : deletions,
      hunks: List<V2DiffHunk>.unmodifiable(hunks),
      initiallyExpanded: initiallyExpanded,
      scopeLabel: scopeLabel,
    );
  }
}

/// Human copy for a Studio failure. Typed errors already carry safe copy;
/// everything else goes through the shared mapper so raw exception text never
/// reaches a snackbar.
String _studioErrorText(Object error) {
  if (error is StudioAccessException) return error.message;
  if (error is StudioGitUnavailableException) return error.message;
  if (error is StudioPreviewException) return error.message;
  return StudioFailure.messageOf(error);
}

class _StudioChangesHost extends StatefulWidget {
  const _StudioChangesHost({
    required this.branch,
    required this.sessionId,
    required this.onBack,
  });

  final String branch;
  final String sessionId;
  final VoidCallback onBack;

  @override
  State<_StudioChangesHost> createState() => _StudioChangesHostState();
}

class _StudioChangesHostState extends State<_StudioChangesHost> {
  late final StudioGitApi _git = StudioGitApi();
  bool _loading = true;
  String? _error;
  StudioGitStatus? _status;
  StudioDiff? _diff;
  int _operation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final operation = ++_operation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final status = await _git.status(widget.sessionId);
      final diff = await _git.combinedDiff(widget.sessionId);
      if (!mounted || operation != _operation) return;
      setState(() {
        _status = status;
        _diff = diff;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() {
        _error = _studioErrorText(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = V2StudioRoutes.changesDataFor(
      branch: widget.branch,
      portReady: true,
      gitStatus: _status,
      diff: _diff,
      loading: _loading,
      errorMessage: _error,
    );
    return V2ChangesPage(
      data: data,
      onBack: widget.onBack,
      onRetry: data.status == V2ChangesStatus.error && _error != null
          ? () => unawaited(_load())
          : null,
    );
  }
}

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
  late final StudioGitApi _git = StudioGitApi();
  StudioGitStatus? _gitStatus;
  StudioDiff? _diff;
  String? _repoDir;

  /// False until the first tree read finishes, so the page shows its loading
  /// skeleton instead of an empty tree while the request is in flight.
  bool _loaded = false;
  bool _syncing = false;

  /// `GET …/git`'s capability flag. False means the deployment has no git
  /// transport yet; the header then draws no sync control.
  bool _gitAvailable = true;

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
    final sessionId = widget.sessionId;
    _repoDir = null;
    _gitStatus = null;
    _diff = null;
    // The gateway is the authority on both "is GitHub connected" and "can
    // this deployment run git". Both reads are best-effort: a failed read
    // leaves the workspace in its empty state, never in a false "bound" one.
    if (port != null) {
      try {
        await port.loadConnection();
      } catch (_) {
        // No connection: the page below shows its honest empty state.
      }
      if (sessionId != null) {
        try {
          final git = await port.loadSessionGit(sessionId);
          if (git != null) {
            _gitAvailable = git.available;
            final binding = git.binding;
            _repoDir = binding?.repoDir;
            if (_repoDir == null) {
              _gitStatus = null;
              _diff = null;
            }
            if (binding != null && mounted) {
              setState(() => _branch = binding.branch);
            }
          }
        } catch (_) {
          // Keep the capability we already knew; draw no new claim.
        }
      }
    }
    if (!(port?.ready ?? false)) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    await _refreshGit();
    if (!mounted) return;
    await _remote.refreshWorkspace(_workspaceKey);
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _refreshGit({bool fetch = true}) async {
    final sessionId = widget.sessionId;
    if (sessionId == null || !_gitAvailable || _repoDir == null) {
      _gitStatus = null;
      _diff = null;
      return;
    }
    try {
      final status = fetch
          ? await _git.inspect(sessionId)
          : await _git.status(sessionId);
      final diff = await _git.combinedDiff(sessionId);
      if (!mounted) return;
      setState(() {
        _gitStatus = status;
        _diff = diff;
      });
    } catch (_) {
      // Ancillary git reads never replace a usable workspace with an error.
      // Unknown counts remain null and render as an em dash.
      if (!mounted) return;
      setState(() {
        _gitStatus = null;
        _diff = null;
      });
    }
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
    final binding = port.bindingFor(sessionId);
    if (binding == null || !binding.ready) {
      // The port's sync is a no-op without a binding; saying "finished" would
      // report a sync that never happened.
      showOSnack(context, 'Bind a repository and branch to sync.');
      return;
    }
    setState(() => _syncing = true);
    try {
      await port.syncLatest(sessionId);
      await _refreshGit(fetch: false);
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

  /// Switches the branch through the gateway's git service. A refusal (no
  /// transport, dirty tree, failed switch) is reported verbatim and the
  /// displayed branch is left untouched, so the header never names a branch
  /// the workspace is not on.
  Future<void> _switchBranch(String branch) async {
    final sessionId = widget.sessionId;
    final port = StudioBindingPort.instance;
    if (sessionId == null) {
      showOSnack(context, 'Open Studio from a chat to switch branches.');
      return;
    }
    if (port == null || !port.ready) {
      showOSnack(context, 'Connect GitHub to switch branches.');
      return;
    }
    try {
      await port.switchBranch(sessionId, branch: branch);
    } catch (error) {
      if (!mounted) return;
      showOSnack(context, _studioErrorText(error));
      return;
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
        void openChanges() {
          unawaited(
            V2StudioRoutes.openChanges(
              context,
              widget.repo,
              _branch,
              sessionId: widget.sessionId,
              loadGit: _repoDir != null && _gitAvailable,
            ),
          );
        }

        void openPreview() {
          unawaited(
            V2StudioRoutes.openLivePreview(
              context,
              widget.repo,
              _branch,
              sessionId: widget.sessionId,
            ),
          );
        }

        final page = V2StudioWorkspacePage(
          data: V2StudioRoutes.workspaceDataFor(
            repo: widget.repo,
            branch: _branch,
            portReady: ready,
            snapshot: snapshot,
            tabs: ready
                ? _remote.tabsState(_workspaceKey)
                : StudioTabsState.empty,
            loading: loading,
            gitAvailable: _gitAvailable,
            errorMessage: error,
            gitStatus: _gitStatus,
            diff: _diff,
          ),
          onBranchTap: () => V2StudioRoutes.openBranchPicker(
            context,
            widget.repo,
            _branch,
            (selected) => unawaited(_switchBranch(selected)),
          ),
          onSync: _sync,
          onSelectFile: (path) => unawaited(_selectFile(path)),
          onCommit: openChanges,
          onPreview: openPreview,
          onPickRepo: () => unawaited(_pickRepo()),
          onRetry: () => unawaited(_load()),
          onCopyFile: () => unawaited(_copyFile()),
          // Read-only: the session's real run log (steps, tools, tokens).
          // Studio never exposes a shell or PTY to the user.
          onViewRuns: widget.sessionId == null
              ? null
              : () => V2RunRoutes.openTrajectory(context, widget.sessionId!),
        );
        if (!ready || widget.repo.trim().isEmpty || _branch.trim().isEmpty) {
          return page;
        }
        return Column(
          children: [
            Expanded(child: page),
            _StudioDestinationBar(
              onChanges: openChanges,
              onPreview: openPreview,
            ),
          ],
        );
      },
    );
  }
}

/// Production navigation to the separate Studio destinations. The standalone
/// presentational workspace keeps its old API, while the real host supplies
/// this consumer instead of leaving callbacks unused.
class _StudioDestinationBar extends StatelessWidget {
  const _StudioDestinationBar({
    required this.onChanges,
    required this.onPreview,
  });

  final VoidCallback onChanges;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final colors = OColors.of(context);
    return ColoredBox(
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.xs,
            OSpace.l,
            OSpace.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: OTextAction(
                  key: const Key('studio-open-changes'),
                  label: 'Changes',
                  icon: Icons.difference_outlined,
                  onPressed: onChanges,
                ),
              ),
              Expanded(
                child: OTextAction(
                  key: const Key('studio-open-preview'),
                  label: 'Live preview',
                  icon: Icons.play_circle_outline_rounded,
                  onPressed: onPreview,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudioPreviewHost extends StatefulWidget {
  const _StudioPreviewHost({
    required this.repo,
    required this.sessionId,
    required this.registration,
  });

  final String repo;
  final String? sessionId;
  final StudioPreviewRegistration? registration;

  @override
  State<_StudioPreviewHost> createState() => _StudioPreviewHostState();
}

class _StudioPreviewHostState extends State<_StudioPreviewHost>
    with WidgetsBindingObserver {
  late final StudioPreviewClient _client = StudioPreviewClient.I;
  V2PreviewStatus _status = V2PreviewStatus.unavailable;
  StudioPreview? _preview;
  StudioPreviewLaunch? _launch;
  String? _error;
  Timer? _poll;
  int _pollAttempts = 0;
  int _operation = 0;
  int _launchGeneration = 0;
  bool _stopping = false;
  bool _retryStop = false;
  bool _restartAfterFailure = false;

  bool get _canStart => widget.sessionId != null && widget.registration != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_stop());
    }
  }

  Future<void> _start() async {
    if (!_canStart || _stopping) return;
    final operation = ++_operation;
    _poll?.cancel();
    _pollAttempts = 0;
    _retryStop = false;
    _restartAfterFailure = false;
    setState(() {
      _status = V2PreviewStatus.connecting;
      _error = null;
      _launch = null;
    });
    try {
      final registration = widget.registration!;
      final preview = await _client.create(
        widget.sessionId!,
        projectDir: registration.projectDir,
        startScriptId: registration.startScriptId,
      );
      if (!mounted || operation != _operation) {
        unawaited(_client.stop(preview.id));
        return;
      }
      _preview = preview;
      final opened = await _client.open(preview.id);
      if (!mounted || operation != _operation) return;
      _applyOpen(opened, operation);
    } catch (error) {
      if (!mounted || operation != _operation) return;
      _showError(error);
    }
  }

  Future<void> _refresh({bool polling = false}) async {
    final preview = _preview;
    if (preview == null || _stopping) return;
    final operation = polling ? _operation : ++_operation;
    if (!polling) {
      _poll?.cancel();
      _pollAttempts = 0;
      setState(() {
        _status = V2PreviewStatus.connecting;
        _error = null;
        _launch = null;
      });
    }
    try {
      final opened = await _client.refresh(preview.id);
      if (!mounted || operation != _operation) return;
      _applyOpen(opened, operation);
    } catch (error) {
      if (!mounted || operation != _operation) return;
      _showError(error);
    }
  }

  void _applyOpen(StudioPreviewOpen opened, int operation) {
    if (operation != _operation) return;
    _preview = opened.preview;
    switch (opened.preview.status) {
      case StudioPreviewStatus.running:
        _restartAfterFailure = false;
        final launch = opened.launch;
        if (launch == null) {
          _error = 'The preview did not provide a valid launch. Try again.';
          _status = V2PreviewStatus.error;
          _launch = null;
        } else {
          _launch = launch;
          _launchGeneration++;
          _status = V2PreviewStatus.connecting;
          _error = null;
        }
        _poll?.cancel();
        break;
      case StudioPreviewStatus.starting:
      case StudioPreviewStatus.stopping:
        _launch = null;
        _status = V2PreviewStatus.connecting;
        _error = null;
        _schedulePoll();
        break;
      case StudioPreviewStatus.failed:
        _launch = null;
        _restartAfterFailure = true;
        _status = V2PreviewStatus.error;
        _error = 'The preview server could not start.';
        _poll?.cancel();
        break;
      case StudioPreviewStatus.expired:
        _launch = null;
        _restartAfterFailure = false;
        _status = V2PreviewStatus.expired;
        _error = 'This preview session ended.';
        _poll?.cancel();
        break;
      case StudioPreviewStatus.stopped:
        _preview = null;
        _launch = null;
        _status = V2PreviewStatus.unavailable;
        _error = null;
        _poll?.cancel();
        break;
    }
    if (mounted) setState(() {});
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_pollAttempts++ >= 30) {
      _status = V2PreviewStatus.error;
      _error = 'The preview took too long to start. Try again.';
      return;
    }
    _poll = Timer(const Duration(seconds: 1), () {
      if (mounted) unawaited(_refresh(polling: true));
    });
  }

  Future<void> _stop() async {
    if (_stopping) return;
    final operation = ++_operation;
    _poll?.cancel();
    _pollAttempts = 0;
    final preview = _preview;
    setState(() {
      _stopping = true;
      _launch = null;
      _error = null;
      _status = preview == null
          ? V2PreviewStatus.unavailable
          : V2PreviewStatus.connecting;
    });
    if (preview == null) {
      _stopping = false;
      return;
    }
    try {
      await _client.stop(preview.id);
      if (!mounted || operation != _operation) return;
      setState(() {
        _preview = null;
        _status = V2PreviewStatus.unavailable;
        _stopping = false;
        _retryStop = false;
      });
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() {
        _stopping = false;
        _retryStop = true;
        _status = V2PreviewStatus.error;
        _error = 'The preview could not be stopped. Try again.';
      });
    }
  }

  Future<void> _expire() async {
    if (_stopping) return;
    final operation = ++_operation;
    final previous = _preview;
    _poll?.cancel();
    _pollAttempts = 0;
    setState(() {
      _stopping = true;
      _preview = null;
      _launch = null;
      _status = V2PreviewStatus.expired;
      _error = 'This preview session ended.';
      _restartAfterFailure = false;
    });
    if (previous != null) {
      try {
        await _client.stop(previous.id);
      } catch (_) {
        // The server-side absolute/idle expiry remains authoritative. The old
        // terminal id is never reused for a new launch.
      }
    }
    if (!mounted || operation != _operation) return;
    setState(() => _stopping = false);
  }

  Future<void> _restartFailedPreview() async {
    if (_stopping) return;
    final previous = _preview;
    _operation++;
    _poll?.cancel();
    setState(() {
      _stopping = true;
      _preview = null;
      _launch = null;
      _status = V2PreviewStatus.connecting;
      _error = null;
    });
    if (previous != null) {
      try {
        await _client.stop(previous.id);
      } catch (_) {
        // A terminal failed registration cannot be opened again. Create a new
        // registration after the best-effort cleanup instead of refreshing it.
      }
    }
    if (!mounted) return;
    _stopping = false;
    return _start();
  }

  Future<void> _retry() {
    if (_restartAfterFailure) return _restartFailedPreview();
    if (_retryStop) return _stop();
    return _preview == null ? _start() : _refresh();
  }

  void _showError(Object error) {
    setState(() {
      _launch = null;
      _status = V2PreviewStatus.error;
      _error = _studioErrorText(error);
    });
  }

  void _nativeLoaded(int generation) {
    if (!mounted || generation != _launchGeneration) return;
    setState(() => _status = V2PreviewStatus.live);
  }

  void _nativeError(int generation, String code) {
    if (!mounted || generation != _launchGeneration) return;
    setState(() {
      _launch = null;
      _status = V2PreviewStatus.error;
      _error = switch (code) {
        'ticket_replay' =>
          'That preview ticket was already used. Refresh to continue.',
        'cross_tenant' || 'preview_denied' => 'That preview is not available.',
        'unsupported_renderer' =>
          'This device cannot show the isolated preview.',
        _ => 'The preview could not be loaded. Try again.',
      };
    });
  }

  DateTime? get _deadline {
    final values = <DateTime>[?_preview?.expiresAt, ?_launch?.cookieExpiresAt];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _operation++;
    final preview = _preview;
    if (preview != null && !_stopping) {
      unawaited(_client.stop(preview.id));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final launch = _launch;
    final generation = _launchGeneration;
    final webView = preview != null && launch != null
        ? StudioPreviewWebView(
            key: ValueKey<String>('${preview.id}:$generation'),
            previewId: preview.id,
            launch: launch,
            kind: preview.kind,
            onLoaded: () => _nativeLoaded(generation),
            onError: (code) => _nativeError(generation, code),
            onHibernate: () => unawaited(_stop()),
          )
        : null;
    return V2LivePreviewPage(
      data: V2LivePreviewData(
        status: _status,
        siteName: widget.repo,
        url: preview != null && launch != null
            ? launch.cleanUrl(preview.id)
            : '',
        webView: webView,
        expiresAt: _deadline,
        errorMessage: _error,
        unavailableReason: _canStart
            ? 'Start an isolated preview for this project.'
            : 'Live preview is not connected yet.',
      ),
      onReload: _status == V2PreviewStatus.live
          ? () => unawaited(_refresh())
          : null,
      onStop: _status == V2PreviewStatus.live ? () => unawaited(_stop()) : null,
      onCancel: _status == V2PreviewStatus.connecting && !_stopping
          ? () => unawaited(_stop())
          : null,
      onRetry: _status == V2PreviewStatus.error
          ? () => unawaited(_retry())
          : null,
      onExpired: () => unawaited(_expire()),
      onStart:
          (_status == V2PreviewStatus.unavailable ||
                  _status == V2PreviewStatus.expired) &&
              _canStart &&
              !_stopping
          ? () => unawaited(_start())
          : null,
    );
  }
}
