# Session-link sharing: Read only and Collab

Status: implemented on `feat/session-link-collab`. This branch replaces review
plan PR-6f (F-179…F-192).

## Product summary

Sharing starts from a chat session (the share icon in the chat app bar, or a
long-press in the drawer). The share sheet opens with **one choice**:

| Mode | Who | What they get |
|---|---|---|
| **Read only** | anyone with the link | The session's visible text (user and assistant messages) as a snapshot. The owner can **Update link** to republish the current chat to the same URL. Viewers can refresh. |
| **Collab** | up to **10 people including the owner** | Join the same live session. Every message shows its author's name. Each person's turns run on **their own** selected model and **their own** key/billing. Everyone sees every prompt and AI reply as it lands. |

Private sync and the old token-and-code Collaboration screen are removed from
Settings. They were not settings, and the collaboration transport now lives
behind the share sheet.

## Links

| Kind | URL |
|---|---|
| Read only | `https://ovidsi.com/s/<shareToken>` |
| Collab | `https://ovidsi.com/s/<sessionToken>/<inviteCode>` |

* All three values are 43-character URL-safe base64 strings (256 bits). The
  share token comes from `secrets.token_urlsafe(32)`. The session token is the
  existing derived collaboration token. The invite code is an HMAC of a random
  invite ID under a server secret. The server stores only hashes of session
  tokens and invite codes.
* The public origin defaults to `https://ovidsi.com` and can be changed with
  `--dart-define=OVID_PUBLIC_SHARE_ORIGIN=…` in the app, `SHARE_BASE_URL` on
  the server, and the `ovidShareHost` Gradle property in the manifest. API
  calls go to `https://api.ovidsi.com` (`OVID_SHARE_BASE_URL`,
  `OVID_COLLABORATION_BASE_URL`).
* A session token on its own does not let anyone join. Joining needs the invite
  code, or an existing active membership.

### Opening a link

1. **App installed:** Android App Links (`autoVerify`, host `ovidsi.com`, path
   prefix `/s/`) open the app directly. `ShareLinkResolver` routes
   `/s/<t>` to the read-only viewer and `/s/<t>/<code>` to the Collab join
   screen.
2. **App not installed:** the link opens the account service's web page at
   `/s/…`. On Android, a small inline script with a fixed CSP hash navigates to
   `intent://ovidsi.com/s/…#Intent;scheme=https;package=<pkg>;S.browser_fallback_url=<Play>;end`.
   Chrome opens the app if it is installed and otherwise opens the Play
   listing. Desktop browsers get a readable page (read only) or an invite
   page (Collab), each with a Play button.
3. **Play install referrer:** the Play URL is
   `https://play.google.com/store/apps/details?id=<pkg>&referrer=share_token%3D<t>[%26invite%3D<code>]`.
   On first launch the app reads the referrer through the existing
   `getInstallReferrer` channel, stores the deferred link, and opens it.
4. `GET /.well-known/assetlinks.json` returns the Digital Asset Links
   statement when `OVID_ANDROID_RELEASE_CERT_SHA256` is set. It may hold
   several comma-separated fingerprints, for example the upload key and the
   Play App Signing key. Without it the endpoint returns 503
   `android_release_fingerprint_not_configured`. The package name comes from
   `OVID_ANDROID_PACKAGE_NAME` (default `com.dhanuk.ovidai`).

## Data model

Read only reuses `server/shares` (SQLite `shares` table). The only addition is
`PUT /shares/{token}`, which atomically replaces the snapshot of a live link
the caller owns. The token, expiry, and owner stay the same.

Collab reuses `server/collaboration`, with no table or column changes:

* `collab_sessions`, `collab_memberships` (owner plus participants; at most
  10 active, enforced inside the write transaction), `collab_invites` (the
  link is a multi-use invite), and `collab_events` (an ordered, append-only
  envelope log).
* **Author names** are stamped by the server into each event envelope as
  `senderDisplayName`. The name comes from the verified Firebase ID token:
  the `name` claim, falling back to the part of `email` before the `@`, then
  "Ovid user". It is trimmed, has control characters removed, and is capped
  at 64 characters. Clients cannot send this field (`serverField`
  rejection). Full email addresses are never exposed. `GET /chat/{t}` adds
  `displayName` to each member, taken from that member's most recent named
  event.
* The **message payload** gains optional fields `role` (`user` or
  `assistant`), `model` (a display label), and `replyTo` (event ID). Old
  `{text}` payloads still validate.

## API (account service)

Every call except the public pages needs `Authorization: Bearer <Firebase ID token>`
and `X-Firebase-AppCheck`, plus account lifecycle admission.

| Method & path | Purpose |
|---|---|
| `POST /shares` / `GET /shares?session_id=` / `DELETE /shares/{t}` | Read-only link create, list, and revoke (existing). |
| `PUT /shares/{t}` | **new** Replace the snapshot (owner only; live links only). |
| `GET /s/{t}` / `GET /s/{t}.json` | Public read-only page and snapshot JSON. |
| `GET /s/{t}/{code}` | **new** Public Collab invite page. It reveals no content and does no lookup. |
| `POST /chat` | Create a collab session (the caller becomes owner). |
| `POST /chat/{t}/members` `{maxUses, ttlSeconds}` | Create a link invite (owner). Links use up to 50 uses and a 7-day TTL. |
| `POST /chat/{t}/members` `{invitationCode}` | Join. Returns 409 `session_full` once 10 members are active. |
| `DELETE /chat/{t}/invites/{inviteId}` | **new** Revoke the link (owner). Current members stay. |
| `DELETE /chat/{t}/members/{participantId}` | Remove a member (owner). That member cannot rejoin with an older link. |
| `DELETE /chat/{t}/members/me` | Leave. |
| `POST /chat/{t}/close` | End the session for everyone (owner). |
| `POST /chat/{t}/events` | Append message, modelStatus, or presence events. |
| `GET /chat/{t}/events?cursor=&wait=0..25` | Replay. **new** `wait` turns it into a long poll. |

## Realtime transport

This reuses the existing collaboration transport: an append-only event log with
signed replay cursors and idempotent appends. The 15-second polling is replaced
by a **long poll**. While the Collab screen is open, the client issues
`GET /events?wait=25`. The server returns at once if events exist past the
cursor. Otherwise it re-checks the session head about once a second (a cheap
indexed read, run in a worker thread) and returns as soon as something
arrives, or after 25 s with an empty page. Delivery latency is about 1 s. Idle
cost is about 2.4 requests per member per minute. SSE or WebSockets were not
needed: long polling works through Caddy and Cloudflare without proxy changes,
and reuses the cursor and fencing logic as-is. Background or closed screens
fall back to the 15-second poll and then stop.

## Each participant uses their own model and key

* A turn runs **on the sender's device**:
  1. Append `message{role:user}` plus `modelStatus{running}`.
  2. Call the sender's selected provider and model with the shared transcript
     as context. This goes through `AgentService.completeCollaborationTurn`:
     no tools, nothing streamed into local chats, the local key.
  3. Append `message{role:assistant, model, replyTo}` plus
     `modelStatus{completed|failed}`.
* Keys never leave the device. The server only relays inert text. The event
  validator rejects credential-shaped metadata and any executable or tool
  fields. Remote events never trigger local execution: the reducer is pure and
  only projects state.
* Billing follows the key: an Ovid Cloud participant uses their own minted
  virtual key, and BYOK participants use their own keys. The owner's key is
  never used for another person's turn.

## Limits and abuse controls

* 10 active members per session, owner included, checked in the same
  transaction that admits a join. The 11th joiner gets
  "This session is full (10/10)".
* Link invite: at most 50 uses and a 7-day TTL. The owner can revoke it and
  issue a new link. Revocation leaves existing members in place. Removing a
  member bumps the session generation, so their older invites stop working.
* Rate limits per session: 120 appends and 600 replays per minute. The
  existing caps also apply: 10,000 events per rolling day, 100 MB retained,
  256 KB per event, and 1 MB per request body.
* Read-only links: 100 live links per owner, a 30-day TTL, 500 messages or
  200 KB per snapshot, and a filter for private text (thinking, tool and
  credential envelopes).
* Public pages send `noindex`, `no-store`, `no-referrer`, and a strict CSP.
  The only script is one fixed inline script allowed by its SHA-256 hash.
* Nothing logs tokens: Caddy keeps no access log for these routes, and errors
  never echo input.

## Out of scope / open decisions

* Collab is a separate live view (`CollabSessionScreen`). The owner's existing
  chat is copied in as context (the last 40 visible messages) when Collab
  starts. Turns in the live session are not written back into the owner's
  local chat.
* Each device can be in one Collab session at a time.
* Read-only links do not update themselves automatically. The owner taps
  **Update link**.
* The private sync core (`lib/core/private_sync`, `server/sync`) still exists
  but has no UI entry point. It was never enabled in release builds because
  `OVID_PRIVATE_SYNC_BASE_URL` was never defined. Removing it completely
  touches account deletion and reset, so it belongs in its own PR.
