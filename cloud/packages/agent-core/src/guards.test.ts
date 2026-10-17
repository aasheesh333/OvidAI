// Loop guards (P3 Task 14) — pure state machine, TDD step 1.
//
// Ports the PR45/F2 repeat-tool reminder group of test/core_regression_test.dart
// (lines 8118–8225, five cases) onto the TS GuardState/recordToolResult seam,
// plus the plan-mandated byte-for-byte legs Dart does not itself pin: the
// escalation string (no Dart test asserts [CRITICAL ESCALATION] — grep across
// test/ finds it only in agent_service.dart:12751), the exactly-at-3/5/8
// timing, the error-reset ladder, and the canonicalJson key-order
// strengthening (plan:596 — Dart jsonEncodes in insertion order, so two calls
// differing only in key order do NOT collide there; the TS port deliberately
// makes them the same call).

import { describe, expect, it } from "vitest";

import type { TodoItem } from "./ports.js";
import {
  NO_PROGRESS_LIMIT,
  isBudgetBoundary,
  looksLikeToolError,
  newGuardState,
  recordToolResult,
  shouldSendTodoNudge,
  todoNudgeMessage,
} from "./guards.js";

// Byte-for-byte (Dart agent_service.dart AS:12728–12741 — adjacent-string
// concatenation assembled; the dashes are em-dashes, U+2014).
const NOTE_3 =
  "\n\n[note] Same tool + identical args repeated 3 times — re-read the tool output or change approach.";
const NOTE_5 =
  "\n\n[note] Same call now repeated 5 times — stop, reconsider the goal, or ask/notify the user.";
const NOTE_8 =
  "\n\n[note] Same call repeated 8 times — STOP looping. Explain the blockage to the user and try a different approach.";
const escalation = (n: number) =>
  `\n\n[CRITICAL ESCALATION] Tool calls have failed ${n} times consecutively. DO NOT continue repeating similar commands or querying missing files. Stop probing and clearly explain the exact problem to the user.`;

// Byte-for-byte (Dart agent_service.dart AS:12537–12542): header \n, the
// pending lines joined by \n ('~' for in_progress, space otherwise), \n\n,
// then the fixed tail.
const TODO_NUDGE =
  "[system] Your SESSION TODOS still has pending items:\n" +
  "- [ ] write the tests\n" +
  "- [~] implement the guards\n" +
  "\n" +
  "Continue working on them. Mark each item in_progress before starting it and completed when done. If a pending item is already done or no longer relevant, update the list with todo_write. Then give your final answer.";

describe("guards: newGuardState", () => {
  it("starts as the zero run bucket (Dart AS:866–897 field defaults)", () => {
    expect(newGuardState()).toEqual({
      repeatKey: null,
      repeatStreak: 0,
      consecutiveErrors: 0,
      turnsWithoutProgress: 0,
      todoNudgeSent: false,
    });
  });
});

describe("guards: recordToolResult — repeat-tool streak (PR45/F2)", () => {
  it("same tool + same args: streak 1..8, notes at EXACTLY the 3rd/5th/8th call (core_regression :8129)", () => {
    const g = newGuardState();
    const results: string[] = [];
    for (let i = 0; i < 9; i += 1) {
      results.push(recordToolResult(g, "run_shell", { command: "ls -la" }, "ok").result);
    }
    // Dart drives the streak directly; here the full appended strings carry
    // the same count (streak n = the nth identical call).
    expect(g.repeatStreak).toBe(9);
    // 3/5/8 append the note — and ONLY there: 1, 2, 4, 6, 7, 9 append nothing.
    expect(results[2]).toBe(`ok${NOTE_3}`); // exactly the 3rd, not the 2nd
    expect(results[1]).toBe("ok");
    expect(results[3]).toBe("ok"); // not the 4th
    expect(results[4]).toBe(`ok${NOTE_5}`); // exactly the 5th
    expect(results[6]).toBe("ok");
    expect(results[7]).toBe(`ok${NOTE_8}`); // exactly the 8th
    expect(results[8]).toBe("ok"); // 9+ never re-escalates
  });

  it("different args reset the streak (core_regression :8151)", () => {
    const g = newGuardState();
    recordToolResult(g, "run_shell", { command: "ls" }, "ok");
    recordToolResult(g, "run_shell", { command: "ls" }, "ok");
    recordToolResult(g, "run_shell", { command: "ls" }, "ok");
    expect(g.repeatStreak).toBe(3);
    recordToolResult(g, "run_shell", { command: "pwd" }, "ok"); // changed args
    expect(g.repeatStreak).toBe(1);
    recordToolResult(g, "fs_read", { path: "path" }, "ok"); // different tool entirely
    expect(g.repeatStreak).toBe(1);
    expect(g.repeatKey!.name).toBe("fs_read");
  });

  it("different tool with same args also resets (core_regression :8175)", () => {
    const g = newGuardState();
    recordToolResult(g, "browser_click", {}, "ok");
    recordToolResult(g, "browser_click", {}, "ok");
    expect(g.repeatStreak).toBe(2);
    recordToolResult(g, "browser_hover", {}, "ok");
    expect(g.repeatStreak).toBe(1);
  });

  it("the streak lives on the guard state (run bucket), never across instances (core_regression :8219)", () => {
    const b1 = newGuardState();
    const b2 = newGuardState();
    const bump = (b: ReturnType<typeof newGuardState>) => {
      recordToolResult(b, "run_shell", { cmd: "ls" }, "ok");
    };
    bump(b1);
    bump(b1);
    bump(b1);
    bump(b2); // different bucket — own streak
    expect(b1.repeatStreak).toBe(3);
    expect(b2.repeatStreak).toBe(1);
  });

  it("canonArgs is key-order-insensitive: {a,b} and {b,a} are the SAME call (plan:596 TS strengthening; Dart would reset)", () => {
    const g = newGuardState();
    recordToolResult(g, "run_shell", { a: 1, b: 2 }, "ok");
    recordToolResult(g, "run_shell", { b: 2, a: 1 }, "ok");
    expect(g.repeatStreak).toBe(2); // Dart's insertion-order jsonEncode would see 1
  });

  it("args are never mutated and the input result string is left untouched (plan:612)", () => {
    const g = newGuardState();
    const args = Object.freeze({ command: "ls -la" }); // canonicalJson copies, never writes
    const result = "ok";
    let returned = "";
    for (let i = 0; i < 3; i += 1) {
      returned = recordToolResult(g, "run_shell", args, result).result;
    }
    expect(args).toEqual({ command: "ls -la" }); // frozen: any in-place write would throw
    expect(result).toBe("ok"); // the original is untouched…
    expect(returned).toBe(`ok${NOTE_3}`); // …the transformation rides the RETURNED copy only
  });
});

describe("guards: recordToolResult — error escalation (AS:12742–12753)", () => {
  // Varying args keeps the repeat streak at 1 so the byte-for-byte escalation
  // assertions stay isolated from the note strings.
  it("3 consecutive error results append CRITICAL ESCALATION with 'failed 3 times'", () => {
    const g = newGuardState();
    const r1 = recordToolResult(g, "run_shell", { n: 1 }, "Error: boom");
    const r2 = recordToolResult(g, "run_shell", { n: 2 }, "Error: boom");
    const r3 = recordToolResult(g, "run_shell", { n: 3 }, "Error: boom");
    expect(r1.result).toBe("Error: boom");
    expect(r2.result).toBe("Error: boom");
    expect(r3.result).toBe(`Error: boom${escalation(3)}`);
    expect(g.consecutiveErrors).toBe(3);
  });

  it("a 4th consecutive failure re-escalates with 'failed 4 times' (AS:12751 interpolates the live count)", () => {
    const g = newGuardState();
    for (let i = 1; i <= 4; i += 1) {
      const r = recordToolResult(g, "run_shell", { n: i }, "Error: boom");
      if (i < 3) expect(r.result).toBe("Error: boom");
      if (i === 3) expect(r.result).toBe(`Error: boom${escalation(3)}`);
      if (i === 4) expect(r.result).toBe(`Error: boom${escalation(4)}`);
    }
  });

  it("a success between errors resets the ladder to zero (AS:12744–12748)", () => {
    const g = newGuardState();
    recordToolResult(g, "run_shell", { n: 1 }, "Error: boom");
    recordToolResult(g, "run_shell", { n: 2 }, "Error: boom");
    const mid = recordToolResult(g, "run_shell", { n: 3 }, "clean output"); // success → 0
    expect(mid.result).toBe("clean output");
    expect(g.consecutiveErrors).toBe(0);
    recordToolResult(g, "run_shell", { n: 4 }, "Error: boom");
    const noEscalationYet = recordToolResult(g, "run_shell", { n: 5 }, "Error: boom");
    expect(noEscalationYet.result).toBe("Error: boom"); // only 2 in a row
    const third = recordToolResult(g, "run_shell", { n: 6 }, "Error: boom");
    expect(third.result).toBe(`Error: boom${escalation(3)}`); // fresh 3-run, not 6
  });

  it("isError tracks the classification (the loop's ok/error flag, AS:12742)", () => {
    const g = newGuardState();
    expect(recordToolResult(g, "t", {}, "Error: boom").isError).toBe(true);
    expect(recordToolResult(g, "t", {}, "tool error: invalid arguments JSON").isError).toBe(true);
    expect(recordToolResult(g, "t", {}, "clean output").isError).toBe(false);
  });

  it("DENIED results are NOT errors (Dart classifier — plan:598 divergence, see guards.ts)", () => {
    const g = newGuardState();
    const r = recordToolResult(g, "run_shell", {}, "DENIED: run_shell is not available in safe mode");
    expect(r.isError).toBe(false);
    expect(g.consecutiveErrors).toBe(0);
  });
});

describe("guards: looksLikeToolError — the six Dart clauses (AS:19753–19761)", () => {
  it.each([
    ["Error: command failed", "startsWith 'error'"],
    ["error: lowercase too", "startsWith 'error' (case-insensitive)"],
    ["tool error: invalid arguments JSON for run_shell", "startsWith 'tool error'"],
    ["File not found: /ws/a/missing.txt", "contains 'not found'"],
    ["ls: /root: permission denied", "contains 'permission denied'"],
    ["exit code 1 — command failed: npm test", "contains 'failed:'"],
    ["Uncaught exception: boom", "contains 'exception:'"],
  ])("%s → error (%s)", (text) => {
    expect(looksLikeToolError(text)).toBe(true);
  });

  it.each([
    ["clean tool output", "plain success"],
    ["fetch failed", "plan:598 lists this — Dart has no such clause (no colon)"],
    ["search failed", "plan:598 lists this — Dart has no such clause (no colon)"],
    ["DENIED: not available in this mode", "DENIED drives tool-card state, never consecutiveErrors"],
  ])("%s → NOT an error (%s)", (text) => {
    expect(looksLikeToolError(text)).toBe(false);
  });
});

describe("guards: budget boundary (AS:12340)", () => {
  it.each([
    [0, false],
    [11, false],
    [12, true],
    [13, false],
    [23, false],
    [24, true],
    [25, false],
    [36, true],
  ])("turn %i → %s", (turn, expected) => {
    expect(isBudgetBoundary(turn)).toBe(expected);
  });
});

describe("guards: NO_PROGRESS_LIMIT", () => {
  it("pins the Dart inline literal 6 (AS:12459 `turnsWithoutProgress < 6`)", () => {
    expect(NO_PROGRESS_LIMIT).toBe(6);
  });
});

describe("guards: todo follow-through nudge (AS:12516–12545)", () => {
  const todos: TodoItem[] = [
    { content: "write the tests", status: "pending" },
    { content: "implement the guards", status: "in_progress" },
  ];

  it("todoNudgeMessage renders pending/in_progress markers byte-for-byte (Dart 12537–12542)", () => {
    expect(todoNudgeMessage(todos)).toBe(TODO_NUDGE);
  });

  it("shouldSendTodoNudge: pending exist && !todoNudgeSent && turnsWithoutProgress < 5 (the 5 literal, AS:12524)", () => {
    expect(shouldSendTodoNudge(newGuardState(), todos)).toBe(true);
    expect(shouldSendTodoNudge({ ...newGuardState(), turnsWithoutProgress: 4 }, todos)).toBe(true);
    // false once sent — the loop sets g.todoNudgeSent BEFORE injecting (Dart AS:12525)
    expect(shouldSendTodoNudge({ ...newGuardState(), todoNudgeSent: true }, todos)).toBe(false);
    // false at 5 (one notch below NO_PROGRESS_LIMIT — the nudge budget is its own)
    expect(shouldSendTodoNudge({ ...newGuardState(), turnsWithoutProgress: 5 }, todos)).toBe(false);
  });

  it("no pending todos → never nudged", () => {
    const g = newGuardState();
    expect(shouldSendTodoNudge(g, [])).toBe(false);
    expect(
      shouldSendTodoNudge(g, [
        { content: "done", status: "completed" },
      ]),
    ).toBe(false);
  });
});
