# Ovid Si Premium Share and Domain Design

## Goal

Make Ovid Si a premium, high-trust product across its 45 audited surfaces,
provide shareable session links that can open or restore a conversation in the
app, and migrate the public gateway from `cloud.dhanuksoftwares.com` to
`api.ovidsi.com` without downtime.

## Product decisions

- Each chat session has one canonical share URL that can be shared unlimited
  times.
- The shared representation is an immutable, read-only snapshot.
- A recipient can authenticate and create an owned fork, then continue that
  fork. The original owner’s session is never mutated by the recipient.
- A missing app uses a web resolver that redirects to Google Play while
  preserving the share token through an install/deferred-deep-link mechanism.
- An installed app opens the shared snapshot directly.
- Share snapshots exclude credentials, hidden reasoning, tool state, private
  metadata, and non-allowlisted attachments.
- `api.ovidsi.com` is not used by the app until DNS, TLS, Caddy, and endpoint
  health checks are confirmed.
- The old hostname remains available during a rollback window.
- UI scores are earned through measurable improvements; score values are not
  edited without corresponding UX changes and verification.

## Architecture

The existing share service and public viewer remain the security boundary. A
canonical share record is resolved by a web/app link layer. The app validates
the token, shows the snapshot, and requires authentication before creating an
owned fork. The fork endpoint is idempotent and owner-scoped.

The domain migration is staged: Cloudflare zones and nameservers first, then
the `api` record and origin TLS, then Caddy routing, endpoint probes, and only
then Flutter/server URL constants. DNS changes are performed only through the
authorized PowerHost and Cloudflare accounts.

## UX quality bar

Every audited screen must have explicit loading, empty, success, error, and
recovery states where applicable; visible hierarchy; keyboard/safe-area
support; semantic labels; reduced-motion behavior; and a clear primary action.
The scorecard is re-run after implementation with evidence and screenshots.

## Security and rollback

Public links are bearer capabilities with expiry/revocation. Forking requires
Firebase authentication and server-side ownership checks. Share tokens never
appear in analytics or diagnostic logs. The old API hostname remains a tested
rollback target until the new DNS and TLS path has passed production probes.
