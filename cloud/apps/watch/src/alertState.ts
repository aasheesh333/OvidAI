import type { CheckResult } from "./checks.js";

/**
 * Edge-triggered alert state (Review Focus #5).
 *
 * Level-triggered checks are evaluated every minute, but an operator is
 * notified only on a state EDGE:
 *   - ok/unknown → fail: alert immediately (a monitor installed while broken
 *     must speak up),
 *   - fail → fail: silent until `repeatAfterMs` (default 30 min) has elapsed
 *     since the last delivered alert, then one reminder,
 *   - fail → ok: one recovery notice, then silence.
 *
 * `nextState` is the boolean map persisted to the state file. `nextAlertAt`
 * (additive to the plan's pinned return shape) carries the epoch-ms of the
 * last DELIVERED alert per check — without it a stateless one-shot process
 * cannot distinguish "first failure" from "still failing". main persists it
 * only for alerts that actually delivered, so a dead token retries next run.
 */

export const DEFAULT_REPEAT_AFTER_MS = 30 * 60 * 1_000;

export interface DiffStateOptions {
  now: Date;
  /** Default 30 min. Re-alert a still-failing check only after this window. */
  repeatAfterMs?: number;
  /** Epoch-ms of the last delivered alert per check (from the state file). */
  lastAlertAt?: Record<string, number>;
}

export interface DiffStateResult {
  alerts: CheckResult[];
  recovered: CheckResult[];
  nextState: Record<string, boolean>;
  /** Additive: epoch-ms of the alert recorded by THIS pass, per check. */
  nextAlertAt: Record<string, number>;
}

export function diffStates(
  prev: Record<string, boolean>,
  curr: CheckResult[],
  opts: DiffStateOptions,
): DiffStateResult {
  const nowMs = opts.now.getTime();
  const repeatAfterMs = opts.repeatAfterMs ?? DEFAULT_REPEAT_AFTER_MS;
  const lastAlertAt = opts.lastAlertAt ?? {};

  const alerts: CheckResult[] = [];
  const recovered: CheckResult[] = [];
  const nextState: Record<string, boolean> = {};
  const nextAlertAt: Record<string, number> = {};

  for (const check of curr) {
    nextState[check.name] = check.ok;
    const was = prev[check.name];
    const last = lastAlertAt[check.name];

    if (!check.ok) {
      // Unknown→fail is an edge (first observation); fail→fail is not.
      const transitioned = was !== false;
      const neverAlerted = last === undefined;
      const due = transitioned || neverAlerted || nowMs - last >= repeatAfterMs;
      if (due) {
        alerts.push(check);
        nextAlertAt[check.name] = nowMs;
      } else {
        nextAlertAt[check.name] = last;
      }
    } else if (was === false) {
      recovered.push(check);
      // No nextAlertAt entry: a future failure is a fresh edge.
    }
  }

  return { alerts, recovered, nextState, nextAlertAt };
}
