/// The `AgentSurface` seam (P8 Task 8).
///
/// The ONE interface the thin-client UI binds to. `CloudAgentFacade` is its
/// only implementation: P8 Task 19 deleted the retired local execution stack.
///
/// Signatures were copied from the live local service's members at the
/// anchors the plan measured. The surface conforms to that contract, not the
/// other way around (plan Task 8 Step 4) — when they disagree, this file is
/// wrong.
///
/// COVERAGE (review round 1, I-1): the plan's "20 of the measured 26"
/// premise counted only DIRECT singleton member chains. chat_screen also
/// aliased the singleton at 9 sites and calls further members through those
/// aliases (queue dock, context meter, @-mention subagents, browser header).
/// Those are on this surface too, so the Task 10 mechanical swap did not
/// strand the queue/context/subagent paths.
///
/// Deliberately NOT on the surface (their call sites died in Tasks 10/13/18):
/// `requestBatteryExemption`, `workspaceRootFor`, `skillUnavailableReason`,
/// `sessionRepoFull`, `hostDirOf`, `isSkillAvailableForSession`, and the
/// legacy no-arg `approve` (its two chat_screen sites were re-pointed onto
/// [approveRequest] in Task 10).
library;

import 'package:flutter/foundation.dart';

import '../state.dart';
import 'models.dart';

/// The cloud-shaped surface consumed by the thin-client UI.
abstract class AgentSurface extends ChangeNotifier {
  /// The foreground session's access mode.
  AgentMode get mode;

  /// Sets [m] for [sessionId] (the foreground session when null).
  void setMode(AgentMode m, {String? sessionId});

  /// True while [sessionId] has a run in flight.
  bool busyFor(String sessionId);

  /// Per-session busy flag for list rows.
  ValueListenable<bool> busyListenable(String sessionId);

  /// Stops [sessionId]'s run. The facade returns whether a live run was
  /// found and a cancel posted (queueing is server-side there). Callers that
  /// only need the side effect can ignore the value.
  bool stopRequested({required String sessionId});

  /// Stops every live run everywhere.
  void hardStopAll();

  /// Starts a turn. The local-only parameters ([freshTurn],
  /// [expandRefsFor]) are accepted for backward compatibility; the cloud
  /// facade forwards only the prompt and attachments.
  Future<void> runTask(
    String originalPrompt, {
    String? sessionId,
    bool freshTurn = true,
    ChatSession? expandRefsFor,
    List<({String name, String path, int size})>? attachments,
  });

  /// Live status line for [sessionId] ("retrying in 9s…"), or null.
  String? statusFor(String sessionId);

  /// True when [sessionId]'s live run has produced no event of any kind for
  /// the response-timeout window — the facade's client-side watchdog, a
  /// user-visible "still waiting" surface (never a cancel). Concrete so
  /// implementations without a watchdog keep the old behavior.
  bool stalledFor(String sessionId) => false;

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

  /// Live background jobs for [sessionId]. The record shape is the surface's
  /// `jobsFor` signature; the plan sketch said `List<BgJob>`, but the
  /// contract wins (Step 4).
  List<({int id, String name, String state, int elapsedSec, int outChars})>
      jobsFor(String sessionId);

  /// Kills a job from the jobs popover.
  void killJobFor(String sessionId, int jobId);

  /// Measured context tokens for [s] (0 on the facade until P3 usage lands).
  int measuredContextTokens(ChatSession s, {String systemPrompt = ''});

  // -------------------------------------------------------------------------
  // Composer queue (chat_screen's queue dock — reached through aliases, so
  // absent from the map's direct-chain measurement)
  // -------------------------------------------------------------------------

  /// The foreground session's queued messages, oldest-first.
  List<String> get queuedMessages;

  /// Queue snapshot for an explicitly rendered session.
  List<String> queuedMessagesFor(String sessionId);

  /// Stable ids for [sessionId]'s queued messages (index-aligned with
  /// [queuedMessagesFor]).
  List<int> queuedMessageIdsFor(String sessionId);

  /// Queues [text] for the session; starts it immediately when idle.
  void enqueueMessage(String text, {String? sessionId});

  /// Edits the queued message with stable [id].
  void editQueuedMessageById(int id, String newText);

  /// Removes the queued message at [index] in the foreground queue.
  void removeQueuedMessage(int index);

  /// Removes the queued message with stable [id].
  void removeQueuedMessageById(int id);

  /// Pulls the row to the front and stops the current run so it starts now.
  void quickSendQueuedMessage(int id, {String? sessionId});

  /// Pulls the row at [index] to the front of the foreground queue.
  void steerQueuedMessage(int index);

  /// Removes every queued message of [sessionId] and returns them for Undo.
  List<QueuedMessageSnapshot> takeQueuedMessages(String sessionId);

  /// Undo for [takeQueuedMessages]; returns how many were restored.
  int restoreQueuedMessages(
      String sessionId, List<QueuedMessageSnapshot> items);

  // -------------------------------------------------------------------------
  // Context-meter counters (chat_screen:623-626)
  // -------------------------------------------------------------------------

  int get sessionSystemTokens;
  int get sessionToolTokens;
  int get sessionMessageTokens;
  int get sessionCacheReadTokens;

  // -------------------------------------------------------------------------
  // @-mention subagents (chat_screen:6692, 6769)
  // -------------------------------------------------------------------------

  /// Subagent handles whose parent is [sessionId], newest first.
  List<SubagentInfo> subagentsOf(String sessionId);

  // -------------------------------------------------------------------------
  // Browser header status dot (chat_screen:1410-1412)
  // -------------------------------------------------------------------------

  /// True while an agent browser tool is running.
  bool get browserBusy;

  /// True once the browser has been opened/pre-warmed in this launch.
  bool get browserReady;

  // -------------------------------------------------------------------------
  // Sidebar (sidebar.dart:1180)
  // -------------------------------------------------------------------------

  /// Forces a fresh LLM-generated title for [s].
  Future<void> regenerateSessionTitle(ChatSession s);
}
