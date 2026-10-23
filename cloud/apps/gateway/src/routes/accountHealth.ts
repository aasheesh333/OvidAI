import type { FastifyInstance } from "fastify";
import { accountDeletions, artifactVault, runUsage, users } from "@ovid/db";
import { planFor, storageBytes } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { badRequest, queryValue } from "./http.js";

/**
 * Account health — one honest aggregate for the Account Health screen.
 *
 * The screen used to have nothing to read, so the spec row said "ABSENT".
 * This route is the server's answer to four questions, and it answers ONLY
 * from state the server actually owns:
 *
 *   - storage: the vault ledger (uploads + active generated artifacts)
 *     against the plan's quota (`storageBytes`, the same table the plan
 *     screen reads);
 *   - usage: the `run_usage` token ledger for today and this month;
 *   - standing: the ban flag on `users` and the account's deletion row;
 *   - plan: the stored tier and the limits the server enforces for it.
 *
 * The one thing the gateway does NOT know is how much spending allowance is
 * left. That is mint/LiteLLM state (a USD window kept in the mint's Redis),
 * not a gateway table, and the gateway has no read path to it. So
 * `remainingUsd` is `null` — never `0`. A zero would tell a paying user
 * "you have nothing left" when the server simply cannot see the number.
 * The recorded tokens (`used`) ARE real, so the screen can still show what
 * this account has consumed without pretending to know the remainder.
 *
 * Only the caller's own rows are read: every query is scoped by the
 * authenticated principal's uid, and a `uid` in the query string is ignored.
 */

const MAX_OFFSET_MINUTES = 840;
const DAY_MS = 86_400_000;

/** States in which a deletion request is still going to happen. */
const PENDING_DELETION_STATES: ReadonlySet<string> = new Set([
  "pending",
  "fenced",
  "deleting",
]);

function iso(value: Date | string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  const at = value instanceof Date ? value : new Date(value);
  return Number.isNaN(at.getTime()) ? null : at.toISOString();
}

/** Epoch seconds → ISO; a value the server cannot represent is null. */
function epochIso(seconds: number | null | undefined): string | null {
  if (typeof seconds !== "number" || !Number.isFinite(seconds)) return null;
  const at = new Date(seconds * 1000);
  return Number.isNaN(at.getTime()) ? null : at.toISOString();
}

function parseOffset(raw: string | null): number | null {
  if (raw === null) return 0;
  if (!/^-?\d+$/.test(raw.trim())) return null;
  const n = Number(raw);
  return Number.isInteger(n) && n >= -MAX_OFFSET_MINUTES && n <= MAX_OFFSET_MINUTES
    ? n
    : null;
}

export function registerAccountHealthRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/account/health", async (request, reply) => {
    const q = (request.query ?? {}) as Record<string, string | string[] | undefined>;
    const offset = parseOffset(queryValue(q.utcOffsetMinutes));
    if (offset === null) {
      return badRequest(
        reply,
        `utcOffsetMinutes must be an integer in [-${MAX_OFFSET_MINUTES}, ${MAX_OFFSET_MINUTES}].`,
      );
    }

    const { uid, email } = request.principal;
    const now = deps.clock?.() ?? new Date();
    const offsetMs = offset * 60_000;

    // "Today" and "this month" are the caller's calendar, not the server's:
    // shift into local time, take the boundary, shift back to an instant.
    const localNow = new Date(now.getTime() + offsetMs);
    const todaySince = new Date(
      Math.floor(localNow.getTime() / DAY_MS) * DAY_MS - offsetMs,
    );
    const monthSince = new Date(
      Date.UTC(localNow.getUTCFullYear(), localNow.getUTCMonth(), 1) - offsetMs,
    );

    // ensure() is idempotent and returns the stored row, which is where the
    // tier, expiry and ban flag live. It never changes tier or ban state.
    const user = await users.ensure(deps.db, uid, email);

    const [storage, today, month, deletion] = await Promise.all([
      artifactVault.usage(deps.db, uid),
      runUsage.totals(deps.db, { userId: uid, since: todaySince, until: now }),
      runUsage.totals(deps.db, { userId: uid, since: monthSince, until: now }),
      accountDeletions.get(deps.db, uid),
    ]);

    // `planFor` is the server's own resolution (unknown → Free, legacy
    // spellings → the tier they mean), so these limits are the ones actually
    // enforced — not a second table that could drift from it.
    const plan = planFor(user.tier);
    const quotaBytes = storageBytes(user.tier);

    reply.header("Cache-Control", "no-store");
    return {
      plan: {
        /** The stored tier, verbatim (a legacy `7x` stays `7x`). */
        tier: user.tier,
        /** The plan that tier resolves to — the one whose limits apply. */
        id: plan.id,
        name: plan.name,
        /** Paid-tier expiry; null when the plan does not expire. */
        expiresAt: iso(user.tierExpiresAt),
        limits: {
          storageBytes: quotaBytes,
          customConnectors: plan.customConnectors,
          projectFiles: plan.projectFiles,
          manualModels: plan.manualModels,
          autoMultiplier: plan.autoMultiplier,
          uploads: { count: plan.uploads.count, windowHours: plan.uploads.windowHours },
        },
      },
      storage: {
        usedBytes: storage.usedBytes,
        quotaBytes,
        /** Clamped: over-quota is "none left", never a negative number. */
        remainingBytes: Math.max(0, quotaBytes - storage.usedBytes),
      },
      usage: {
        today: {
          since: todaySince.toISOString(),
          until: now.toISOString(),
          /** Tokens actually recorded by the worker — a real fact. */
          used: today,
          /** Mint/LiteLLM state; the gateway cannot see it. */
          remainingUsd: null,
        },
        month: {
          since: monthSince.toISOString(),
          until: now.toISOString(),
          used: month,
          remainingUsd: null,
        },
      },
      standing: {
        banned: user.bannedAt !== null && user.bannedAt !== undefined,
        bannedAt: iso(user.bannedAt),
        bannedReason: user.bannedReason ?? null,
        /**
         * The spec's "multi-IP flag" has no server-side detector or column.
         * null states that plainly; false would claim the account was
         * checked and came back clean.
         */
        multiIpFlags: null,
        /**
         * The caller's own deletion row, projected to the three fields the
         * screen needs. `record` is the lifecycle worker's internal payload
         * (snake_case, retry/fence bookkeeping) and never leaves the server.
         */
        deletion:
          deletion === null
            ? null
            : {
                state: deletion.state,
                pending: PENDING_DELETION_STATES.has(deletion.state),
                deleteAfter: epochIso(deletion.deleteAfter),
              },
      },
    };
  });
}
