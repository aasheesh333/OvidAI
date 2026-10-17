/**
 * Tier-1 Lightpanda pool (P6 browser engine, Task 11; research §1/§7.1).
 *
 * Lightpanda is a CDP-compatible headless browser with a 1-context /
 * 1-page per process model (research §1.3), so a "pool" here is a capped
 * set of concurrently-spawned `lightpanda serve` processes with FIFO
 * admission beyond `cfg.maxTier1Processes` — NOT a set of long-lived
 * reusable processes:
 *
 *  - `acquire()` spawns a fresh `serve --host 127.0.0.1 --port P` proc on
 *    slot i (port 9400+i), waits for CDP readiness (retry connectOverCDP
 *    every 100 ms, <=5 s), and returns the lease.
 *  - `release()` ALWAYS kills the process and reaps it (SIGTERM -> 2 s
 *    grace -> SIGKILL). Cross-user hygiene is therefore BY CONSTRUCTION:
 *    no cookies/storage can ever survive a lease, because lightpanda
 *    offers no verifiable cookie wipe and one context per process
 *    (research §1.3, Review Focus #1).
 *
 * Ports bind 127.0.0.1 only. Everything is tracked so `close()` can reap
 * strays. The binary is host-provisioned (`OVID_LIGHTPANDA_BIN`, research
 * §1.4); `lightpandaAvailable` is the gate every consumer must check.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants, existsSync } from "node:fs";
import { chromium } from "playwright-core";

import type { BrowserEngineConfig } from "./config.js";

export class LightpandaError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LightpandaError";
  }
}

/** proc slot i listens on 127.0.0.1:LIGHTPANDA_PORT_BASE + i */
export const LIGHTPANDA_PORT_BASE = 9400;

/** CDP readiness budget for a freshly spawned serve process. */
const CDP_READY_TIMEOUT_MS = 5_000;

/** stdout cap for one-shot `fetch --dump markdown` runs. */
const ONESHOT_STDOUT_CAP = 4 * 1024 * 1024;

/** SIGKILL after this SIGTERM grace period (reap bound is a bit above it). */
const KILL_GRACE_MS = 2_000;

export function lightpandaAvailable(binPath: string | null): boolean {
  if (binPath === null) return false;
  try {
    if (!existsSync(binPath)) return false;
    accessSync(binPath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export interface LightpandaLease {
  slot: number;
  cdpUrl: string;
  pid: number;
}

export interface LightpandaPool {
  /** Spawns a serve proc (FIFO beyond cfg.maxTier1Processes). */
  acquire(timeoutMs: number): Promise<LightpandaLease>;
  /** acquire -> connectOverCDP -> single context/page -> goto(domcontentloaded) -> content() -> disconnect -> release. */
  readPage(url: string, timeoutMs: number): Promise<{ html: string; title: string; finalUrl: string }>;
  /** One-shot `bin fetch --dump markdown <url>` subprocess; stdout capped; non-zero exit/timeout => LightpandaError. */
  oneShotMarkdown(url: string, timeoutMs: number): Promise<{ markdown: string; title: string | null; finalUrl: string }>;
  /** ALWAYS kills + reaps the lease's process, then admits the next waiter. */
  release(lease: LightpandaLease): Promise<void>;
  /** Currently held leases. */
  running(): number;
  /** Kill all, reap all, reject waiters with LightpandaError. Idempotent. */
  close(): Promise<void>;
}

function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

export function createLightpandaPool(
  binPath: string,
  cfg: BrowserEngineConfig,
  opts: { spawnImpl?: typeof spawn; now?: () => number } = {},
): LightpandaPool {
  const doSpawn = opts.spawnImpl ?? spawn;
  const now = opts.now ?? Date.now;

  interface HeldProc {
    lease: LightpandaLease;
    child: ChildProcess;
  }

  // slot -> held lease (a held slot IS a live proc by construction).
  const held = new Map<number, HeldProc>();
  // Every spawned proc (serve + one-shot fetch) so close() can reap strays.
  const allProcs = new Set<ChildProcess>();
  const waiters: {
    timeoutMs: number;
    resolve(lease: LightpandaLease): void;
    reject(err: Error): void;
    timer: ReturnType<typeof setTimeout>;
  }[] = [];
  let closed = false;
  let closePromise: Promise<void> | null = null;

  function claimSlot(): number {
    for (let slot = 0; slot < cfg.maxTier1Processes; slot++) {
      if (!held.has(slot)) return slot;
    }
    return -1;
  }

  /** SIGTERM -> grace -> SIGKILL; resolves once the exit event landed (bounded). */
  function killAndReap(child: ChildProcess): Promise<void> {
    return new Promise((resolve) => {
      if (child.exitCode !== null || child.signalCode !== null) {
        resolve();
        return;
      }
      let settled = false;
      // Declared before `finish` so the defensive kill() failure path below
      // can clear them without hitting the temporal dead zone.
      let sigkillTimer: ReturnType<typeof setTimeout> | undefined;
      let boundTimer: ReturnType<typeof setTimeout> | undefined;
      const finish = () => {
        if (settled) return;
        settled = true;
        if (sigkillTimer !== undefined) clearTimeout(sigkillTimer);
        if (boundTimer !== undefined) clearTimeout(boundTimer);
        resolve();
      };
      child.once("exit", finish);
      try {
        child.kill("SIGTERM");
      } catch {
        finish();
        return;
      }
      sigkillTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // already dead — the exit event will settle us
        }
      }, KILL_GRACE_MS);
      // Absolute bound: even if the exit event were somehow lost, release()
      // must not hang the caller past the reap window.
      boundTimer = setTimeout(finish, KILL_GRACE_MS + 1_000);
      sigkillTimer.unref?.();
      boundTimer.unref?.();
    });
  }

  /** Retry connectOverCDP every 100 ms until ready or the deadline; resolves void. */
  async function waitForCdp(cdpUrl: string, budgetMs: number, child: ChildProcess): Promise<void> {
    const deadline = now() + budgetMs;
    const spawnFailed = new Promise<never>((_, reject) => {
      child.once("error", reject);
    });
    let lastErr: unknown = null;
    while (now() < deadline) {
      if (child.exitCode !== null) {
        throw new Error(`serve process exited early with code ${child.exitCode}`);
      }
      try {
        const browser = await Promise.race([
          chromium.connectOverCDP(cdpUrl, { timeout: Math.max(250, deadline - now()) }),
          spawnFailed,
        ]);
        // Readiness probe only — readPage opens its own connection. In
        // playwright-core 1.64 Browser has no disconnect(); close() on a
        // CDP-attached browser drops the connection without killing the
        // (about-to-be-released) process.
        try {
          await browser.close();
        } catch {
          // probe connection already gone; readiness is still proven
        }
        return;
      } catch (err) {
        lastErr = err;
      }
      await sleep(100);
    }
    throw new Error(`CDP not ready within ${budgetMs} ms (${errMessage(lastErr)})`);
  }

  /** Spawns `serve` on the slot's port and waits for CDP readiness. */
  async function spawnLease(slot: number, timeoutMs: number): Promise<LightpandaLease> {
    const port = LIGHTPANDA_PORT_BASE + slot;
    const cdpUrl = `http://127.0.0.1:${port}`;
    const child = doSpawn(binPath, ["serve", "--host", "127.0.0.1", "--port", String(port)], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    // Claim the slot synchronously so pump() can never double-admit.
    held.set(slot, { lease: { slot, cdpUrl, pid: child.pid ?? -1 }, child });
    allProcs.add(child);
    // Bounded stderr tail for diagnostics; pipes must be drained or the
    // child can block on a full pipe buffer.
    let stderrTail = "";
    child.stderr?.on("data", (chunk: Buffer) => {
      if (stderrTail.length < 8_192) stderrTail += chunk.toString("utf8");
    });
    // stdout is never consumed in serve mode — drain it so a chatty build
    // cannot fill the pipe and wedge the process.
    child.stdout?.on("data", () => undefined);

    try {
      await waitForCdp(cdpUrl, Math.min(CDP_READY_TIMEOUT_MS, timeoutMs), child);
    } catch (err) {
      allProcs.delete(child);
      // Keep the slot RESERVED through the kill/reap window (same rule as
      // release): a concurrent acquire must queue, never spawn onto a port
      // whose old process is still shutting down.
      try {
        await killAndReap(child);
      } finally {
        if (held.get(slot)?.child === child) held.delete(slot);
        pump();
      }
      throw new LightpandaError(
        `lightpanda serve failed to become CDP-ready on ${cdpUrl}: ${errMessage(err)}${stderrTail ? `; stderr: ${stderrTail.slice(-512)}` : ""}`,
      );
    }
    const entry = held.get(slot);
    if (!entry || entry.child !== child) {
      // close() cleared the pool while CDP was starting; close() already
      // killed the child. Surface a typed error, never a raw TypeError.
      throw new LightpandaError("The Lightpanda pool was closed while the serve process was starting.");
    }
    return entry.lease;
  }

  function pump(): void {
    while (waiters.length > 0 && held.size < cfg.maxTier1Processes) {
      const waiter = waiters.shift()!;
      clearTimeout(waiter.timer);
      void spawnLease(claimSlot(), waiter.timeoutMs).then(waiter.resolve, (err: unknown) => {
        waiter.reject(err instanceof Error ? err : new Error(String(err)));
      });
    }
  }

  function acquire(timeoutMs: number): Promise<LightpandaLease> {
    if (closed) {
      return Promise.reject(new LightpandaError("The Lightpanda pool is closed."));
    }
    const slot = claimSlot();
    if (slot !== -1) return spawnLease(slot, timeoutMs);
    return new Promise<LightpandaLease>((resolve, reject) => {
      const waiter = {
        timeoutMs,
        resolve,
        reject,
        timer: setTimeout(() => {
          const i = waiters.indexOf(waiter);
          if (i !== -1) waiters.splice(i, 1);
          reject(
            new LightpandaError(
              `The lightpanda pool is full (${cfg.maxTier1Processes} processes). The acquire was queued and timed out after ${timeoutMs} ms.`,
            ),
          );
        }, timeoutMs),
      };
      waiters.push(waiter);
    });
  }

  async function release(lease: LightpandaLease): Promise<void> {
    const entry = held.get(lease.slot);
    // Lease identity is (slot, pid), not slot alone: a stale/duplicate
    // release must never kill a NEWER lease that took the slot later.
    if (entry !== undefined && entry.lease.pid !== lease.pid) {
      pump();
      return;
    }
    try {
      if (entry !== undefined) {
        allProcs.delete(entry.child);
        // ALWAYS kill + reap — the process is never reused (hygiene by construction).
        await killAndReap(entry.child);
      }
    } finally {
      // The slot stays RESERVED (still in `held`) for the WHOLE kill/reap
      // window, so a concurrent acquire() sees the pool full and queues
      // behind existing FIFO waiters instead of spawning a replacement onto
      // a port whose old process is still shutting down (EADDRINUSE +
      // transient process-cap overshoot). Free it only after the reap.
      if (held.get(lease.slot) === entry) held.delete(lease.slot);
      pump();
    }
  }

  async function readPage(url: string, timeoutMs: number): Promise<{ html: string; title: string; finalUrl: string }> {
    const lease = await acquire(timeoutMs);
    try {
      const browser = await chromium.connectOverCDP(lease.cdpUrl, { timeout: Math.min(CDP_READY_TIMEOUT_MS, timeoutMs) });
      try {
        // Lightpanda: exactly ONE context per process (research §1.3) —
        // reuse the default context, never ask for a second one. The
        // context's auto-attached pages()[0] is a non-navigable STARTUP
        // session ("No page on the STARTUP session"), so a REAL target is
        // always created with newPage() — verified against the nightly.
        const context = browser.contexts()[0];
        if (!context) throw new LightpandaError("lightpanda exposed no default context over CDP");
        const page = await context.newPage();
        await page.goto(url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
        const html = await page.content();
        const title = await page.title();
        const finalUrl = page.url();
        return { html, title, finalUrl };
      } finally {
        try {
          // close() on a CDP-attached browser drops our connection; the
          // release below kills the process regardless.
          await browser.close();
        } catch {
          // connection already gone; the release below still kills the proc
        }
      }
    } catch (err) {
      throw err instanceof LightpandaError
        ? err
        : new LightpandaError(`lightpanda readPage failed for ${url}: ${errMessage(err)}`);
    } finally {
      await release(lease);
    }
  }

  function oneShotMarkdown(
    url: string,
    timeoutMs: number,
  ): Promise<{ markdown: string; title: string | null; finalUrl: string }> {
    if (closed) return Promise.reject(new LightpandaError("The Lightpanda pool is closed."));
    return new Promise((resolve, reject) => {
      const child = doSpawn(binPath, ["fetch", "--dump", "markdown", url], {
        stdio: ["ignore", "pipe", "pipe"],
      });
      allProcs.add(child);
      const chunks: Buffer[] = [];
      let total = 0;
      let stderrTail = "";
      let done = false;

      const fail = (message: string): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        void killAndReap(child);
        reject(new LightpandaError(message));
      };
      const timer = setTimeout(
        () => fail(`lightpanda fetch timed out after ${timeoutMs} ms for ${url}`),
        timeoutMs,
      );

      child.stdout?.on("data", (chunk: Buffer) => {
        total += chunk.length;
        if (total > ONESHOT_STDOUT_CAP) {
          fail(`lightpanda fetch stdout exceeded the ${ONESHOT_STDOUT_CAP} byte cap for ${url}`);
          return;
        }
        chunks.push(chunk);
      });
      child.stderr?.on("data", (chunk: Buffer) => {
        if (stderrTail.length < 8_192) stderrTail += chunk.toString("utf8");
      });
      child.once("error", (err: Error) => {
        allProcs.delete(child);
        fail(`lightpanda fetch failed to spawn: ${errMessage(err)}`);
      });
      child.once("close", (code, signal) => {
        allProcs.delete(child);
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (code !== 0) {
          reject(
            new LightpandaError(
              `lightpanda fetch exited with code ${code} (signal ${signal ?? "none"}) for ${url}${stderrTail ? `: ${stderrTail.slice(-512)}` : ""}`,
            ),
          );
          return;
        }
        resolve({ markdown: Buffer.concat(chunks).toString("utf8"), title: null, finalUrl: url });
      });
    });
  }

  function running(): number {
    return held.size;
  }

  function close(): Promise<void> {
    if (closePromise) return closePromise;
    closed = true;
    closePromise = (async () => {
      const queued = waiters.splice(0);
      for (const waiter of queued) {
        clearTimeout(waiter.timer);
        waiter.reject(new LightpandaError("The Lightpanda pool is closed."));
      }
      const entries = [...held.values()];
      held.clear();
      await Promise.allSettled(
        entries.map((entry) => {
          allProcs.delete(entry.child);
          return killAndReap(entry.child);
        }),
      );
      const strays = [...allProcs];
      allProcs.clear();
      await Promise.allSettled(strays.map((child) => killAndReap(child)));
    })();
    return closePromise;
  }

  return { acquire, readPage, oneShotMarkdown, release, running, close };
}
