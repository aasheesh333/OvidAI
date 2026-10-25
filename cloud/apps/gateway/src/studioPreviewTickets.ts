import { randomBytes } from "node:crypto";

export const PREVIEW_TICKET_TTL_SECONDS = 60;
export const PREVIEW_COOKIE_TTL_SECONDS = 15 * 60;
export const PREVIEW_COOKIE_NAME = "__Host-ovid_preview";

const GRANT_BYTES = 32;
const GRANT_RE = /^[A-Za-z0-9_-]{43}$/;
const PREVIEW_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const DEFAULT_KEY_PREFIX = "ovid:studio:preview:";

export interface PreviewBinding {
  userId: string;
  sessionId: string;
  previewId: string;
  generation: number;
}

export interface PreviewCookieGrant extends PreviewBinding {
  /** Random server-side grant, never an Ovid session or API credential. */
  cookieToken: string;
  cookieExpiresAt: string;
}

export interface MintedPreviewGrants extends PreviewCookieGrant {
  ticket: string;
  ticketExpiresAt: string;
}

export interface PreviewTicketRedis {
  set(key: string, value: string, expiryMode: "EX", seconds: number): Promise<unknown>;
  get(key: string): Promise<string | null>;
  call(command: "GETDEL", key: string): Promise<unknown>;
}

export interface PreviewTicketStoreOptions {
  /** Isolated tests supply a suite-unique prefix; production uses the default. */
  keyPrefix?: string;
  now?: () => Date;
}

/**
 * Redis-backed scoped preview capabilities. Tickets are single use; cookie
 * grants are reusable only until their original absolute Redis expiry.
 */
export class PreviewTicketStore {
  private readonly keyPrefix: string;
  private readonly now: () => Date;

  constructor(
    private readonly redis: PreviewTicketRedis,
    options: PreviewTicketStoreOptions = {},
  ) {
    this.keyPrefix = options.keyPrefix ?? DEFAULT_KEY_PREFIX;
    this.now = options.now ?? (() => new Date());
  }

  async mint(binding: PreviewBinding): Promise<MintedPreviewGrants> {
    assertBinding(binding);
    const ticket = randomGrant();
    const cookieToken = randomGrant();
    const nowMs = this.now().getTime();
    if (!Number.isFinite(nowMs)) throw new Error("Preview grant clock is invalid.");
    const ticketExpiresAt = new Date(
      nowMs + PREVIEW_TICKET_TTL_SECONDS * 1_000,
    ).toISOString();
    const cookieExpiresAt = new Date(
      nowMs + PREVIEW_COOKIE_TTL_SECONDS * 1_000,
    ).toISOString();
    const stored = JSON.stringify({
      ...binding,
      cookieToken,
      cookieExpiresAt,
    } satisfies PreviewCookieGrant);

    // Create the cookie first. A failed ticket write can leave only an
    // unreferenced, expiring random grant; it can never leave a ticket whose
    // exchange appears to succeed without a valid cookie grant.
    await this.redis.set(
      this.cookieKey(cookieToken),
      stored,
      "EX",
      PREVIEW_COOKIE_TTL_SECONDS,
    );
    await this.redis.set(
      this.ticketKey(ticket),
      stored,
      "EX",
      PREVIEW_TICKET_TTL_SECONDS,
    );
    return {
      ...binding,
      ticket,
      cookieToken,
      ticketExpiresAt,
      cookieExpiresAt,
    };
  }

  /**
   * Atomically GETDELs the ticket. Supplying the expected binding makes a
   * mismatch a denial and still burns the one-use ticket, so it cannot be
   * probed and then replayed with a different claimed binding.
   */
  async consume(
    ticket: string,
    expected?: PreviewBinding,
  ): Promise<PreviewCookieGrant | null> {
    if (!GRANT_RE.test(ticket)) return null;
    const raw = await this.redis.call("GETDEL", this.ticketKey(ticket));
    if (typeof raw !== "string") return null;
    const grant = parseGrant(raw);
    if (grant === null || grant.cookieToken === undefined) return null;
    if (expected !== undefined && !sameBinding(grant, expected)) return null;
    return grant;
  }

  /** Verifies with GET only: no EXPIRE, touch, replacement, or silent slide. */
  async verifyCookie(
    cookieToken: string,
    expected: PreviewBinding,
  ): Promise<PreviewBinding | null> {
    if (!GRANT_RE.test(cookieToken)) return null;
    const raw = await this.redis.get(this.cookieKey(cookieToken));
    if (raw === null) return null;
    const grant = parseGrant(raw);
    if (
      grant === null ||
      grant.cookieToken !== cookieToken ||
      !sameBinding(grant, expected)
    ) {
      return null;
    }
    return {
      userId: grant.userId,
      sessionId: grant.sessionId,
      previewId: grant.previewId,
      generation: grant.generation,
    };
  }

  private ticketKey(ticket: string): string {
    return `${this.keyPrefix}ticket:${ticket}`;
  }

  private cookieKey(cookieToken: string): string {
    return `${this.keyPrefix}cookie:${cookieToken}`;
  }
}

export function createPreviewTicketStore(
  redis: PreviewTicketRedis,
  options: PreviewTicketStoreOptions = {},
): PreviewTicketStore {
  return new PreviewTicketStore(redis, options);
}

/** Exact host-only cookie; there is deliberately no Domain attribute. */
export function createPreviewCookie(cookieToken: string): string {
  if (!GRANT_RE.test(cookieToken)) throw new Error("Invalid preview cookie grant.");
  return `${PREVIEW_COOKIE_NAME}=${cookieToken}; Secure; HttpOnly; SameSite=Strict; Path=/`;
}

/** Reads exactly one valid preview cookie; duplicate capabilities fail closed. */
export function parsePreviewCookie(header: string | undefined): string | null {
  if (header === undefined) return null;
  let found: string | null = null;
  for (const part of header.split(";")) {
    const equals = part.indexOf("=");
    if (equals < 0) continue;
    const name = part.slice(0, equals).trim();
    if (name !== PREVIEW_COOKIE_NAME) continue;
    if (found !== null) return null;
    const value = part.slice(equals + 1).trim();
    if (!GRANT_RE.test(value)) return null;
    found = value;
  }
  return found;
}

export interface PreviewExchange {
  status: 303;
  location: string;
  setCookie: string;
  cacheControl: "private, no-store";
  referrerPolicy: "no-referrer";
  /** Composition must replace the exchange entry, not push a ticket URL. */
  history: "replace";
}

/**
 * Pure exchange response model. The one-use ticket is absent by construction:
 * this accepts only the already-consumed cookie grant and a clean preview ID.
 */
export function createPreviewExchange(grant: PreviewCookieGrant): PreviewExchange {
  assertBinding(grant);
  return {
    status: 303,
    location: `/preview/${grant.previewId}/`,
    setCookie: createPreviewCookie(grant.cookieToken),
    cacheControl: "private, no-store",
    referrerPolicy: "no-referrer",
    history: "replace",
  };
}

function randomGrant(): string {
  return randomBytes(GRANT_BYTES).toString("base64url");
}

function validBinding(value: unknown): value is PreviewBinding {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<PreviewBinding>;
  return (
    validIdentifier(candidate.userId) &&
    validIdentifier(candidate.sessionId) &&
    typeof candidate.previewId === "string" &&
    PREVIEW_ID_RE.test(candidate.previewId) &&
    Number.isSafeInteger(candidate.generation) &&
    (candidate.generation ?? 0) > 0
  );
}

function assertBinding(binding: PreviewBinding): void {
  if (!validBinding(binding)) throw new Error("Invalid preview grant binding.");
}

function validIdentifier(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= 512 &&
    !/[\u0000-\u001f\u007f]/.test(value)
  );
}

function sameBinding(a: PreviewBinding, b: PreviewBinding): boolean {
  return (
    a.userId === b.userId &&
    a.sessionId === b.sessionId &&
    a.previewId === b.previewId &&
    a.generation === b.generation
  );
}

function parseGrant(raw: string): PreviewCookieGrant | null {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) return null;
    const candidate = parsed as Partial<PreviewCookieGrant>;
    // `validBinding` deliberately narrows only the base binding. Read the
    // extended fields through a separate reference so that narrowing cannot
    // erase them from the type of this grant.
    const grant = candidate as PreviewCookieGrant;
    if (
      !validBinding(candidate) ||
      typeof grant.cookieToken !== "string" ||
      !GRANT_RE.test(grant.cookieToken) ||
      typeof grant.cookieExpiresAt !== "string" ||
      !Number.isFinite(Date.parse(grant.cookieExpiresAt))
    ) {
      return null;
    }
    return {
      userId: grant.userId,
      sessionId: grant.sessionId,
      previewId: grant.previewId,
      generation: grant.generation,
      cookieToken: grant.cookieToken,
      cookieExpiresAt: grant.cookieExpiresAt,
    };
  } catch {
    return null;
  }
}
