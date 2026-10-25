import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import {
  accountSettings,
  attachments,
  byokKeysRepo,
  eventMirror,
  messages,
  projectsRepo,
  runs,
  runUsage,
  sessionState,
  sessions,
  users,
  type Db,
  type MessageRow,
  type RunRow,
} from "@ovid/db";
import { AGENT_RUN_JOB_NAME } from "@ovid/queue";
import {
  branchSessionBodySchema,
  CLOUD_PRESET_IDS,
  MAX_PROJECT_REFS,
  MAX_SESSION_REFS,
  manualModelsAllowed,
  MintInternalError,
  regenerateBodySchema,
  sendMessageBodySchema,
  type MessageDto,
  type MessagePage,
  type SendMessageResponse,
  type SessionDto,
  type SessionEvent,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { DEFAULT_MINT_TIMEOUT_MS, MintTimeoutError } from "../keys.js";
import { verifiedEdgeNetwork } from "../rateLimits.js";
import {
  evaluateTokenCaps,
  utcDayStart,
  utcMonthStart,
} from "../tokenCaps.js";
import { isDurableWorkerSession, refusePublicWorkerControl } from "./workerControlGuards.js";
import {
  badRequest,
  etagFor,
  isUuid,
  matchesIfNoneMatch,
  notFound,
  parsePageLimit,
  queryValue,
  sendError,
  zodBadRequest,
} from "./http.js";

// Message routes — all mounted inside the authenticated /cloud/v1 scope.

export function toMessageDto(
  row: MessageRow,
  files?: ReadonlyArray<{ id: string; name: string; size: number }>,
): MessageDto {
  return {
    id: row.id,
    sessionId: row.sessionId,
    role: row.role as MessageDto["role"],
    content: row.content,
    createdAt: row.createdAt.toISOString(),
    // Absent (not null) when the row captured no reasoning: the field is
    // additive, so a client that predates it sees an unchanged payload.
    ...(row.reasoning !== null && row.reasoning !== "" ? { reasoning: row.reasoning } : {}),
    ...(files !== undefined && files.length > 0
      ? { attachments: files.map((f) => ({ id: f.id, name: f.name, sizeBytes: f.size })) }
      : {}),
  };
}

/** Wave 1b: the most events one history page carries (newest kept on overflow). */
export const HISTORY_EVENT_LIMIT = 2000;
/** Wave 1b: the most streamed chunks folded into a live run's text. */
const LIVE_DELTA_LIMIT = 20_000;
// History mutation is deliberately unavailable until send and mutations
// share a PostgreSQL serialization protocol and transactional job outbox.
// In particular, activeForSession -> truncate is NOT a cross-worker guard.
function historyActionsUnavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    409,
    "history_actions_unavailable",
    "Your chat is kept unchanged. Changing earlier messages, retrying a finished task and branching are unavailable.",
  );
}

/**
 * Events after which a live run's bubble starts fresh on the client: the
 * in-progress text of a reopened run is only the deltas AFTER the last of
 * these (run_started_retry carries no runId — it can only belong to the
 * active run once that run has started).
 */
const BUBBLE_BOUNDARY_TYPES = new Set([
  "run_started",
  "message_segment",
  "tool_started",
  "tool_completed",
  "run_started_retry",
]);

// The send body schema lives in @ovid/shared (sendMessageBodySchema) — the
// one copy, documented there: content, attachmentIds (P8 Task 3),
// clientMsgId (P8 Task 4) and maxOutputTokens (the Settings "Max output
// tokens" pick; validated int 1..MAX_OUTPUT_TOKENS_CAP, additive).
const sendMessageBody = sendMessageBodySchema;

/**
 * P8 Task 4: resolve a (sessionId, clientMsgId) that already exists.
 * - "none": no row holds the key — the send proceeds.
 * - "replay": the existing message produced a run → the route answers 202
 *   with the ORIGINAL {runId, userMessageId, status:"queued"} and inserts
 *   nothing (SendMessageResponse's status union is literally "queued" — the
 *   replay replays the original answer verbatim; run liveness is the client's
 *   to poll via GET /runs/:id).
 * - "conflict": the message has NO run (e.g. imported history holds the id)
 *   → 409 run_conflict, still inserting nothing.
 */
type ClientMsgIdResolution =
  | { kind: "none" }
  | { kind: "replay"; runId: string; userMessageId: string }
  | { kind: "conflict" };

async function resolveClientMsgId(
  db: Db,
  sessionId: string,
  clientMsgId: string,
): Promise<ClientMsgIdResolution> {
  const existing = await messages.findByClientMsgId(db, sessionId, clientMsgId);
  if (existing === null) return { kind: "none" };
  const run = await runs.getByPromptMessageId(db, existing.id);
  return run !== null
    ? { kind: "replay", runId: run.id, userMessageId: existing.id }
    : { kind: "conflict" };
}

// Review round 1 (IMPORTANT): the 409 window. A message row commits BEFORE
// its runs.create — a same-key concurrent send that resolves inside that gap
// observes "message exists, no run", which is the conflict shape, but the run
// is merely not there YET. Concluding 409 there would make a client that
// regenerates its key on 409 defeat the whole idempotency feature. So a
// conflict verdict is re-checked a bounded number of times before it is
// believed; if the run appears, the answer becomes the 202 replay.
const CONFLICT_HEAL_RETRIES = 3;
const CONFLICT_HEAL_DELAY_MS = 25;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** resolveClientMsgId, plus bounded healing of the transient conflict window. */
async function resolveClientMsgIdHealing(
  db: Db,
  sessionId: string,
  clientMsgId: string,
): Promise<ClientMsgIdResolution> {
  let resolved = await resolveClientMsgId(db, sessionId, clientMsgId);
  for (let attempt = 0; attempt < CONFLICT_HEAL_RETRIES && resolved.kind === "conflict"; attempt++) {
    await sleep(CONFLICT_HEAL_DELAY_MS);
    resolved = await resolveClientMsgId(db, sessionId, clientMsgId);
  }
  return resolved;
}

/** postgres unique-violation (23505), searching drizzle's .cause chain for the driver error. */
function isUniqueViolation(err: unknown): boolean {
  let e: unknown = err;
  for (let depth = 0; e instanceof Error && depth < 5; depth++) {
    if ((e as { code?: unknown }).code === "23505") return true;
    e = (e as { cause?: unknown }).cause;
  }
  return false;
}

/**
 * P10 Task 2: bounded internal-mint call. The provisioner contract takes no
 * signal, so the deadline is enforced here with a race — every provisioner
 * implementation is bounded, and the HTTP implementation ALSO passes its own
 * AbortSignal to fetch so the socket is released.
 *
 * P9 Task 9: the call carries the gateway's OWN verified uid. No client
 * Firebase token or App Check header crosses this boundary.
 */
async function ensureKeyBounded(deps: GatewayDeps, uid: string): Promise<void> {
  const timeoutMs = deps.mintTimeoutMs ?? DEFAULT_MINT_TIMEOUT_MS;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      deps.mint.ensureKeyForUid(uid),
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new MintTimeoutError(timeoutMs)), timeoutMs);
        timer.unref?.();
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * The mint's contract errors cross the wire as FastAPI-parity {"detail": …}
 * bodies (HttpContractError — the legacy APK depends on that shape), which
 * the thin client cannot parse: it reads only the gateway's
 * {error:{code,message}} envelope (cloud_rest.dart _toError). Extract the
 * human-readable detail for re-enveloping; a non-string/absent detail falls
 * back to the client's own generic wording.
 */
function mintDetail(body: unknown): string {
  if (typeof body === "string" && body.trim() !== "") return body;
  const detail = (body as { detail?: unknown } | null)?.detail;
  return typeof detail === "string" && detail !== "" ? detail : "Ovid Cloud request failed.";
}

/**
 * Client-mapped codes for relayed mint verdicts: 402 is the free-cap stop,
 * and the client's whole 402 UX (outbox keeps the prompt, chat error row +
 * resets-at countdown) is documented against `daily_limit_reached`
 * (cloud_session_store.dart, chat_screen.dart's _CloudErrorRow). 429 has no
 * dedicated client mapping — `rate_limited` matches the code the mint itself
 * answers for LiteLLM 429s (mintRoutes.ts).
 */
function mintRelayCode(status: number): string {
  return status === 402 ? "daily_limit_reached" : "rate_limited";
}

/**
 * `x-ovid-resets-at` off the mint response, re-emitted as epoch ms — the
 * exact shape the client's _resetsAt parses first (all-digits → epoch ms;
 * anything else must be ISO). An ISO stamp from the mint is converted; a
 * missing or unparseable value returns null (the client renders no countdown).
 */
function resetsAtEpochMs(headers: Readonly<Record<string, string>>): string | null {
  const raw = (headers["x-ovid-resets-at"] ?? headers["resets-at"] ?? "").trim();
  if (raw === "") return null;
  if (/^\d+$/.test(raw)) return raw;
  const ms = Date.parse(raw);
  return Number.isNaN(ms) ? null : String(ms);
}

/**
 * Key provisioning BEFORE any write for ordinary send: null =
 * the key is there, proceed; otherwise the reply already sent. A deadline
 * breach is a retryable 503; mint 402/429 verdicts are re-enveloped for the
 * thin client with any resets-at forwarded as x-ovid-resets-at; everything
 * else collapses to 409 key_not_minted.
 */
async function provisionKey(
  deps: GatewayDeps,
  request: FastifyRequest,
  reply: FastifyReply,
  uid: string,
  sessionId: string,
): Promise<FastifyReply | null> {
  try {
    await ensureKeyBounded(deps, uid);
    return null;
  } catch (err) {
    // P10 Task 2: a deadline breach is a bounded, retryable dependency
    // failure — NOT a "this account has no key" verdict.
    if (
      err instanceof MintTimeoutError ||
      (typeof err === "object" && err !== null && (err as { name?: unknown }).name === "TimeoutError")
    ) {
      request.log.warn({ err, sessionId }, "key provisioning timed out; run not enqueued");
      return sendError(reply, 503, "unavailable", "Key provisioning timed out; please retry shortly.");
    }
    if (err instanceof MintInternalError && (err.status === 402 || err.status === 429)) {
      const response = reply.code(err.status);
      const resetsAt = resetsAtEpochMs(err.headers);
      if (resetsAt !== null) response.header("x-ovid-resets-at", resetsAt);
      return response.send({
        error: { code: mintRelayCode(err.status), message: mintDetail(err.body) },
      });
    }
    request.log.warn({ err, sessionId }, "key provisioning failed; run not enqueued");
    return sendError(reply, 409, "key_not_minted", "No model API key is provisioned for this account.");
  }
}

/**
 * Wave 1b (CH-006): this page's settled agent activity — the non-delta
 * events whose ts falls inside the page's time window (from its oldest row
 * when older rows exist, up to the newer page's first row), capped at the
 * snapshot's [lastEventSeq] — plus, on the newest page, ONE coalesced
 * `message_delta` carrying the active run's in-progress text since its last
 * bubble boundary (a chat reopened mid-run shows the live answer, CH-002).
 */
async function historyEvents(
  db: Db,
  sessionId: string,
  o: {
    rows: MessageRow[];
    nextCursor: string | null;
    beforeId: string | null;
    lastEventSeq: string | null;
    active: RunRow | null;
  },
): Promise<SessionEvent[]> {
  if (o.lastEventSeq === null) return [];
  const oldest = o.rows[o.rows.length - 1];
  const fromTs = o.nextCursor !== null && oldest !== undefined ? oldest.createdAt : null;
  let toTs: Date | null = null;
  if (o.beforeId !== null) {
    const boundary = await messages.getInSession(db, sessionId, o.beforeId);
    if (boundary === null) return [];
    toTs = boundary.createdAt;
  }
  const events = await eventMirror.readWindow(db, sessionId, {
    fromTs,
    toTs,
    maxSeq: o.lastEventSeq,
    limit: HISTORY_EVENT_LIMIT,
  });
  const active = o.active;
  if (o.beforeId !== null || active === null || active.status !== "running") return events;

  // The active run's bubble boundary: its run_started and every later
  // boundary event in the window.
  let startIndex = -1;
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const e = events[i]!;
    if (e.type === "run_started" && e.payload.runId === active.id) {
      startIndex = i;
      break;
    }
  }
  if (startIndex === -1) return events;
  let boundarySeq = events[startIndex]!.seq;
  for (let i = startIndex + 1; i < events.length; i += 1) {
    const e = events[i]!;
    if (!BUBBLE_BOUNDARY_TYPES.has(e.type)) continue;
    const runId = e.payload.runId;
    if (runId === undefined || runId === active.id) boundarySeq = e.seq;
  }
  const deltas = await eventMirror.deltasForRun(db, sessionId, active.id, {
    afterSeq: boundarySeq,
    maxSeq: o.lastEventSeq,
    limit: LIVE_DELTA_LIMIT,
  });
  const last = deltas[deltas.length - 1];
  if (last === undefined) return events;
  const text = deltas.map((d) => (typeof d.payload.text === "string" ? d.payload.text : "")).join("");
  const coalesced: SessionEvent = {
    sessionId,
    seq: last.seq,
    type: "message_delta",
    payload: { runId: active.id, text },
    ts: last.ts,
  };
  return [...events, coalesced].sort((a, b) => compareSeqStrings(a.seq, b.seq));
}

/** Redis stream ids "<ms>-<sub>", compared numerically on both parts. */
function compareSeqStrings(a: string, b: string): number {
  const [am = "0", as = "0"] = a.split("-");
  const [bm = "0", bs = "0"] = b.split("-");
  const dm = Number(am) - Number(bm);
  if (dm !== 0) return dm;
  return Number(as) - Number(bs);
}

// ---------------------------------------------------------------------------
// Wave 1a — per-turn settings helpers
// ---------------------------------------------------------------------------

/** agent-core routing.ts AUTO_ALIASES (the gateway does not depend on agent-core). */
const AUTO_MODEL_ALIASES: readonly string[] = ["auto", "ovid-cloud/auto"];
/** agent-core routing.ts EFFORT_SUFFIX — Dart `·\s*(low|medium|high)$`. */
const EFFORT_SUFFIX = /·\s*(low|medium|high)$/i;

/** The catalog id under an optional " · low|medium|high" effort suffix. */
function baseModelId(raw: string): string {
  const m = EFFORT_SUFFIX.exec(raw);
  return (m === null ? raw : raw.slice(0, m.index)).trim();
}

function isAutoModel(base: string): boolean {
  return base === "" || AUTO_MODEL_ALIASES.includes(base.toLowerCase());
}

/**
 * The allowed model ids (lowercased) or null when the catalog is unknown —
 * the documented fail-open (absent seam, null answer, empty list or a thrown
 * read all mean "cannot judge"; LiteLLM's key scope still bounds the run).
 */
async function readModelCatalog(
  deps: GatewayDeps,
  log: { warn(obj: unknown, msg?: string): void },
): Promise<Set<string> | null> {
  if (deps.modelCatalog === undefined) return null;
  try {
    const list = await deps.modelCatalog();
    if (list === null || list.length === 0) return null;
    return new Set(list.map((m) => m.trim().toLowerCase()));
  } catch (err) {
    log.warn({ err }, "model catalog unavailable; accepting the requested model");
    return null;
  }
}

/** `@[Title]` tokens (R1 explicit session tags). */
const TITLE_MENTION_RE = /@\[([^\]\n]{1,200})\]/g;

/**
 * Resolves `@[Title]` mentions to the caller's session ids: case-insensitive
 * exact title match among live sessions, excluding the current one. An
 * ambiguous title (two sessions share it) or an unknown one is ignored —
 * never guessed.
 */
async function resolveTitleMentions(
  deps: GatewayDeps,
  uid: string,
  currentSessionId: string,
  content: string,
): Promise<string[]> {
  const titles: string[] = [];
  for (const m of content.matchAll(TITLE_MENTION_RE)) {
    const t = m[1]!.trim();
    if (t !== "") titles.push(t);
  }
  if (titles.length === 0) return [];
  const rows = await sessions.findByTitles(deps.db, uid, titles);
  const byTitle = new Map<string, string[]>();
  for (const row of rows) {
    if (row.id === currentSessionId) continue;
    const key = row.title.trim().toLowerCase();
    byTitle.set(key, [...(byTitle.get(key) ?? []), row.id]);
  }
  const out: string[] = [];
  for (const t of titles) {
    const ids = byTitle.get(t.toLowerCase());
    if (ids !== undefined && ids.length === 1 && !out.includes(ids[0]!)) out.push(ids[0]!);
  }
  return out;
}

/**
 * Writes the present settings into the session's agent state (and the mode
 * onto the sessions row so the DTO agrees). Returns the effective model the
 * session will request ("auto" when unpinned).
 */
async function persistTurnSettings(
  deps: GatewayDeps,
  sessionId: string,
  uid: string,
  s: {
    modelPin: string | null | undefined;
    mode: SessionDto["mode"] | undefined;
    planMode: boolean | undefined;
    presetId: string | undefined;
  },
): Promise<string> {
  const current = await sessionState.get(deps.db, sessionId);
  const patch: Parameters<typeof sessionState.patch>[2] = {};
  if (s.modelPin !== undefined) patch.modelPin = s.modelPin;
  if (s.mode !== undefined) patch.mode = s.mode;
  if (s.presetId !== undefined) patch.presetId = s.presetId;
  if (s.planMode !== undefined) {
    // A change becomes a pending transition the loop applies at the run's
    // first turn boundary (entering/leaving plan mode correctly records and
    // restores the pre-plan mode there). Unchanged = no transition; a stale
    // pending opposite transition is cancelled.
    if (s.planMode !== current.planMode) patch.pendingPlanMode = s.planMode;
    else if (current.pendingPlanMode !== null) patch.pendingPlanMode = null;
  }
  if (Object.keys(patch).length > 0) await sessionState.patch(deps.db, sessionId, patch);
  if (s.mode !== undefined) await sessions.update(deps.db, sessionId, uid, { mode: s.mode });
  const pin = s.modelPin !== undefined ? s.modelPin : current.modelPin;
  return pin === null || pin.trim() === "" ? "auto" : pin;
}

/** The session's requested model right now ("auto" when unpinned) — replay answers. */
async function currentModel(deps: GatewayDeps, sessionId: string): Promise<string> {
  const pin = (await sessionState.get(deps.db, sessionId)).modelPin;
  return pin === null || pin.trim() === "" ? "auto" : pin;
}

/** 50000000 → "50,000,000". Deterministic (no locale-dependent grouping). */
function grouped(n: number): string {
  return String(Math.trunc(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/**
 * The plan's token ceiling — the product's 50M/day + 1.5B/month (paid tiers
 * scaled by their multiplier), counted from the `run_usage` ledger the worker
 * already writes. A send is refused only when a window is ALREADY spent: the
 * gateway cannot know how many tokens the next run will use, so it stops at
 * the ceiling rather than estimating.
 *
 * The refusal reuses the ONE allowance vocabulary the clients already map:
 * 402 `daily_limit_reached` plus the epoch-ms `x-ovid-resets-at` countdown.
 * The mint already relays its monthly cap under this same code, so naming the
 * monthly window with it is consistent, not a third refusal shape — and the
 * web client's `modelRefusalMessage` treats every other 402 as a model gate.
 *
 * Returns null when the send may proceed.
 */
async function tokenCapRefusal(
  deps: GatewayDeps,
  reply: FastifyReply,
  uid: string,
  tier: string | null | undefined,
  now: Date,
): Promise<FastifyReply | null> {
  const [today, month] = await Promise.all([
    runUsage.totals(deps.db, { userId: uid, since: utcDayStart(now), until: now, billingClass: "ovid_allowance" }),
    runUsage.totals(deps.db, { userId: uid, since: utcMonthStart(now), until: now, billingClass: "ovid_allowance" }),
  ]);
  const verdict = evaluateTokenCaps({ tier, now, today, month });
  if (verdict === null) return null;

  const window = verdict.window === "day" ? "daily" : "monthly";
  const response = reply.code(402);
  response.header("x-ovid-resets-at", String(verdict.resetsAt.getTime()));
  return response.send({
    error: {
      code: "daily_limit_reached",
      message: `You have used your plan's ${window} token allowance (${grouped(
        verdict.cap,
      )} tokens). It resets at ${verdict.resetsAt.toISOString()}.`,
    },
  });
}

export function registerMessageRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/sessions/:id/messages", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid, email } = request.principal;

    // 0. Key-abuse admission — FIRST, before ownership, body validation, mint,
    //    any write or the queue. One Ovid key belongs to one person; a key
    //    seen from abnormally many independent networks in the policy window
    //    is treated as stolen/shared and refused (0 requests). The decision
    //    itself is the pure `evaluateIpAnomaly`; the guard only resolves the
    //    trusted client IP and appends the observation.
    //
    //    Client IP: `request.socket.remoteAddress` (the socket peer) plus
    //    X-Forwarded-For ONLY when that peer is a configured reverse proxy.
    //    `request.ip` is NOT used: trustProxy is deliberately off, so a
    //    direct client could otherwise choose its own address. See
    //    clientIp.ts for the exact hop read and the Caddy contract.
    //
    //    A configured automatic guard persists account standing and blocks live
    //    keys BEFORE sanitized registered-email delivery. Mail failure is only
    //    an outcome here: it never turns this refusal back into an allow.
    if (deps.ipAnomaly !== undefined) {
      const edge = verifiedEdgeNetwork(request);
      const decision = await deps.ipAnomaly.admit(uid, {
        peerAddress: request.socket.remoteAddress,
        forwardedFor: request.headers["x-forwarded-for"],
        // Raw client/proxy ASN headers are not evidence. Only the complete
        // signed edge bundle verified by the rate-limit pre-handler is used.
        ...(edge !== undefined ? { edge } : {}),
      });
      if (decision.block) {
        request.log.warn(
          {
            uid,
            reason: decision.reason,
            suspension: decision.suspension,
            mailOutcome: decision.mailOutcome,
          },
          "ip anomaly: send refused (key blocked)",
        );
        return sendError(
          reply,
          403,
          "ip_anomaly_blocked",
          "This account is temporarily blocked after unusual network activity. Contact support if this is unexpected.",
        );
      }
    }

    // 1. Ownership FIRST: wrong owner and unknown session are both 404 (never
    //    403), before body validation so nobody can probe a session they
    //    don't own through validation behavior. The shape guard folds a
    //    malformed :id into the same 404 envelope (identical message — still
    //    no existence leaks) and keeps client garbage away from the db.
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    // A durable child shares its parent's owner, but a Firebase-owned child ID
    // is not main-agent authority. Fence before replay, mint, writes, or queue.
    if (await isDurableWorkerSession(deps.db, sessionId)) {
      return refusePublicWorkerControl(reply);
    }

    // 2. Body validation: missing/empty/whitespace-only content → 400.
    const parsed = sendMessageBody.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const content = parsed.data.content;
    if (content.trim() === "") {
      return badRequest(reply, "content must be a non-empty string.");
    }

    // 2b. clientMsgId idempotency (P8 Task 4) — BEFORE attachment validation:
    //     a retry whose attachmentIds went stale/garbage must still replay
    //     the original answer (the ORIGINAL send already succeeded), and a
    //     conflicting id must never create rows. Runs before mint too, so a
    //     replay touches no side effects at all. Conflict verdicts heal
    //     (bounded re-check) — the winner's run may not exist yet.
    const clientMsgId = parsed.data.clientMsgId;
    if (clientMsgId !== undefined) {
      const resolved = await resolveClientMsgIdHealing(deps.db, sessionId, clientMsgId);
      if (resolved.kind === "replay") {
        const body: SendMessageResponse = {
          runId: resolved.runId,
          userMessageId: resolved.userMessageId,
          status: "queued",
          model: await currentModel(deps, sessionId),
        };
        return reply.code(202).send(body);
      }
      if (resolved.kind === "conflict") {
        return sendError(
          reply,
          409,
          "run_conflict",
          "This clientMsgId is already used by a message that has no run.",
        );
      }
    }

    // 2c. Attachment validation (P8 Task 3) — BEFORE any write (no orphan
    //     rows on a 400). Every id must resolve to an attachment row of THIS
    //     session; getForSession is session-scoped, so a valid id belonging to
    //     another session counts as unknown.
    const requestedAttachmentIds = [...new Set(parsed.data.attachmentIds ?? [])];
    if (requestedAttachmentIds.length > 0) {
      const known = await attachments.getForSession(
        deps.db,
        sessionId,
        requestedAttachmentIds,
      );
      if (known.length !== requestedAttachmentIds.length) {
        return badRequest(reply, "attachmentIds contains an unknown attachment id.");
      }
    }

    // 2d-pre. Provision the users row before the per-turn settings are
    //    validated: its tier decides whether a named model is allowed at all
    //    (step 2d) and sets the queue priority (step 5). The upsert is
    //    idempotent, and it must happen before the FK-dependent writes below.
    const user = await users.ensure(deps.db, uid, email);

    // 2d. Wave 1a per-turn settings — validated BEFORE mint and any write
    //     (and after the replay check: a retry of an accepted send replays
    //     the original answer whatever its settings say now).
    const settings = parsed.data;
    if (settings.presetId !== undefined && !(CLOUD_PRESET_IDS as readonly string[]).includes(settings.presetId)) {
      return badRequest(reply, `presetId must be one of: ${CLOUD_PRESET_IDS.join(", ")}.`);
    }
    let modelPin: string | null | undefined;
    if (settings.model !== undefined) {
      const raw = settings.model.trim();
      const base = baseModelId(raw);
      if (raw === "" || isAutoModel(base)) {
        modelPin = null;
      } else {
        // Plan gate, server-side. The picker greys these out for Free and Go,
        // but a greyed control is a courtesy, not a boundary: a modified
        // client could still POST a premium model, and one request on a
        // $99/1M-token model would spend a free account's month. The tier is
        // read here, at the moment of the send, from the same users row the
        // queue priority uses.
        if (!manualModelsAllowed(user.tier)) {
          return sendError(
            reply,
            402,
            "manual_model_not_allowed",
            "Choosing a model is a paid-plan feature. Use Auto, or upgrade in Settings.",
          );
        }
        const known = await readModelCatalog(deps, request.log);
        if (known !== null && !known.has(base.toLowerCase())) {
          return sendError(
            reply,
            400,
            "model_unavailable",
            "That model is not available on Ovid Cloud. Pick another model.",
          );
        }
        modelPin = raw;
      }
    }
    // R1: the explicit @-tags — sessionRefs ids plus `@[Title]` tokens.
    const explicitRefs = [...new Set(settings.sessionRefs ?? [])];
    for (const ref of explicitRefs) {
      const owned = ref !== sessionId && isUuid(ref) ? await sessions.get(deps.db, ref, uid) : null;
      if (owned === null) return badRequest(reply, "sessionRefs contains an unknown session.");
    }
    const mentioned = await resolveTitleMentions(deps, uid, sessionId, content);
    const sessionRefs = [...new Set([...explicitRefs, ...mentioned])].slice(0, MAX_SESSION_REFS);

    // W1 follow-up: explicit `@project:<id>` refs. FAIL-SAFE: the WHOLE send
    // is refused (typed 400, before mint and any write) on an over-limit,
    // duplicated, malformed, foreign or unknown ref. We never drop a bad ref
    // and never partially include the rest — a silently missing project would
    // make the model answer without context the user believes it has.
    // Malformed ids and >MAX_PROJECT_REFS are rejected by the shared schema
    // (zodBadRequest, 400) above; this loop covers the semantic cases.
    const rawProjectRefs = settings.projectRefs ?? [];
    if (rawProjectRefs.length > MAX_PROJECT_REFS) {
      return sendError(
        reply,
        400,
        "too_many_project_refs",
        `You can reference at most ${MAX_PROJECT_REFS} projects in one message.`,
      );
    }
    const seenProjectRefs = new Set<string>();
    for (const ref of rawProjectRefs) {
      if (seenProjectRefs.has(ref)) {
        return sendError(
          reply,
          400,
          "duplicate_project_ref",
          "projectRefs contains the same project more than once.",
        );
      }
      seenProjectRefs.add(ref);
      // Owner-scoped: unknown and foreign are indistinguishable (no leaks).
      const ownedProject = await projectsRepo.get(deps.db, uid, ref);
      if (ownedProject === null) {
        return sendError(
          reply,
          400,
          "unknown_project_ref",
          "projectRefs contains a project you do not own.",
        );
      }
    }
    const projectRefs = rawProjectRefs;

    // 4. Key provisioning BEFORE any write: if mint fails, no message row,
    //    no run row and no queue job are left behind (ordering pinned by
    //    messages.test.ts). 402/429 verdicts are re-enveloped for the thin
    //    client (the mint's {"detail":…} shape is FastAPI parity, which the
    //    client cannot parse) with any resets-at forwarded as
    //    x-ovid-resets-at; every other failure collapses to 409 key_not_minted.
    //    P9 Task 9: mint is called with the gateway's own verified uid
    //    (signed server-to-server).
    // Snapshot the caller's billing choice before accepting the message. BYOK
    // must not mint/check an Ovid key (including its exhausted allowance), and
    // a stale/foreign key must never silently fall back to Ovid billing.
    const byokDefault = (await accountSettings.get(deps.db, uid)).byokDefault;
    if (byokDefault !== null && (await byokKeysRepo.get(deps.db, byokDefault.keyId, uid)) === null) {
      return sendError(reply, 409, "key_not_minted", "Your selected API key is unavailable. Update it in Settings.");
    }
    if (byokDefault === null) {
      // 4a. The plan's token ceiling, BEFORE mint and before any write. It
      //     counts only Ovid-billed sends: a BYOK send spends the user's own
      //     key, so the Ovid allowance does not apply to it (same rule as the
      //     mint-relayed 402 below). Refusing here means no key is minted and
      //     no message/run/job is left behind.
      const tokenRefusal = await tokenCapRefusal(
        deps,
        reply,
        uid,
        user.tier,
        deps.clock?.() ?? new Date(),
      );
      if (tokenRefusal !== null) return tokenRefusal;

      const mintFailure = await provisionKey(deps, request, reply, uid, sessionId);
      if (mintFailure !== null) return mintFailure;
    }

    // 5. Persist the user message, create the run row, then enqueue. With a
    //    clientMsgId the insert is guarded by the per-session partial unique
    //    index: a concurrent same-key send that raced past the check above
    //    resolves here into the same replay/409 answer — never a 500.
    let userMessage: MessageRow;
    try {
      userMessage = await messages.append(deps.db, {
        sessionId,
        role: "user",
        content,
        ...(clientMsgId !== undefined ? { clientMsgId } : {}),
      });
    } catch (err) {
      if (clientMsgId === undefined || !isUniqueViolation(err)) throw err;
      // The losing side of a concurrent same-key race — and it may be landing
      // inside the winner's message-commit→runs.create gap, so the verdict
      // heals the same way (bounded re-check) before any 409 is answered.
      const resolved = await resolveClientMsgIdHealing(deps.db, sessionId, clientMsgId);
      if (resolved.kind === "replay") {
        const body: SendMessageResponse = {
          runId: resolved.runId,
          userMessageId: resolved.userMessageId,
          status: "queued",
          model: await currentModel(deps, sessionId),
        };
        return reply.code(202).send(body);
      }
      return sendError(
        reply,
        409,
        "run_conflict",
        "This clientMsgId is already used by a message that has no run.",
      );
    }
    // Wave 1b (CH-006): the uploads ride under this prompt in history.
    await attachments.linkToMessage(deps.db, sessionId, requestedAttachmentIds, userMessage.id);
    const run = await runs.create(deps.db, {
      sessionId,
      promptMessageId: userMessage.id,
    });
    const priority = user.tier === "free" ? 2 : 1;

    // 5b. Wave 1a: persist the turn's settings into the session's agent state
    //     (what the worker's loop reads: modelPin, mode, presetId, pending
    //     plan transition) — only for a NEW accepted send, never a replay.
    const effectiveModel = await persistTurnSettings(deps, sessionId, uid, {
      modelPin,
      mode: settings.mode,
      planMode: settings.planMode,
      presetId: settings.presetId,
    });
    try {
      await deps.queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        // P2 Task 12: tier rides the payload so the worker's sandbox attach
        // applies the tier-matched workspace quota (optional on the wire —
        // old consumers simply never see it). P8 Task 3: attachmentIds ride
        // the same way, present ONLY when the request sent a non-empty list
        // (the job wire stays additive for pre-P8 consumers). maxOutputTokens
        // rides identically: the Settings output cap, present only when the
        // request sent one (the worker maps it onto the engine request's
        // maxTokens; absent = the provider's own default).
        {
          runId: run.id,
          sessionId,
          userId: uid,
          prompt: content,
          tier: user.tier,
          ...(byokDefault !== null
            ? { byokKeyId: byokDefault.keyId, byokModel: byokDefault.model }
            : {}),
          ...(requestedAttachmentIds.length > 0
            ? { attachmentIds: requestedAttachmentIds }
            : {}),
          ...(parsed.data.maxOutputTokens !== undefined
            ? { maxOutputTokens: parsed.data.maxOutputTokens }
            : {}),
          // Wave 1a: the access chip rides the job (job wins in the loop),
          // and the explicit @-tags are the ONLY other sessions this run may
          // see (R1).
          ...(settings.mode !== undefined ? { mode: settings.mode } : {}),
          ...(sessionRefs.length > 0 ? { sessionRefs } : {}),
          // W1 follow-up: project refs ride the job for THIS run only. The
          // worker injects their memory and never persists it on the session.
          ...(projectRefs.length > 0 ? { projectRefs } : {}),
        },
        { jobId: run.id, priority },
      );
    } catch (err) {
      // Documented ruling: the user message row stays and the run row is LEFT
      // 'queued' (not deleted) so an operator/reconciler can re-enqueue it;
      // the client sees 503 and can retry (jobId=runId keeps re-adds
      // idempotent on the queue side).
      request.log.error({ err, runId: run.id, sessionId }, "queue add failed; run row left queued");
      return sendError(
        reply,
        503,
        "unavailable",
        "Run queue is temporarily unavailable; please retry shortly.",
      );
    }

    // 6. Bump session activity and answer 202 — the run executes async.
    // P7 Task 12: a send is the strongest activity signal — the tracker the
    // hibernator consults. Best-effort by design (pinned): a redis blip must
    // never fail an otherwise-accepted send. WS watching does NOT bump
    // (passive — pinned in Task 10's trigger rationale); P2 (pty) and P6
    // (browser) add their own bumps at their channels.
    if (deps.activity !== undefined) {
      void deps.activity.bump(sessionId).catch(() => {});
    }
    await sessions.touch(deps.db, sessionId);
    const body: SendMessageResponse = {
      runId: run.id,
      userMessageId: userMessage.id,
      status: "queued",
      model: effectiveModel,
    };
    return reply.code(202).send(body);
  });

  app.get("/sessions/:id/messages", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    // Ownership 404 first — same rule as every other :id route (malformed :id
    // folds into the same envelope via the shape guard, never a 500).
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, request.principal.uid);
    if (session === null) return notFound(reply);

    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    // DOCUMENTED CHOICE: a malformed `before` is IGNORED and the first page is
    // served — the same lenient degradation the sessions-list `cursor` has
    // (garbage cursor → first page, pinned in sessions.test.ts). Not a 400:
    // paging params stay clamp-or-ignore everywhere, and an unguarded value
    // would reach the keyset id comparison, where bpchar string ordering makes
    // results arbitrary (e.g. before=0 filters EVERY UUIDv7 id out → empty
    // page instead of the intended "no valid cursor → start over").
    const rawBefore = queryValue(query.before);
    const beforeId = rawBefore !== null && isUuid(rawBefore) ? rawBefore : null;
    const rawEvents = queryValue(query.events);
    const wantEvents = rawEvents === "1" || rawEvents === "true";
    // Wave 1b (CH-003): the watermark is read BEFORE the page, so every
    // event at or below it is reflected by (or older than) the snapshot; a
    // client that subscribes from it never replays the log on top of the
    // page, and anything committed meanwhile replays after it (the client's
    // messageId guard keeps that exactly-once).
    const lastEventSeq = await eventMirror.maxSeq(deps.db, sessionId);
    const { rows, nextCursor } = await messages.page(deps.db, sessionId, {
      limit,
      beforeId,
    });
    const active = await runs.activeForSession(deps.db, sessionId);
    const files = await attachments.forMessages(
      deps.db,
      sessionId,
      rows.filter((r) => r.role === "user").map((r) => r.id),
    );
    const filesByMessage = new Map<string, typeof files>();
    for (const f of files) {
      if (f.messageId === null) continue;
      const key = f.messageId.trim();
      filesByMessage.set(key, [...(filesByMessage.get(key) ?? []), f]);
    }
    const body: MessagePage = {
      // Newest-first keyset page (UUIDv7 id order); nextCursor is the oldest id.
      items: rows.map((r) => toMessageDto(r, filesByMessage.get(r.id.trim()))),
      nextCursor,
      lastEventSeq,
      activeRun:
        active === null
          ? null
          : { runId: active.id, status: active.status === "running" ? "running" : "queued" },
    };
    if (wantEvents) {
      body.events = await historyEvents(deps.db, sessionId, {
        rows,
        nextCursor,
        beforeId,
        lastEventSeq,
        active,
      });
    }

    // W12 — conditional GET for repeat history loads. Chat transcripts are
    // PER-USER and MUTABLE, so this is deliberately NOT public caching:
    // `private, no-cache` forbids shared/CDN storage and forces revalidation,
    // while the ETag lets an unchanged page answer 304 with no body. Vary by
    // Authorization so no intermediary can mix two users' representations.
    // The ownership check above always runs first — a foreign uid still sees
    // the same 404, never a 304 oracle.
    const etag = etagFor(body);
    const ifNoneMatch = request.headers["if-none-match"];
    const inm = Array.isArray(ifNoneMatch) ? ifNoneMatch.join(",") : ifNoneMatch;
    const headers = {
      etag,
      "cache-control": "private, no-cache",
      pragma: "no-cache",
      vary: "Authorization, Accept-Encoding",
      "x-content-type-options": "nosniff",
    };
    if (matchesIfNoneMatch(inm, etag)) {
      return reply.code(304).headers(headers).send();
    }
    return reply.headers(headers).send(body);
  });

  // -------------------------------------------------------------------------
  // Wave 1b (CT-004 / CH-024): history edits. Every route is ownership-first
  // (wrong owner and unknown ids are the same 404). Mutations are release-
  // gated, including while idle, until an atomic DB/outbox contract exists.
  // -------------------------------------------------------------------------

  /** R4 gate: a separate destructive delete cannot implement atomic edit. */
  app.delete("/sessions/:id/messages/:messageId", async (request, reply) => {
    const { id: sessionId, messageId } = request.params as { id: string; messageId: string };
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, request.principal.uid);
    if (session === null) return notFound(reply);
    if (!isUuid(messageId)) return notFound(reply, "Message not found.");
    if ((await messages.getInSession(deps.db, sessionId, messageId)) === null) {
      return notFound(reply, "Message not found.");
    }
    return historyActionsUnavailable(reply);
  });

  /** Drop an answer (and anything after it) and run its prompt again. */
  app.post("/sessions/:id/messages/:messageId/regenerate", async (request, reply) => {
    const { id: sessionId, messageId } = request.params as { id: string; messageId: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    const parsed = regenerateBodySchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (!isUuid(messageId)) return notFound(reply, "Message not found.");
    const target = await messages.getInSession(deps.db, sessionId, messageId);
    if (target === null) return notFound(reply, "Message not found.");
    if (target.role !== "assistant" && target.role !== "user") {
      return badRequest(reply, "Only an answer or a prompt can be run again.");
    }
    return historyActionsUnavailable(reply);
  });

  /** A new chat seeded with this chat's history up to and including a message. */
  app.post("/sessions/:id/branch", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    const parsed = branchSessionBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const anchor = await messages.getInSession(deps.db, sessionId, parsed.data.messageId);
    if (anchor === null) return notFound(reply, "Message not found.");
    return historyActionsUnavailable(reply);
  });
}
