import { describe, expect, it } from "vitest";
import {
  COLLAB_REPORT_DAILY_LIMIT,
  COLLAB_REPORT_MAX_EXCERPT,
  appendCollabModerationAudit,
  collabContentVisibility,
  collabRemovalFenceSatisfied,
  createCollabModerationAudit,
  decideCollabModeratorAction,
  decideCollabOwnerMessageRemoval,
  decideCollabOwnerParticipantRemoval,
  decideCollabReport,
  decideCollabViewerBlock,
  deriveCollabModeratorActionReceipt,
  parseCollabModeratorActionBody,
  parseCollabReportBody,
  type CollabMemberAuthority,
  type CollabMessageTargetAccess,
  type CollabModerationReportTarget,
  type CollabModeratorAction,
  type CollabParticipantTargetAccess,
  type CollabReportRecord,
} from "./moderation.js";

// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md forbids Vitest/typechecks.

const NOW = new Date("2026-10-25T12:34:56.000Z");
const NOW_ISO = "2026-10-25T12:34:56.000Z";
const REQUEST_ID = "r".repeat(16);
const MODERATOR_REQUEST_ID = "m".repeat(16);

function server(auditId = "audit-1") {
  return { now: NOW, auditId };
}

function member(overrides: Partial<CollabMemberAuthority> = {}): CollabMemberAuthority {
  return {
    uid: "user-1",
    roomId: "room-1",
    participantId: "p-user",
    ownerUserId: "owner-1",
    role: "participant",
    status: "active",
    lifecycle: "active",
    roomGeneration: 7,
    membershipGeneration: 7,
    ...overrides,
  };
}

function owner(overrides: Partial<CollabMemberAuthority> = {}): CollabMemberAuthority {
  return member({
    uid: "owner-1",
    participantId: "p-owner",
    role: "owner",
    ...overrides,
  });
}

function message(overrides: Partial<CollabMessageTargetAccess> = {}): CollabMessageTargetAccess {
  return {
    kind: "collab_message",
    roomId: "room-1",
    targetId: "message-1",
    participantId: "p-target",
    text: "canonical private text",
    ...overrides,
  };
}

function participant(overrides: Partial<CollabParticipantTargetAccess> = {}): CollabParticipantTargetAccess {
  return {
    kind: "collab_participant",
    roomId: "room-1",
    targetId: "p-target",
    role: "participant",
    status: "active",
    ...overrides,
  };
}

function reportBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schemaVersion: 1,
    requestId: REQUEST_ID,
    kind: "collab_message",
    targetId: "message-1",
    reason: "hate",
    details: "reporter details",
    ...overrides,
  };
}

function existingReport(overrides: Partial<CollabReportRecord> = {}): CollabReportRecord {
  return {
    reportId: "report-existing",
    requestId: REQUEST_ID,
    reporterUid: "user-1",
    roomId: "room-1",
    kind: "collab_message",
    targetId: "message-1",
    reason: "hate",
    details: "reporter details",
    excerpt: "canonical private text",
    createdAt: NOW_ISO,
    status: "open",
    ...overrides,
  };
}

function reportDecision(overrides: Partial<Parameters<typeof decideCollabReport>[0]> = {}) {
  return decideCollabReport({
    actor: member(),
    request: parseCollabReportBody(reportBody()),
    target: message(),
    existing: null,
    reportsInLast24Hours: 0,
    server: { ...server(), reportId: "report-new" },
    ...overrides,
  });
}

function errorCode(fn: () => unknown): string | undefined {
  try {
    fn();
  } catch (error) {
    return (error as { code?: string }).code;
  }
  throw new Error("Expected policy call to fail");
}

describe("Collab report domain input", () => {
  it("uses a closed bounded body and rejects client-owned server fields", () => {
    expect(parseCollabReportBody(reportBody({ details: undefined }))).toEqual({
      schemaVersion: 1,
      requestId: REQUEST_ID,
      kind: "collab_message",
      targetId: "message-1",
      reason: "hate",
      details: "",
    });

    for (const override of [
      { reporterUid: "forged-user" },
      { roomId: "forged-room" },
      { excerpt: "forged excerpt" },
      { createdAt: NOW_ISO },
      { role: "owner" },
      { unknown: true },
    ]) {
      expect(errorCode(() => parseCollabReportBody(reportBody(override)))).toBe("invalid_request");
    }
    expect(errorCode(() => parseCollabReportBody(reportBody({ details: "🙂".repeat(1001) }))))
      .toBe("invalid_request");
    for (const details of [
      null, false, true, 0, 1, 1n, Symbol("details"), () => "details", [], {}, ["nested"],
    ]) {
      expect(errorCode(() => parseCollabReportBody(reportBody({ details }))))
        .toBe("invalid_request");
    }
    expect(parseCollabReportBody(reportBody({ details: "🙂".repeat(1000) })).details)
      .toHaveLength(2000);
    expect(errorCode(() => parseCollabReportBody(reportBody({ targetId: "t".repeat(129) }))))
      .toBe("invalid_request");
    expect(errorCode(() => parseCollabReportBody(reportBody({ requestId: "short" }))))
      .toBe("invalid_request");
  });

  it("rejects nullable details before reading server ID or time context", () => {
    let serverReads = 0;
    const guardedServer = {
      get auditId() { serverReads += 1; return "audit-forbidden"; },
      get reportId() { serverReads += 1; return "report-forbidden"; },
      get now() { serverReads += 1; return NOW; },
    };
    expect(errorCode(() => reportDecision({
      request: { ...parseCollabReportBody(reportBody()), details: null as never },
      server: guardedServer,
    }))).toBe("invalid_request");
    expect(serverReads).toBe(0);
  });

  it("derives identity, room, target, time, and bounded excerpt only from server data", () => {
    const decision = reportDecision({
      target: message({ text: `canonical ${"🙂".repeat(COLLAB_REPORT_MAX_EXCERPT)}` }),
      server: { now: NOW, auditId: "audit-report", reportId: "report-new" },
    });

    expect(decision.outcome).toBe("applied");
    expect(decision.result).toMatchObject({
      reportId: "report-new",
      requestId: REQUEST_ID,
      reporterUid: "user-1",
      roomId: "room-1",
      targetId: "message-1",
      excerpt: `canonical ${"🙂".repeat(COLLAB_REPORT_MAX_EXCERPT - 10)}`,
      createdAt: NOW_ISO,
      status: "open",
    });
    expect(Array.from(decision.result.excerpt)).toHaveLength(COLLAB_REPORT_MAX_EXCERPT);
    expect(decision.mutation).toEqual(decision.result);
  });

  it("uses participant access directly and never invents a message excerpt", () => {
    const request = parseCollabReportBody(reportBody({
      kind: "collab_participant",
      targetId: "p-target",
    }));
    const decision = reportDecision({ request, target: participant() });
    expect(decision.result).toMatchObject({
      kind: "collab_participant",
      targetId: "p-target",
      excerpt: "",
    });
    expect(errorCode(() => reportDecision({ request, target: message() })))
      .toBe("target_not_found");
  });

  it("requires current actor membership and exact current target access before dedupe or quota", () => {
    expect(errorCode(() => reportDecision({ target: null }))).toBe("target_not_found");
    expect(errorCode(() => reportDecision({
      target: null,
      existing: existingReport(),
      reportsInLast24Hours: COLLAB_REPORT_DAILY_LIMIT,
    }))).toBe("target_not_found");
    expect(errorCode(() => reportDecision({ target: message({ roomId: "other-room" }) })))
      .toBe("target_not_found");
    expect(errorCode(() => reportDecision({ target: message({ targetId: "other-message" }) })))
      .toBe("target_not_found");
    expect(errorCode(() => reportDecision({ actor: member({ status: "revoked" }) })))
      .toBe("not_member");
    expect(errorCode(() => reportDecision({ actor: member({ lifecycle: "closed" }) })))
      .toBe("session_closed");
  });

  it("replays an identical report before the daily limit and conflicts on changed payloads", () => {
    const replay = reportDecision({
      existing: existingReport(),
      reportsInLast24Hours: COLLAB_REPORT_DAILY_LIMIT,
    });
    expect(replay).toMatchObject({
      outcome: "replayed",
      result: { reportId: "report-existing" },
      mutation: null,
      audit: null,
    });

    expect(errorCode(() => reportDecision({
      existing: existingReport(),
      request: parseCollabReportBody(reportBody({ details: "changed" })),
      reportsInLast24Hours: COLLAB_REPORT_DAILY_LIMIT,
    }))).toBe("request_already_used");
    expect(errorCode(() => reportDecision({
      reportsInLast24Hours: COLLAB_REPORT_DAILY_LIMIT,
    }))).toBe("report_limit_reached");
    expect(reportDecision({ reportsInLast24Hours: COLLAB_REPORT_DAILY_LIMIT - 1 }).outcome)
      .toBe("applied");
  });
});

describe("viewer blocks and visibility", () => {
  it("makes block and unblock desired-state idempotent without a global effect", () => {
    const blocked = decideCollabViewerBlock({
      actor: member(), target: participant(), blocked: true, currentlyBlocked: false, server: server(),
    });
    expect(blocked).toMatchObject({
      outcome: "applied",
      result: {
        type: "set_viewer_block",
        scope: "viewer",
        viewerUid: "user-1",
        targetParticipantId: "p-target",
        blocked: true,
      },
    });
    const duplicate = decideCollabViewerBlock({
      actor: member(), target: participant(), blocked: true, currentlyBlocked: true, server: server("audit-2"),
    });
    expect(duplicate).toMatchObject({ outcome: "unchanged", mutation: null, audit: null });

    const unblocked = decideCollabViewerBlock({
      actor: member(), target: participant(), blocked: false, currentlyBlocked: true, server: server("audit-3"),
    });
    expect(unblocked.result).toMatchObject({ scope: "viewer", blocked: false });
    expect(errorCode(() => decideCollabViewerBlock({
      actor: member(), target: participant({ targetId: "p-user" }),
      blocked: true, currentlyBlocked: false, server: server(),
    }))).toBe("invalid_request");
    expect(errorCode(() => decideCollabViewerBlock({
      actor: member(), target: participant({ roomId: "other-room" }),
      blocked: true, currentlyBlocked: false, server: server(),
    }))).toBe("target_not_found");
  });

  it("hides content only for the blocking viewer and never relabels global suppression", () => {
    const block = decideCollabViewerBlock({
      actor: member(), target: participant(), blocked: true, currentlyBlocked: false, server: server(),
    }).result;
    const base = {
      roomId: "room-1",
      messageId: "message-1",
      subjectParticipantId: "p-target",
      ownerRemoval: null,
      moderatorSuppression: null,
    };
    expect(collabContentVisibility({ ...base, viewerUid: "user-1", viewerBlock: block }))
      .toBe("viewer_blocked");
    expect(collabContentVisibility({ ...base, viewerUid: "user-2", viewerBlock: block }))
      .toBe("visible");
    expect(collabContentVisibility({
      ...base,
      viewerUid: "user-2",
      viewerBlock: block,
      moderatorSuppression: { roomId: "room-1", messageId: "message-1" },
    })).toBe("moderator_globally_suppressed");
    expect(collabContentVisibility({
      ...base,
      viewerUid: "user-1",
      viewerBlock: block,
      moderatorSuppression: { roomId: "room-1", messageId: "message-1" },
    })).toBe("moderator_globally_suppressed");
  });
});

describe("owner removal and room tombstones", () => {
  it("requires owner authority and emits an atomic generation/cancellation removal fence", () => {
    const decision = decideCollabOwnerParticipantRemoval({
      actor: owner(), target: participant(), server: server("audit-remove"),
    });
    expect(decision).toMatchObject({ outcome: "applied", audit: { action: "remove_participant" } });
    expect(decision.result).toEqual({
      type: "remove_participant",
      scope: "room",
      authority: "owner",
      actorUid: "owner-1",
      roomId: "room-1",
      targetParticipantId: "p-target",
      expectedRoomGeneration: 7,
      expectedActorParticipantId: "p-owner",
      expectedActorMembershipGeneration: 7,
      nextRoomGeneration: 8,
      cancelParticipantTurns: true,
      revokeMembership: true,
    });
    expect(collabRemovalFenceSatisfied(decision.result, {
      roomId: "room-1",
      roomGeneration: 7,
      actorParticipantId: "p-owner",
      actorMembershipGeneration: 7,
      cancelledParticipantId: "p-target",
    })).toBe(true);
    expect(collabRemovalFenceSatisfied(decision.result, {
      roomId: "room-1",
      roomGeneration: 8,
      actorParticipantId: "p-owner",
      actorMembershipGeneration: 7,
      cancelledParticipantId: "p-target",
    })).toBe(false);
    expect(collabRemovalFenceSatisfied(decision.result, {
      roomId: "room-1",
      roomGeneration: 7,
      actorParticipantId: "p-owner",
      actorMembershipGeneration: 7,
      cancelledParticipantId: null,
    })).toBe(false);

    expect(errorCode(() => decideCollabOwnerParticipantRemoval({
      actor: member(), target: participant(), server: server(),
    }))).toBe("not_member");
    expect(errorCode(() => decideCollabOwnerParticipantRemoval({
      actor: member({ role: "owner" }), target: participant(), server: server(),
    }))).toBe("not_member");
    expect(errorCode(() => decideCollabOwnerParticipantRemoval({
      actor: owner(), target: participant({ targetId: "p-owner", role: "owner" }), server: server(),
    }))).toBe("owner_not_removable");
  });

  it("does not advance generations or recancel for an already revoked participant", () => {
    const decision = decideCollabOwnerParticipantRemoval({
      actor: owner(), target: participant({ status: "revoked" }), server: server(),
    });
    expect(decision).toMatchObject({ outcome: "unchanged", mutation: null, audit: null });
  });

  it("uses a repeatable room-visibility tombstone rather than deleting canonical history", () => {
    const decision = decideCollabOwnerMessageRemoval({
      actor: owner(), target: message(), currentlyRemoved: false, server: server("audit-message"),
    });
    expect(decision.result).toEqual({
      type: "tombstone_message",
      scope: "room",
      roomId: "room-1",
      messageId: "message-1",
      canonicalHistory: "preserved",
    });
    expect(collabContentVisibility({
      viewerUid: "someone-else",
      roomId: "room-1",
      messageId: "message-1",
      subjectParticipantId: "p-target",
      viewerBlock: null,
      ownerRemoval: decision.result,
      moderatorSuppression: null,
    })).toBe("owner_room_removed");
    expect(decideCollabOwnerMessageRemoval({
      actor: owner(), target: message(), currentlyRemoved: true, server: server("audit-message-2"),
    })).toMatchObject({ outcome: "unchanged", mutation: null, audit: null });
  });
});

function moderatorReport(overrides: Partial<CollabModerationReportTarget> = {}): CollabModerationReportTarget {
  return {
    reportId: "report-1",
    roomId: "room-1",
    kind: "collab_message",
    targetId: "message-1",
    status: "open",
    ...overrides,
  };
}

function moderatorRequest(action: CollabModeratorAction = "suppress_message") {
  return parseCollabModeratorActionBody({
    schemaVersion: 1,
    requestId: MODERATOR_REQUEST_ID,
    action,
    reason: "hate",
  });
}

function moderatorDecision(overrides: Partial<Parameters<typeof decideCollabModeratorAction>[0]> = {}) {
  return decideCollabModeratorAction({
    moderator: { uid: "moderator-1", permission: "collab_moderator", active: true },
    request: moderatorRequest(),
    report: moderatorReport(),
    target: message(),
    existing: null,
    current: { roomGeneration: 7, messageSuppressed: false, roomSuppressed: false },
    server: server("audit-moderator"),
    ...overrides,
  });
}

describe("separate privileged moderation", () => {
  it("does not treat room ownership or ordinary membership as moderator authority", () => {
    for (const moderator of [
      null,
      { uid: "owner-1", permission: "room_owner", active: true },
      { uid: "user-1", permission: "collab_member", active: true },
      { uid: "moderator-1", permission: "collab_moderator", active: false },
    ]) {
      expect(errorCode(() => moderatorDecision({ moderator }))).toBe("moderator_required");
    }
  });

  it("creates global suppression only through an explicit moderator action", () => {
    const decision = moderatorDecision();
    expect(decision.result).toEqual({
      type: "suppress_message",
      scope: "global",
      reportId: "report-1",
      roomId: "room-1",
      messageId: "message-1",
    });
    expect(decision.audit).toMatchObject({
      actorUid: "moderator-1",
      actorAuthority: "moderator",
      action: "suppress_message",
      outcome: "applied",
    });
    if (decision.result.type !== "suppress_message") throw new Error("wrong effect type");
    expect(collabContentVisibility({
      viewerUid: "user-2",
      roomId: "room-1",
      messageId: "message-1",
      subjectParticipantId: "p-target",
      viewerBlock: null,
      ownerRemoval: null,
      moderatorSuppression: decision.result,
    })).toBe("moderator_globally_suppressed");
    expect(moderatorDecision({
      current: { roomGeneration: 7, messageSuppressed: true, roomSuppressed: false },
    })).toMatchObject({
      outcome: "unchanged",
      mutation: null,
      audit: null,
      receiptMutation: { outcome: "unchanged", action: "suppress_message" },
    });
  });

  it("replays the original moderator result without reapplying or reauditing it", () => {
    const first = moderatorDecision();
    const existing = first.receipt;
    expect(first.receiptMutation).toEqual(existing);
    expect(moderatorDecision({ existing, target: null })).toMatchObject({
      outcome: "replayed",
      result: first.result,
      mutation: null,
      audit: null,
      receipt: existing,
      receiptMutation: null,
    });
    expect(errorCode(() => moderatorDecision({
      existing,
      request: parseCollabModeratorActionBody({
        schemaVersion: 1,
        requestId: MODERATOR_REQUEST_ID,
        action: "suppress_message",
        reason: "spam",
      }),
    }))).toBe("request_already_used");
  });

  it("requires a no-op receipt mutation and replays it after a later lawful report transition", () => {
    const noOp = moderatorDecision({
      request: moderatorRequest("dismiss"),
      report: moderatorReport({ status: "dismissed" }),
      target: null,
    });
    expect(noOp).toMatchObject({
      outcome: "unchanged",
      mutation: null,
      audit: null,
      receipt: {
        outcome: "unchanged",
        action: "dismiss",
        effect: { type: "dismiss_report" },
      },
      receiptMutation: { outcome: "unchanged" },
    });

    const later = moderatorDecision({
      request: parseCollabModeratorActionBody({
        schemaVersion: 1,
        requestId: "later-request-16",
        action: "suppress_message",
        reason: "hate",
      }),
      report: moderatorReport({ status: "dismissed" }),
    });
    expect(later.outcome).toBe("applied");

    const persisted = JSON.parse(JSON.stringify(noOp.receipt)) as {
      schemaVersion: number;
      effect: { type: string; scope: string };
    };
    expect(persisted.schemaVersion).toBe(1);
    const replay = moderatorDecision({
      request: moderatorRequest("dismiss"),
      report: moderatorReport({ status: "actioned" }),
      target: null,
      existing: persisted,
    });
    expect(replay).toMatchObject({
      outcome: "replayed",
      result: noOp.result,
      mutation: null,
      audit: null,
      receipt: noOp.receipt,
      receiptMutation: null,
    });
    expect(replay.receipt).not.toBe(persisted);
    expect(replay.result).not.toBe(persisted.effect);
    persisted.effect.scope = "tampered-after-replay";
    expect(replay.receipt.effect.scope).toBe("moderation");
  });

  it("rejects malformed persisted receipt schemas and suppression effects before replay", () => {
    const valid = moderatorDecision().receipt;
    const persisted = JSON.parse(JSON.stringify(valid)) as Record<string, unknown>;
    const effect = persisted.effect as Record<string, unknown>;
    const withoutSchema = { ...persisted };
    delete withoutSchema.schemaVersion;
    const malformed: unknown[] = [
      withoutSchema,
      { ...persisted, schemaVersion: 2 },
      { ...persisted, token: "SECRET-TOKEN" },
      { ...persisted, createdAt: "not-a-time" },
      { ...persisted, outcome: "replayed" },
      { ...persisted, actorUid: "" },
      { ...persisted, reason: "not-a-reason" },
      { ...persisted, effect: null },
      { ...persisted, effect: { ...effect, scope: "viewer" } },
      { ...persisted, effect: { ...effect, reportId: "other-report" } },
      { ...persisted, effect: { ...effect, excerpt: "SECRET-EXCERPT" } },
    ];
    for (const existing of malformed) {
      expect(errorCode(() => moderatorDecision({ existing, target: null })))
        .toBe("invalid_request");
    }
    expect(errorCode(() => deriveCollabModeratorActionReceipt({
      record: null,
      moderator: { uid: "moderator-1", permission: "collab_moderator", active: true },
      request: moderatorRequest(),
      report: moderatorReport(),
    }))).toBe("invalid_request");
  });

  it("validates every persisted removal fence and dismiss/room effect invariant", () => {
    const dismissInput = {
      request: moderatorRequest("dismiss"),
      report: moderatorReport({ status: "dismissed" }),
      target: null,
    };
    const dismiss = moderatorDecision(dismissInput).receipt;
    expect(errorCode(() => moderatorDecision({
      ...dismissInput,
      existing: { ...dismiss, effect: { ...dismiss.effect, scope: "global" } },
    }))).toBe("invalid_request");

    const roomInput = { request: moderatorRequest("suppress_room") };
    const room = moderatorDecision(roomInput).receipt;
    for (const effect of [
      { ...room.effect, scope: "viewer" },
      { ...room.effect, messageId: "message-1" },
    ]) {
      expect(errorCode(() => moderatorDecision({ ...roomInput, existing: { ...room, effect } })))
        .toBe("invalid_request");
    }

    const removalInput = {
      request: moderatorRequest("remove_participant"),
      report: moderatorReport({ kind: "collab_participant" as const, targetId: "p-target" }),
      target: participant(),
    };
    const removal = moderatorDecision(removalInput).receipt;
    if (removal.effect.type !== "remove_participant") throw new Error("wrong effect fixture");
    for (const override of [
      { scope: "global" },
      { authority: "owner" },
      { actorUid: "other-actor" },
      { expectedRoomGeneration: 0 },
      { expectedActorParticipantId: "p-moderator" },
      { expectedActorMembershipGeneration: 7 },
      { nextRoomGeneration: 9 },
      { cancelParticipantTurns: false },
      { revokeMembership: false },
      { reportId: "other-report" },
      { details: "SECRET-DETAILS" },
    ]) {
      expect(errorCode(() => moderatorDecision({
        ...removalInput,
        existing: { ...removal, effect: { ...removal.effect, ...override } },
      }))).toBe("invalid_request");
    }
  });

  it("deeply freezes and defensively separates new and recovered receipt effects", () => {
    const input = {
      request: moderatorRequest("remove_participant"),
      report: moderatorReport({ kind: "collab_participant" as const, targetId: "p-target" }),
      target: participant(),
    };
    const decision = moderatorDecision(input);
    expect(Object.isFrozen(decision.result)).toBe(true);
    expect(Object.isFrozen(decision.receipt)).toBe(true);
    expect(Object.isFrozen(decision.receipt.effect)).toBe(true);
    expect(decision.receipt.effect).not.toBe(decision.result);
    expect(decision.receiptMutation?.effect).not.toBe(decision.result);
    const effect = decision.receipt.effect;
    if (effect.type !== "remove_participant") throw new Error("wrong effect type");
    expect(() => {
      (decision.result as unknown as { nextRoomGeneration: number }).nextRoomGeneration = 99;
    }).toThrow(TypeError);
    expect(effect.nextRoomGeneration).toBe(8);

    const persisted = JSON.parse(JSON.stringify(decision.receipt)) as {
      effect: { nextRoomGeneration: number };
    };
    const replay = moderatorDecision({
      ...input,
      report: moderatorReport({
        kind: "collab_participant",
        targetId: "p-target",
        status: "actioned",
      }),
      current: { roomGeneration: 99, messageSuppressed: false, roomSuppressed: false },
      existing: persisted,
    });
    expect(replay.receipt).not.toBe(persisted);
    expect(replay.result).not.toBe(persisted.effect);
    expect(Object.isFrozen(replay.receipt)).toBe(true);
    expect(Object.isFrozen(replay.receipt.effect)).toBe(true);
    persisted.effect.nextRoomGeneration = 99;
    if (replay.receipt.effect.type !== "remove_participant") throw new Error("wrong replay effect");
    expect(replay.receipt.effect.nextRoomGeneration).toBe(8);
  });

  it("keeps dismissal, room suppression, and participant removal transitions explicit", () => {
    const dismissed = moderatorDecision({
      request: moderatorRequest("dismiss"),
      target: null,
    });
    expect(dismissed.result).toMatchObject({ type: "dismiss_report", scope: "moderation" });
    expect(moderatorDecision({
      request: moderatorRequest("dismiss"),
      report: moderatorReport({ status: "dismissed" }),
      target: null,
    }).outcome).toBe("unchanged");
    expect(errorCode(() => moderatorDecision({
      request: moderatorRequest("dismiss"),
      report: moderatorReport({ status: "actioned" }),
      target: null,
    }))).toBe("invalid_transition");

    const room = moderatorDecision({
      request: moderatorRequest("suppress_room"),
      target: null,
    });
    expect(room.result).toMatchObject({ type: "suppress_room", scope: "global", roomId: "room-1" });
    if (room.result.type !== "suppress_room") throw new Error("wrong effect type");
    expect(collabContentVisibility({
      viewerUid: "user-2",
      roomId: "room-1",
      messageId: "another-message",
      subjectParticipantId: "p-target",
      viewerBlock: null,
      ownerRemoval: null,
      moderatorSuppression: room.result,
    })).toBe("moderator_globally_suppressed");

    const removed = moderatorDecision({
      request: moderatorRequest("remove_participant"),
      report: moderatorReport({ kind: "collab_participant", targetId: "p-target" }),
      target: participant(),
    });
    expect(removed.result).toMatchObject({
      type: "remove_participant",
      authority: "moderator",
      expectedActorParticipantId: null,
      expectedActorMembershipGeneration: null,
      nextRoomGeneration: 8,
      cancelParticipantTurns: true,
    });
    if (removed.result.type !== "remove_participant") throw new Error("wrong effect type");
    expect(collabRemovalFenceSatisfied(removed.result, {
      roomId: "room-1",
      roomGeneration: 7,
      actorParticipantId: null,
      actorMembershipGeneration: null,
      cancelledParticipantId: "p-target",
    })).toBe(true);
  });
});

describe("safe append-only audit values", () => {
  it("contains actor, target, reason, server time, and outcome but no report content", () => {
    const decision = reportDecision({
      request: parseCollabReportBody(reportBody({ details: "SECRET-DETAILS" })),
      target: message({ text: "SECRET-EXCERPT" }),
      server: { now: NOW, auditId: "audit-safe", reportId: "report-safe" },
    });
    expect(decision.audit).toEqual({
      auditId: "audit-safe",
      actorUid: "user-1",
      actorAuthority: "member",
      target: { roomId: "room-1", kind: "message", id: "message-1" },
      action: "report",
      reason: "hate",
      createdAt: NOW_ISO,
      outcome: "applied",
      reportId: "report-safe",
    });
    expect(JSON.stringify(decision.audit)).not.toContain("SECRET-DETAILS");
    expect(JSON.stringify(decision.audit)).not.toContain("SECRET-EXCERPT");
    expect(JSON.stringify(decision.audit)).not.toContain("canonical private text");
    expect(Object.isFrozen(decision.audit)).toBe(true);
    expect(Object.isFrozen(decision.audit?.target)).toBe(true);
  });

  it("appends without mutation, dedupes identical audit IDs, and rejects ID reuse", () => {
    const audit = reportDecision().audit;
    if (audit === null) throw new Error("missing audit fixture");
    const conflicting = createCollabModerationAudit({
      auditId: audit.auditId,
      actorUid: audit.actorUid,
      actorAuthority: audit.actorAuthority,
      target: { ...audit.target },
      action: audit.action,
      reason: audit.reason,
      outcome: "denied",
      now: NOW,
      reportId: audit.reportId,
    });
    const empty: ReturnType<typeof appendCollabModerationAudit> = [];
    const first = appendCollabModerationAudit(empty, audit);
    const replay = appendCollabModerationAudit(first, audit);
    expect(empty).toEqual([]);
    expect(first).toHaveLength(1);
    expect(replay).toHaveLength(1);
    expect(Object.isFrozen(first)).toBe(true);
    expect(errorCode(() => appendCollabModerationAudit(first, conflicting)))
      .toBe("request_already_used");
    expect(first[0]?.outcome).toBe("applied");
  });

  it("accepts only factory-derived new audits and blocks extra runtime fields", () => {
    const audit = reportDecision().audit;
    if (audit === null) throw new Error("missing audit fixture");
    const decoded = JSON.parse(JSON.stringify(audit)) as typeof audit;
    expect(errorCode(() => appendCollabModerationAudit([], decoded)))
      .toBe("invalid_request");
    expect(errorCode(() => appendCollabModerationAudit([], {
      ...audit,
      details: "SECRET-DETAILS",
    } as never))).toBe("invalid_request");
    expect(errorCode(() => createCollabModerationAudit({
      auditId: "audit-extra",
      actorUid: "moderator-1",
      actorAuthority: "moderator",
      target: { roomId: "room-1", kind: "room", id: "room-1" },
      action: "suppress_room",
      reason: "other",
      outcome: "applied",
      now: NOW,
      excerpt: "SECRET-EXCERPT",
    } as never))).toBe("invalid_request");
  });

  it("defensively copies and freezes appended history against later source mutation", () => {
    const existing = reportDecision().audit;
    const added = reportDecision({
      server: { now: NOW, auditId: "audit-added", reportId: "report-added" },
    }).audit;
    if (existing === null || added === null) throw new Error("missing audit fixture");
    const persisted = JSON.parse(JSON.stringify(existing)) as typeof existing;
    const trail = appendCollabModerationAudit([persisted], added);
    expect(trail).toHaveLength(2);
    expect(trail[0]).not.toBe(persisted);
    expect(trail[1]).not.toBe(added);
    expect(Object.isFrozen(trail[0])).toBe(true);
    expect(Object.isFrozen(trail[0]?.target)).toBe(true);
    expect(Object.isFrozen(trail[1])).toBe(true);
    expect(Object.isFrozen(trail[1]?.target)).toBe(true);

    (persisted as unknown as { target: { id: string } }).target.id = "mutated-after-append";
    expect(trail[0]?.target.id).toBe("message-1");
    expect(errorCode(() => appendCollabModerationAudit([
      { ...persisted, excerpt: "SECRET-EXCERPT" },
    ] as never, added))).toBe("invalid_request");
    expect(errorCode(() => appendCollabModerationAudit([
      { ...persisted, target: { ...persisted.target, token: "SECRET-TOKEN" } },
    ] as never, added))).toBe("invalid_request");

    const context = {
      auditId: "audit-copy",
      actorUid: "moderator-1",
      actorAuthority: "moderator" as const,
      target: { roomId: "room-1", kind: "room" as const, id: "room-1" },
      action: "suppress_room" as const,
      reason: "other" as const,
      outcome: "applied" as const,
      now: NOW,
    };
    const copied = createCollabModerationAudit(context);
    context.target.id = "changed-input";
    expect(copied.target.id).toBe("room-1");
  });

  it("supports denied outcomes with closed reasons rather than arbitrary sensitive text", () => {
    const denied = createCollabModerationAudit({
      auditId: "audit-denied",
      actorUid: "moderator-1",
      actorAuthority: "moderator",
      target: { roomId: "room-1", kind: "room", id: "room-1" },
      action: "suppress_room",
      reason: "other",
      outcome: "denied",
      now: NOW,
    });
    expect(denied).toMatchObject({ outcome: "denied", reason: "other", createdAt: NOW_ISO });
    expect(errorCode(() => createCollabModerationAudit({
      auditId: denied.auditId,
      actorUid: denied.actorUid,
      actorAuthority: denied.actorAuthority,
      target: { ...denied.target },
      action: denied.action,
      reason: "sensitive free-form explanation" as never,
      outcome: denied.outcome,
      now: NOW,
    }))).toBe("invalid_request");
  });
});
