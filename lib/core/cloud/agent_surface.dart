/// The `AgentSurface` seam (P8 Task 8).
///
/// The ONE interface `chat_screen.dart` binds to when Task 10 swaps
/// `AgentService.I` for `CloudAgentFacade.I` behind
/// `Distribution.cloudExecution`. Both implementations satisfy it:
///
///  * `AgentService` — the local execution stack (implements this additively;
///    its body is untouched until the Task 12+ deletion waves);
///  * `CloudAgentFacade` — the thin client (REST + WS projection).
///
/// Signatures are copied from the LIVE `agent_service.dart` members at the
/// anchors the plan measured. The surface conforms to AgentService, not the
/// other way around (plan Task 8 Step 4) — when they disagree, this file is
/// wrong. The 21 members are the 20 surviving chat_screen call-site members
/// (worklist §1C) plus [busyListenable] (sidebar.dart:1203, Task 10).
///
/// Deliberately NOT on the surface (their call sites die in Tasks 10/13):
/// `requestBatteryExemption`, `workspaceRootFor`, `skillUnavailableReason`,
/// `sessionRepoFull`, `hostDirOf`, and the legacy no-arg `approve` (its two
/// chat_screen sites are re-pointed onto [approveRequest] in Task 10).
library;

import 'package:flutter/foundation.dart';

import '../agent_service.dart';
import '../state.dart';

/// The AgentService-shaped surface consumed by the thin-client UI.
abstract class AgentSurface extends ChangeNotifier {
  /// The foreground session's access mode.
  AgentMode get mode;

  /// Sets [m] for [sessionId] (the foreground session when null).
  void setMode(AgentMode m, {String? sessionId});

  /// True while [sessionId] has a run in flight.
  bool busyFor(String sessionId);

  /// Per-session busy flag for list rows.
  ValueListenable<bool> busyListenable(String sessionId);

  /// Stops [sessionId]'s run; returns whether a queued continuation survived.
  bool stopRequested({required String sessionId});

  /// Stops every live run everywhere.
  void hardStopAll();

  /// Starts a turn. The local-only parameters ([freshTurn],
  /// [expandRefsFor], [scheduledTask]) are accepted for AgentService parity;
  /// the cloud facade forwards only the prompt and attachments.
  Future<void> runTask(
    String originalPrompt, {
    String? sessionId,
    bool freshTurn = true,
    ChatSession? expandRefsFor,
    List<({String name, String path, int size})>? attachments,
    Map<String, dynamic>? scheduledTask,
  });

  /// Live status line for [sessionId] ("retrying in 9s…"), or null.
  String? statusFor(String sessionId);

  /// Ticks once per live-bubble stream publication for [sessionId].
  ValueListenable<int> liveBubbleTicksFor(String sessionId);

  /// The foreground session's pending approval, if any.
  ApprovalRequest? get pendingApproval;

  /// Approvals waiting in sessions other than the foreground one.
  List<({String sessionId, String title, ApprovalRequest request})>
      get pendingApprovalsElsewhere;

  /// Resolves [req] only if it is still the pending approval.
  bool approveRequest(ApprovalRequest req, bool ok, {String? note});

  /// Resolves [req] with "always allow"; false when it is no longer pending.
  bool approveAlwaysRequest(ApprovalRequest req);

  /// Plan mode for the foreground session.
  bool get planMode;
  set planMode(bool v);

  /// Files staged for the foreground session's next turn.
  List<({String name, String path, int size})> get pendingAttachments;

  /// Files still being prepared; the composer shows a placeholder per file.
  int get stagingAttachmentCount;

  /// Stages a local file for the next turn. Returns a human-readable error
  /// string, or null on success.
  Future<String?> attachFile(String sourcePath, String fileName,
      {String? sessionId});

  /// Removes one staged file by path.
  void removeAttachment(String path);

  /// Clears every staged file (after send).
  void clearAttachment();

  /// Live background jobs for [sessionId]. The record shape is the LIVE
  /// AgentService signature (`agent_service.dart` jobsFor); the plan sketch
  /// said `List<BgJob>`, but conformance to AgentService wins (Step 4).
  List<({int id, String name, String state, int elapsedSec, int outChars})>
      jobsFor(String sessionId);

  /// Measured context tokens for [s] (0 on the facade until P3 usage lands).
  int measuredContextTokens(ChatSession s, {String systemPrompt = ''});
}
