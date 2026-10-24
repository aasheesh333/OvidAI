# Connector Task 9 — documents, data, search, and finance

Review and implementation date: **2026-10-24**. Base requested by the brief:
`9d1f22bd425a3c950487079e45eed02cd112235d`.

## Status semantics

- **Contract candidate** means the official read, credential profile, fixed
  origin, closed input, bounded request, and sanitized response have automated
  contract evidence. It does **not** mean production readiness.
- **Release blocked** means the row is absent from `CURATED_IDS`,
  `CURATED_DESCRIPTORS`, and the production `CURATED_MANIFEST`.
- All 26 rows are currently **release blocked**. Fifteen have executable
  contract candidates; eleven have no descriptor because the required safe
  handler/auth model is absent. All fifteen contract candidates additionally
  lack live credentials and therefore lack live-read evidence.
- `DATA_SEARCH_CANDIDATE_MANIFEST` is an internal verification projection, not
  a production tile or activation path.

The requested `/tmp/opencode/ovid-provider-review/batch-d.md` covers the
commerce/infrastructure batch, not these candidates. The matching official
research is in `batch-c.md`, with DocuSign/Typeform/Calendly in `batch-b.md`.
Those first-party findings were used and current official pages were checked
directly where available. Documentation review is not live evidence.

## Candidate matrix

| Candidate | Definition and official read | Credential / bound | Live evidence | Release |
|---|---|---|---|---|
| `docusign` | **Blocked, absent.** Requires OAuth/UserInfo account/base-URI discovery and rotating-token lifecycle; no pasted-token or hardcoded-demo substitute. | eSignature v2.1; no descriptor. | Not run; definition blocked. | **Blocked** |
| `typeform` | `list_forms`: `GET https://api.typeform.com/forms`, US forms metadata. | Bearer `forms:read`; page 1–100, page size 1–50. | **Not provided:** `OVID_LIVE_TYPEFORM_ACCESS_TOKEN`. | **Blocked** |
| `calendly` | `get_current_user`: `GET https://api.calendly.com/users/me`; returns actual user metadata, not a token ping. | Scoped OAuth/PAT `users:read`; one resource read, email discarded. | **Not provided:** `OVID_LIVE_CALENDLY_ACCESS_TOKEN`. | **Blocked** |
| `miro` | `list_boards`: `GET https://api.miro.com/v2/boards`. | OAuth `boards:read`; limit 1–50, offset 0–9950. | **Not provided:** `OVID_LIVE_MIRO_ACCESS_TOKEN`. | **Blocked** |
| `canva` | `list_designs`: `GET https://api.canva.com/rest/v1/designs`. | OAuth `design:meta:read`; limit 1–100; temporary view/edit/thumbnail URLs discarded. | **Not provided:** `OVID_LIVE_CANVA_ACCESS_TOKEN`. | **Blocked** |
| `webflow` | `list_sites`: `GET https://api.webflow.com/v2/sites`. | Bearer `sites:read`; endpoint has no page args, so the response is capped and projection reports total/truncated. | **Not provided:** `OVID_LIVE_WEBFLOW_ACCESS_TOKEN`. | **Blocked** |
| `snowflake` | **Blocked, absent.** Needs single-statement SQL/bind/partition and warehouse-cost handler, per-user OAuth/JWT, and read-only role enforcement. No fake `SELECT 1` health operation. | SQL API v2; arbitrary SQL/job passthrough denied. | Not run; definition blocked. | **Blocked** |
| `bigquery` | `list_datasets`: `GET https://bigquery.googleapis.com/bigquery/v2/projects/{project_id}/datasets`. Metadata only, no SQL/jobs. | OAuth `bigquery.readonly`; authenticated project ID validated; maxResults 1–50. | **Not provided:** `OVID_LIVE_BIGQUERY_ACCESS_TOKEN`, `OVID_LIVE_BIGQUERY_PROJECT_ID`. | **Blocked** |
| `databricks` | **Blocked, absent.** Needs OAuth/SQL policy, chunk/external-link handling, warehouse-cost controls, and restricted workspace origin. | Statement Execution 2.0; no statement passthrough. | Not run; definition blocked. | **Blocked** |
| `pinecone` | `list_indexes`: `GET https://api.pinecone.io/indexes`, API `2026-07`. Control plane only; returned index hosts are never contacted. | Dedicated serverless-project `ControlPlaneViewer` key; Starter/Builder `All` keys and pod RBAC models are not accepted. Response/projection capped. | **Not provided:** `OVID_LIVE_PINECONE_API_KEY`. | **Blocked** |
| `elasticsearch` | **Blocked, absent.** Needs deployment-pinned origin and PIT-aware scoped-key handler limited to named indices. | No arbitrary cluster host, search body, or admin key. | Not run; definition blocked. | **Blocked** |
| `typesense` | **Blocked, absent.** Needs restricted origin and collection-scoped HMAC key handler with enforced tenant filters. | No admin key or arbitrary cluster host. | Not run; definition blocked. | **Blocked** |
| `brave-search` | `web_search`: `GET https://api.search.brave.com/res/v1/web/search`. [Official query constraints](https://api-dashboard.search.brave.com/api-reference/web/search/get): at most 600 characters **and independently 75 words**, validated before config/egress. | Dedicated web-search key; count 1–20, offset 0–2, web-only fixed filters. Quota may be consumed; no no-cost claim. | **Not provided:** `OVID_LIVE_BRAVE_SEARCH_API_KEY`. | **Blocked** |
| `tavily` | `search`: `POST https://api.tavily.com/search` (read-only search compute). | Dedicated Bearer key; fixed `basic` depth (documented 1 credit), one chunk/source, 1–10 results; no advanced search, answers, images, or raw content. | **Not provided:** `OVID_LIVE_TAVILY_API_KEY`. | **Blocked** |
| `serpapi` | **Blocked, absent.** Private key is required in the query string and engine-specific archive/redaction is not implemented. | **Replacement:** use `brave-search` or `tavily` for web search. | Not run; definition blocked. | **Blocked** |
| `algolia` | **Blocked, absent.** Needs secured-key derivation, dual-auth headers, fallback hosts, `restrictIndices`, and tenant filters. | No Admin key or generic search POST. | Not run; definition blocked. | **Blocked** |
| `google-maps` | `search_places`: `POST https://places.googleapis.com/v1/places:searchText`, Places API (New) only. | Places-only restricted key; fixed `places.id,nextPageToken` Essentials ID Only mask; pageSize 1–20. Each page may be billable. | **Not provided:** `OVID_LIVE_GOOGLE_MAPS_API_KEY`. | **Blocked** |
| `mixpanel` | `get_saved_insight`: `GET https://mixpanel.com/api/query/insights` for configured project/bookmark IDs. US only; no JQL or arbitrary filters. | Project-scoped Consumer service account Basic auth; response projection caps 10 series and 31 dates/series. Official Query API budget is 60 queries/hour and 5 concurrent. | **Not provided:** username, secret, project ID, bookmark ID env vars below. | **Blocked** |
| `amplitude` | `list_charts`: `GET https://developer-api.amplitude.com/v1/projects/{project_id}/charts`, US Developer API. | PAT/OAuth `analytics:read` bound to US; numeric project ID validated; limit 1–50; fixed sort. | **Not provided:** `OVID_LIVE_AMPLITUDE_ACCESS_TOKEN`, `OVID_LIVE_AMPLITUDE_PROJECT_ID`. | **Blocked** |
| `posthog` | `list_insights`: `GET https://us.posthog.com/api/projects/{project_id}/insights/`, US Cloud. | Project-scoped personal key `insight:read`; numeric project ID validated; limit 1–50, offset 0–1000, `basic=true`, `refresh=force_cache`. | **Not provided:** `OVID_LIVE_POSTHOG_PERSONAL_API_KEY`, `OVID_LIVE_POSTHOG_PROJECT_ID`. | **Blocked** |
| `segment` | `list_sources`: `GET https://api.segmentapis.com/sources`, US Public API. | Business-plan workspace token with Source read-only; count 1–25. Write keys/settings are discarded. Team plans without a read-only role are not accepted. | **Not provided:** `OVID_LIVE_SEGMENT_ACCESS_TOKEN`. | **Blocked** |
| `metabase` | **Blocked, absent.** Needs versioned Agent semantic-query/session handler and tenant origin; native SQL stays off. | No group-wide key, `/api/dataset`, or `execute-sql` passthrough. | Not run; definition blocked. | **Blocked** |
| `redash` | **Blocked, absent.** Needs version-specific cached-result/Query API key handler and tenant origin; official API list is explicitly incomplete. | No fresh query execution or arbitrary SQL. | Not run; definition blocked. | **Blocked** |
| `superset` | **Blocked, absent.** Needs stable-version JWT/Rison/RBAC handler and reviewed tenant origin. | No SQL Lab, arbitrary query, or password-login passthrough. | Not run; definition blocked. | **Blocked** |
| `stripe` | `list_products`: `GET https://api.stripe.com/v1/products`, with static `Stripe-Version: 2026-09-30.endive` per the [official versioning reference](https://docs.stripe.com/api/versioning) current on 2026-10-24. Product metadata only. | Restricted key with **Products: Read** and everything else None; limit 1–100. No payment, charge, refund, payout, subscription, or other financial write exists. | **Not provided:** `OVID_LIVE_STRIPE_RESTRICTED_KEY`. | **Blocked** |
| `paypal` | **Blocked, absent.** Client-credentials token lifecycle has no granular read-only scope and is merchant/server-app auth, not per-buyer auth. | No shared-secret token cache or payment operation. | Not run; definition blocked. | **Blocked** |

## Request and response boundaries

- Every supported descriptor has a fixed HTTPS origin. No model argument can
  supply `baseUrl`, `host`, `url`, headers, proxy settings, SQL, GraphQL, a job,
  webhook, or arbitrary body. Invalid operation args fail before connection
  resolution.
- BigQuery, Amplitude, PostHog, and Mixpanel tenant identifiers come only from
  authenticated connection configuration and are syntax-validated before any
  fetch. Other tenancy is fixed by the per-user credential/region.
- POST is used only for documented read/search compute (Tavily and Places).
  Bodies are server-owned typed fields and constants. Every operation is
  `effect:"read"`, `approval:"mode"`; no high-risk/write operation is exported.
- Raw responses are capped at 65,536 bytes. Provider JSON is projected to an
  allowlisted shape and secret-redacted; the existing engine then enforces the
  8,192-byte final tool-result cap. Oversized projections fail closed rather
  than being silently truncated.
- Pagination is one explicit page per call; no arbitrary `next` URL is followed.
  BigQuery/Places `nextPageToken` is projected as `next_cursor` before the
  existing `*Token` redactor runs, preserving a usable opaque cursor without
  weakening credential redaction.
- Canva temporary URLs, PostHog queries/user details, Segment write keys,
  Amplitude chart definitions, and catalog metadata not needed by the selected
  read are discarded.

## Contract commands and actual outcomes

```bash
cd /root/OvidBackend/cloud/packages/mcp
./node_modules/.bin/vitest run \
  src/rest/descriptors/dataSearch.test.ts \
  test/providers/dataSearch.contract.test.ts
```

- RED before implementation: exit **1**, two failed suites/zero collected tests
  because `dataSearch.js` did not exist. Evidence:
  `/tmp/opencode/ovid-production-completion/connectors-task-9-data-search/red-contract.{log,exit}`.
- Additional REDs proved pagination-cursor projection, large-page handling, and rejection of lookalike descriptors with non-canonical origins.
- GREEN after implementation: exit **0**, **80/80 tests passed** across two
  files. Evidence:
  `/tmp/opencode/ovid-production-completion/connectors-task-9-data-search/green-contract.{log,exit}`.
- The per-candidate tests cover all 26 rows. They include official
  operation/version/auth, typed requests, sanitized responses, per-user secret
  isolation, fixed origins, closed inputs, page/cost bounds, block reasons, and
  production-catalog exclusion.

Scoped typecheck (exit **0**):

```bash
./node_modules/.bin/tsc --noEmit --strict --target ES2022 --module ESNext \
  --moduleResolution Bundler --skipLibCheck --types node,vitest \
  src/rest/descriptors/dataSearch.ts \
  src/rest/descriptors/dataSearch.test.ts \
  test/providers/dataSearch.live.test.ts
```

## Explicit live-read harness

Ordinary CI does not claim live evidence. With
`OVID_LIVE_PROVIDER_TESTS=1`, every contract candidate has its own mandatory
per-provider opt-in and credential check. Missing values fail the test; there
are no skipped passes. Actual configured reads use production DNS-pinned
`ProviderEgress`, never raw `fetch`, and print only the sanitized projection.

```bash
cd /root/OvidBackend/cloud/packages/mcp
for id in TYPEFORM CALENDLY MIRO CANVA WEBFLOW PINECONE BIGQUERY \
  BRAVE_SEARCH TAVILY GOOGLE_MAPS MIXPANEL AMPLITUDE POSTHOG SEGMENT STRIPE; do
  export "OVID_LIVE_PROVIDER_${id}=1"
done
OVID_LIVE_PROVIDER_TESTS=1 \
  ./node_modules/.bin/vitest run test/providers/dataSearch.live.test.ts
```

Credential names (values must come from dedicated least-privilege test
accounts, never source or logs):

| Provider | Required environment |
|---|---|
| Typeform | `OVID_LIVE_TYPEFORM_ACCESS_TOKEN` |
| Calendly | `OVID_LIVE_CALENDLY_ACCESS_TOKEN` |
| Miro | `OVID_LIVE_MIRO_ACCESS_TOKEN` |
| Canva | `OVID_LIVE_CANVA_ACCESS_TOKEN` |
| Webflow | `OVID_LIVE_WEBFLOW_ACCESS_TOKEN` |
| Pinecone | `OVID_LIVE_PINECONE_API_KEY` |
| BigQuery | `OVID_LIVE_BIGQUERY_ACCESS_TOKEN`, `OVID_LIVE_BIGQUERY_PROJECT_ID` |
| Brave Search | `OVID_LIVE_BRAVE_SEARCH_API_KEY` |
| Tavily | `OVID_LIVE_TAVILY_API_KEY` |
| Google Maps | `OVID_LIVE_GOOGLE_MAPS_API_KEY` |
| Mixpanel | `OVID_LIVE_MIXPANEL_USERNAME`, `OVID_LIVE_MIXPANEL_SECRET`, `OVID_LIVE_MIXPANEL_PROJECT_ID`, `OVID_LIVE_MIXPANEL_BOOKMARK_ID` |
| Amplitude | `OVID_LIVE_AMPLITUDE_ACCESS_TOKEN`, `OVID_LIVE_AMPLITUDE_PROJECT_ID` |
| PostHog | `OVID_LIVE_POSTHOG_PERSONAL_API_KEY`, `OVID_LIVE_POSTHOG_PROJECT_ID` |
| Segment | `OVID_LIVE_SEGMENT_ACCESS_TOKEN` |
| Stripe | `OVID_LIVE_STRIPE_RESTRICTED_KEY` |

Actual outcome on 2026-10-24: exit **1**, **15/15 live tests failed** with
`credentials not provided` after every per-provider read gate was explicitly
enabled. No credential values were present and no provider network call was
made. Evidence:
`/tmp/opencode/ovid-production-completion/connectors-task-9-data-search/live-credentials-blocked.{log,exit}`.
A preceding run with no per-row opt-ins also failed 15/15, as required:
`live-blocked.{log,exit}`.

## Writes and cleanup

There are **no advertised writes** and no write tests.
`OVID_LIVE_PROVIDER_WRITE_TESTS=1` was not used. Consequently there is no
write claim, disposable resource, per-action write approval, cleanup proof, or
sanitized write result. Financial products are read-only; query jobs,
deployment actions, payment actions, and paid mutation flows are absent.

## Fix round 1 — official contract corrections

Independent review `task-9-review-round-1.md` identified two Important
findings. Both were fixed with real RED then GREEN evidence under
`/tmp/opencode/ovid-production-completion/connectors-task-9-data-search/fix-round-1/`.

1. **Brave independent word bound.** The official
   [Web Search query documentation](https://api-dashboard.search.brave.com/api-reference/web/search/get)
   limits `q` to 600 characters **and** 75 words. The descriptor schema enforces
   the character bound and a provider-specific pre-handler enforces the word
   bound before credential resolution or egress. Boundary fixtures prove 75
   words accepted, 76 rejected, 600 characters accepted, 601 rejected, and
   leading/trailing/repeated tab/newline whitespace counted without creating
   words.
2. **Stripe dated API contract.** Batch C requires a version pin. The official
   [versioning reference](https://docs.stripe.com/api/versioning), checked on
   2026-10-24, identifies `2026-09-30.endive` as current. Every Stripe request
   now carries exactly `Stripe-Version: 2026-09-30.endive`; descriptor,
   official-docs, and actual outbound-header fixtures assert this value so a
   tenant account default cannot silently change response contracts.

The focused contract command now passes **87/87** tests. RED before the fixes
was **82 passed, 5 failed** (two Brave 76-word cases, Stripe descriptor/docs,
Stripe outbound header, and the concurrently removed candidate-only manifest
export). Task 9's candidate-only export was restored without adding candidates
to production definitions. Scoped typecheck is clean. All candidate/blocked
rows, no-write behavior, and live credential blockers remain unchanged.

## Remaining concerns

1. No row may be promoted until its real read passes with the documented
   least-privilege test account and the sanitized result is recorded.
2. OAuth-using candidates currently define the data-plane read only. App
   registration, authorization, refresh/rotation, revoke, and disconnect
   lifecycle evidence must be supplied by the common OAuth lifecycle owner;
   this batch does not claim it.
3. Regional profiles are deliberately narrow: Typeform US, Mixpanel US,
   Amplitude US, PostHog US, Segment US, and Places New only. Other regions are
   not silently routed to these origins.
4. Brave, Tavily, and Places calls can consume quota or bill even though they
   are reads. The harness uses one result where supported and must run only
   against approved test accounts.
