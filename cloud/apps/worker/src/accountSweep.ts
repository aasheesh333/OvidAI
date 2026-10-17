/**
 * Durable account-deletion sweep — the port of `server/account/worker.py`.
 *
 * Every pass re-reads `store.due(now)`; a crash or a poison row never loses
 * work because the lifecycle persists `next_attempt` BEFORE its effects and
 * the due ordering puts unattempted rows ahead of backed-off ones. Logs never
 * include a uid, token or credential.
 */

import type { DeletionStore, Lifecycle } from "@ovid/account";

/** The plan-pinned cadence (Python's systemd timer: every 30 s). */
export const ACCOUNT_SWEEP_INTERVAL_MS = 30_000;

export interface AccountSweeperDeps {
  lifecycle: Lifecycle;
  store: DeletionStore;
  intervalMs?: number;
  /** Injectable seconds clock (tests); defaults to the wall clock. */
  clock?: () => number;
}

export interface AccountSweeper {
  stop(): Promise<void>;
}

export function startAccountDeletionSweeper(deps: AccountSweeperDeps): AccountSweeper {
  const intervalMs = deps.intervalMs ?? ACCOUNT_SWEEP_INTERVAL_MS;
  const clock = deps.clock ?? (() => Date.now() / 1000);
  let stopped = false;
  let chain: Promise<void> = Promise.resolve();

  const pass = async (): Promise<void> => {
    if (stopped) return;
    let due: string[];
    try {
      due = await deps.store.due(clock());
    } catch {
      // Postgres down: the rows stay durable and the next pass retries.
      console.error("[account-sweep] due query failed; durable rows will be retried");
      return;
    }
    for (const uid of due) {
      try {
        await deps.lifecycle.finalize(uid, { scheduled: true });
      } catch {
        // No UID/token/credential/SQL exception contents in worker logs.
        console.error("[account-sweep] cleanup failed; durable record will be retried");
      }
    }
  };

  // Boot pass (systemd timer parity: one run before the interval).
  chain = pass();
  const timer = setInterval(() => {
    chain = chain.then(pass);
  }, intervalMs);
  timer.unref();

  return {
    async stop(): Promise<void> {
      stopped = true;
      clearInterval(timer);
      await chain;
    },
  };
}
