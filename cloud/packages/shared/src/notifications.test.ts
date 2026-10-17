import { describe, expect, it } from "vitest";
import {
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
  const expected: Record<NotificationKind, "agent_updates" | "scheduler_results"> = {
    agentFinished: "agent_updates",
    agentFailed: "agent_updates",
    agentNeedsInput: "agent_updates",
    agentNeedsApproval: "agent_updates",
    jobDone: "agent_updates",
    scheduleSucceeded: "scheduler_results",
    scheduleFailed: "scheduler_results",
  };

  it("routes schedule kinds to scheduler_results and the rest to agent_updates", () => {
    for (const [kind, channel] of Object.entries(expected)) {
      expect(notificationChannelFor(kind as NotificationKind)).toBe(channel);
    }
  });
});

describe("notification routes", () => {
  it("pins the Dart route templates", () => {
    expect(chatRoute("s1")).toBe("/c/s1");
    expect(scheduleRoute("s1")).toBe("/schedule/s1");
  });
});
