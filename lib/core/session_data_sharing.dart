import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_service.dart';
import 'session_browser_profiles.dart';
import 'state.dart';

/// Session data sharing across app restarts.
///
/// The isolation model the app follows is:
///
/// * **During a launch** every chat session is isolated — its own Studio repo,
///   branch, open files and buffers, its own browser tabs, and its own WebView
///   cookie jar (see [SessionBrowserProfiles]).
/// * **On every app restart** the accumulated data is shared ONCE, so a repo
///   connected in chat A and a Google login performed in chat B are available
///   everywhere. After that first sync the sessions diverge again until the
///   next restart.
///
/// Both halves are user-controlled from Settings:
/// `shareStudioOnRestart` (repo/branch) and `shareBrowserOnRestart` (logins).
/// This service is the single place that performs the restart-time sync, so
/// the startup task, the Settings toggles and the "Sync now" action all share
/// one implementation.
class SessionDataSharing extends ChangeNotifier {
  SessionDataSharing._();

  static final SessionDataSharing I = SessionDataSharing._();

  /// Report of the last browser sharing pass (shown in Settings → Data).
  BrowserShareReport? lastBrowserReport;

  /// How many sessions received a repo/branch in the last Studio pass.
  int lastStudioSessions = 0;

  /// Guards against a double run when the startup task and a settings change
  /// race in the same launch.
  bool _browserRan = false;
  bool _studioRan = false;

  /// Every session id the app currently knows, oldest first.
  List<String> get sessionIds =>
      AppState.I.sessions.map((s) => s.id).where((id) => id.isNotEmpty).toList();

  /// The restart-time entry point wired into the startup sequence.
  ///
  /// Runs before any browser tab exists, which is the only moment a deleted
  /// session's profile can actually be removed (the platform refuses while a
  /// live WebView still holds it).
  Future<void> runOnStartup() async {
    try {
      final purged = await SessionBrowserProfiles.I.purgePendingDeletes();
      if (purged > 0) {
        debugPrint('purged $purged orphaned browser profile(s)');
      }
    } catch (error) {
      debugPrint('purgePendingDeletes failed: $error');
    }
    await shareBrowserOnRestart();
    await shareStudioOnRestart();
  }

  /// Copy the previous launch's browser logins into every session profile.
  ///
  /// Runs once per launch (unless [force]). A no-op when the user turned
  /// sharing off or the WebView has no profile support.
  Future<BrowserShareReport> shareBrowserOnRestart({bool force = false}) async {
    if (!force && _browserRan) {
      return lastBrowserReport ?? const BrowserShareReport.nothing('');
    }
    if (!AppState.I.shareBrowserOnRestart) {
      final report = const BrowserShareReport.nothing(
        'Off — each session keeps its own logins.',
      );
      lastBrowserReport = report;
      notifyListeners();
      return report;
    }
    _browserRan = true;
    final report = await SessionBrowserProfiles.I.shareOnRestart(
      sessionIds: sessionIds,
    );
    lastBrowserReport = report;
    notifyListeners();
    return report;
  }

  /// Backfill Studio repo/branch across sessions so a repo connected in one
  /// chat is available in all of them after a restart.
  ///
  /// Sessions that already chose their own repo keep it — this only fills the
  /// gaps (including sessions restored from an older app version), which is
  /// what "shared once on restart, isolated afterwards" means in practice.
  Future<int> shareStudioOnRestart({bool force = false}) async {
    if (!force && _studioRan) return lastStudioSessions;
    if (!AppState.I.shareStudioOnRestart) {
      lastStudioSessions = 0;
      notifyListeners();
      return 0;
    }
    _studioRan = true;
    var filled = 0;
    try {
      final app = AppState.I;
      final repo = app.lastRepoFull;
      final branch = app.lastBranch;
      for (final session in app.sessions) {
        var touched = false;
        if ((session.repo == null || session.repo!.isEmpty) &&
            repo != null &&
            repo.isNotEmpty) {
          session.repo = repo;
          touched = true;
        }
        if ((session.branch == null || session.branch!.isEmpty) &&
            branch.isNotEmpty) {
          session.branch = branch;
          touched = true;
        }
        if (touched) filled++;
      }
      if (filled > 0) {
        await app.persistSessions();
        app.refresh();
      }
      // The active session's Studio view may still point at a cache bound to
      // another session — rebind so the shared repo is actually visible.
      await AgentService.I.refreshStudioBindingForActiveSession();
    } catch (error) {
      debugPrint('shareStudioOnRestart failed: $error');
    }
    lastStudioSessions = filled;
    notifyListeners();
    return filled;
  }
}
