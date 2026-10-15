/**
 * Key-provisioning contracts shared by the gateway (implementations live in
 * `apps/gateway/src/keys.ts`) and the worker (Task 9 consumes `KeyProvider`).
 *
 * Controller ruling: the INTERFACES live here in @ovid/shared so the worker
 * never imports from an app package; implementations stay in the gateway.
 * Types only — this module intentionally contains no runtime code.
 */

/**
 * Reads a user's provisioned model key from the mint service's Redis
 * (mint db2 — the connection URL carries the db selector, so implementations
 * do a plain `GET user:{uid}:key`). null = the user has no key yet.
 */
export interface KeyProvider {
  getKeyForUser(uid: string): Promise<string | null>;
}

/**
 * Ensures the caller has a key provisioned, forwarding the caller's identity
 * (Firebase ID token + App Check token) to the mint service. HTTP
 * implementations surface mint's non-2xx status/body on the thrown error so
 * the gateway can relay billing/rate-limit envelopes (402/429) verbatim.
 */
export interface MintProvisioner {
  ensureKey(idToken: string, appCheck: string | null): Promise<{ key: string }>;
}
