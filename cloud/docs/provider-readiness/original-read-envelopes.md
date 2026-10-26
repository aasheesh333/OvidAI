# Provider readiness — original curated connectors: read-envelope validation

Review and implementation date: **2026-10-26**. Production-live-supported rows:
**0**. Nothing in this document changes that number.

## What was missing

Nine curated originals were still executed by the generic REST engine with no
provider-specific response parsing:

`gitlab`, `jira`, `figma`, `sentry`, `exa`, `notion`, `airtable`, `firebase`,
`discord`.

The engine proves only "HTTP 2xx + parseable JSON". For these providers a 2xx
body can still be a soft failure or a wrong-tenant answer — an Atlassian
`{"errorMessages": [...]}`, a Figma `{"status":403,"err":"..."}`, a Discord
`{"message":"401: Unauthorized","code":0}`, a Notion `{"object":"error"}` — and
the model received it as a successful read. The other curated handlers
(Linear, Slack, Telegram, Google Drive, Supabase, Cloudflare) and the whole
data-search/commerce batches already had a named-shape check.

## What was added

`cloud/packages/mcp/src/rest/descriptors/readEnvelopes.ts`:

- `readShapeError(providerId, operationId, payload)` — the documented shape of
  each published read, and a stable reason when the body does not match.
- `withReadEnvelope(providerId, handler)` — delegates the request to the
  unchanged engine handler, then rejects a non-document body with one fixed
  message: `Provider returned an unexpected read response.`
  Provider payload text and credentials are never echoed.

Wiring (so all three production construction paths agree):

| Path | File |
| --- | --- |
| Catalog / gateway manifest handlers | `src/catalog.ts` |
| Worker activation overrides | `src/activation.ts` (`createCuratedProviderSupport`) |
| Discord handler facade | `src/rest/descriptors/comms.ts` |

`src/egress/redactor.ts` also now replaces a JSON **key** that contains a
credential value with the marker as a whole key. Substring replacement produced
`{"commen[REDACTED]s":[]}`, i.e. invalid JSON, which made any post-redaction
parser (including this new envelope check) reject a valid read.

## Evidence class

**Source only.** The evidence is a synthetic fixture suite:
`src/rest/descriptors/readEnvelopes.test.ts` (46 cases) plus
`src/egress/redactor.test.ts`. It proves the parser, the two wiring paths, and
the fixed non-leaking error text. No provider credential was used and no
provider was contacted, so:

- no row gains `liveReadEvidence`;
- no `releaseState` changes;
- `PRODUCTION_PROVIDER_REGISTRY.catalogDefinitions()` and `CURATED_IDS` remain
  empty.

Promotion for any of these nine still requires the existing live gates: an
opt-in run with a real credential for that provider, a real bounded read, and
`credentials: "passed"` on the readiness row.

## Remaining gaps in this group

| Provider | Remaining blocker |
| --- | --- |
| gitlab, jira, figma, sentry, exa, notion, airtable, firebase, discord | live credential + live read not provided |
| jira, figma, sentry | tenant origin is dynamic (`{host}` / `{tenant}`), so the catalog projection still excludes it until per-connection origin composition exists |
| firebase | requires a user ID token / OAuth token; a web API key is deliberately rejected |
| discord | OAuth user token required; a bot token is not interchangeable |
