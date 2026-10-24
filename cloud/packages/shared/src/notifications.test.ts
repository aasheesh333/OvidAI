import { describe, expect, it } from "vitest";
import {
  androidChannelIdFor,
  chatRoute,
  notificationChannelFor,
  notificationSummary,
  scheduleRoute,
  type NotificationKind,
} from "./notifications.js";

/**
 * Notification vocabulary ported from `lib/core/background_notifications.dart`
 * (and `test/background_notifications_test.dart`). The summary function is a
 * line-by-line port: same regexes, same >60%-cut rule.
 */

describe("notificationSummary", () => {
  it("replaces a fenced code block with [code]", () => {
    expect(notificationSummary("```\ncode\n```")).toBe("[code]");
  });

  it("strips images, keeps link text, strips markdown markers", () => {
    expect(notificationSummary("**bold** [link](http://a) ![img](http://b)")).toBe("bold link");
    expect(notificationSummary("# Title\n\n**bold** [link](http://a)")).toBe("Title bold link");
  });

  it("strips *_`#> characters and collapses whitespace", () => {
    expect(notificationSummary("a\n\n   b\t_c_ `d` > e")).toBe("a b c d e");
  });

  it("caps a 200-char input at 140, cutting at the last space boundary", () => {
    // Dart: cut = s.substring(0, 139); space = cut.lastIndexOf(" ");
    // space (134) > max * 0.6 (84) -> cut at the space, trimRight, add "…".
    const input = "word ".repeat(40);
    expect(input).toHaveLength(200);
    const out = notificationSummary(input);
    expect(out).toBe("word ".repeat(26) + "word…");
    expect(out.length).toBeLessThanOrEqual(140);
    expect(out.endsWith("…")).toBe(true);
  });

  it("caps an input with no spaces at max-1 chars plus the ellipsis", () => {
    const out = notificationSummary("a".repeat(200));
    expect(out).toBe("a".repeat(139) + "…");
    expect(out).toHaveLength(140);
  });

  it("honours an explicit max of 48", () => {
    const out = notificationSummary("word ".repeat(20), { max: 48 });
    expect(out).toBe("word ".repeat(8) + "word…");
    expect(out.length).toBeLessThanOrEqual(48);
  });

  it("leaves short text untouched", () => {
    expect(notificationSummary("  hello   world  ")).toBe("hello world");
  });
});

describe("notificationChannelFor", () => {
  const expected: Record<NotificationKind, "agent_updates" | "scheduler_results" | "background_status"> = {
    agentFinished: "agent_updates",
    agentFailed: "agent_updates",
    agentNeedsInput: "agent_updates",
    agentNeedsApproval: "agent_updates",
    jobDone: "agent_updates",
    scheduleSucceeded: "scheduler_results",
    scheduleFailed: "scheduler_results",
    backgroundStatus: "background_status",
  };

  it("routes every kind to its actual channel", () => {
    for (const [kind, channel] of Object.entries(expected)) {
      expect(notificationChannelFor(kind as NotificationKind)).toBe(channel);
    }
  });
});

describe("androidChannelIdFor", () => {
  it.each([
    ["agent_updates", "chime", "ovid_agent_updates.chime.v1"],
    ["agent_updates", "system", "ovid_agent_updates.system.v1"],
    ["scheduler_results", "silent", "ovid_scheduler_results.silent.v1"],
    ["background_status", "silent", "ovid_background_status.silent.v1"],
  ] as const)("maps %s/%s to the versioned native channel", (channel, sound, expected) => {
    expect(androidChannelIdFor(channel, sound)).toBe(expected);
  });

  it("keeps background status silent even if a stale sound is supplied", () => {
    expect(androidChannelIdFor("background_status", "chime")).toBe("ovid_background_status.silent.v1");
  });
});

describe("notification routes", () => {
  it("pins the Dart route templates", () => {
    expect(chatRoute("s1")).toBe("/c/s1");
    expect(scheduleRoute("s1")).toBe("/schedule/s1");
  });
});
