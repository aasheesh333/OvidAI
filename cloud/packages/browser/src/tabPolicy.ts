/**
 * Agent-owned tabs (product spec §8, "the agent opens the first tab; the user
 * cannot open tabs").
 *
 * The tab strip is created and extended by the AGENT only. A viewer may select
 * (`switch_tab`) or close an existing tab, but a user-initiated create is a
 * typed refusal — never a silent no-op and never a new page. Keeping the
 * policy in one module means the registry, the redis bridge and any future
 * transport all share the same error shape and copy.
 *
 * The client shows the plus button disabled with "Ovid opens tabs"; this
 * module is the SERVER boundary behind that nicety (a buggy or hostile client
 * can still publish a create request).
 */

export type TabActor = "agent" | "user";

/** Stable machine-readable code for the refusal (clients/tests may switch on it). */
export const TAB_CREATION_FORBIDDEN_CODE = "BROWSER_TAB_CREATION_FORBIDDEN";

/** The exact user-facing copy the disabled plus button carries. */
export const TAB_CREATION_FORBIDDEN_COPY = "Ovid opens tabs";

/** Longer explanation for logs / API error messages. */
export const TAB_CREATION_FORBIDDEN_MESSAGE =
  "Ovid opens tabs: the agent creates every tab. You can switch or close an existing tab.";

/**
 * Thrown when a non-agent actor tries to create a tab. Typed (class + stable
 * `code`) so a transport can map it to a refusal instead of a generic 500.
 */
export class BrowserTabCreationForbiddenError extends Error {
  readonly code = TAB_CREATION_FORBIDDEN_CODE;
  readonly actor: TabActor;
  readonly sessionId: string | null;

  constructor(actor: TabActor = "user", sessionId: string | null = null, message: string = TAB_CREATION_FORBIDDEN_MESSAGE) {
    super(message);
    this.name = "BrowserTabCreationForbiddenError";
    this.actor = actor;
    this.sessionId = sessionId;
  }
}

/**
 * Compatibility aliases: the refusal has been described both as a "tab
 * creation" and a "user tab creation" error. Both names point at the SAME
 * class so `instanceof` works for either spelling.
 */
export const TabCreationForbiddenError = BrowserTabCreationForbiddenError;
export const UserTabCreationForbiddenError = BrowserTabCreationForbiddenError;
export const TabCreateForbiddenError = BrowserTabCreationForbiddenError;
export const UserTabCreateForbiddenError = BrowserTabCreationForbiddenError;
/** Short alias for the stable code (same string as TAB_CREATION_FORBIDDEN_CODE). */
export const BROWSER_TAB_CREATE_FORBIDDEN = TAB_CREATION_FORBIDDEN_CODE;

/** True for the typed refusal (works across a duplicated module instance too). */
export function isTabCreationForbiddenError(err: unknown): err is BrowserTabCreationForbiddenError {
  if (err instanceof BrowserTabCreationForbiddenError) return true;
  return (
    typeof err === "object" &&
    err !== null &&
    (err as { code?: unknown }).code === TAB_CREATION_FORBIDDEN_CODE &&
    (err as { name?: unknown }).name === "BrowserTabCreationForbiddenError"
  );
}

/** True only for an EXPLICIT agent actor — `undefined` is a refusal. */
export function isAgentActor(actor: TabActor | undefined): boolean {
  return actor === "agent";
}

/**
 * Gate one tab-create request. Only an explicit `"agent"` actor passes;
 * anyone else (including an actor-less legacy call) gets the typed refusal
 * before any page is allocated or instrumented.
 */
export function assertTabCreationAllowed(
  actor: TabActor | undefined,
  sessionId: string | null = null,
): void {
  if (!isAgentActor(actor)) {
    throw new BrowserTabCreationForbiddenError(actor ?? "user", sessionId);
  }
}

/** Alias with the "agent-only" wording used by the registry call sites. */
export const assertAgentTabCreation = assertTabCreationAllowed;

/**
 * The single user-create entry point: always refuses. Exists so a transport
 * can route a user request here and get the typed error, rather than
 * accidentally calling the agent path.
 */
export function rejectUserTabCreation(sessionId: string | null = null): never {
  throw new BrowserTabCreationForbiddenError("user", sessionId);
}

/**
 * Recognise create-shaped ctl payloads from the wire. The shared
 * `BrowserCtlMsg` union deliberately has no `new_tab` member (the gateway
 * never sends one), but a buggy/older client may still publish one — the
 * bridge uses this to answer with the typed refusal instead of a generic
 * "schema-invalid" log.
 */
export function isUserTabCreateCtl(payload: unknown): boolean {
  if (typeof payload !== "object" || payload === null) return false;
  const type = (payload as { type?: unknown }).type;
  return type === "new_tab" || type === "create_tab";
}
