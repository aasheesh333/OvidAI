# Connector Task 9 — documents, data, search, and finance

Review and implementation date: **2026-10-24**. Base requested by the brief:
`9d1f22bd425a3c950487079e45eed02cd112235d`.

## Status semantics

- **Contract candidate** means the official read, credential profile, fixed or
  validated tenant origin, closed input, bounded request, and sanitized response
  have automated contract evidence. It does **not** mean production readiness.
- **Release blocked** means the row is absent from `CURATED_IDS`,
  `CURATED_DESCRIPTORS`, and the production `CURATED_MANIFEST`.
- All 26 rows are currently **release blocked**. Twenty-five have executable
  contract candidates and declared operations; Redash remains descriptor-absent
  pending its version-specific contract. All 26 additionally lack live
  credentials and therefore lack live-read evidence.
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
| `docusign` | `list_envelopes`: `GET {discovered-base}/restapi/v2.1/accounts/{account_id}/envelopes`; fresh UserInfo discovery per call and exact account binding. | OAuth `signature`; count 1–100, bounded start position; no recipients/documents/sends. | **Not provided:** `OVID_LIVE_DOCUSIGN_ACCESS_TOKEN`, `OVID_LIVE_DOCUSIGN_ACCOUNT_ID`. | **Blocked** |
| `typeform` | `list_forms`: `GET https://api.typeform.com/forms`, US forms metadata. | Bearer `forms:read`; page 1–100, page size 1–50. | **Not provided:** `OVID_LIVE_TYPEFORM_ACCESS_TOKEN`. | **Blocked** |
| `calendly` | `get_current_user`: `GET https://api.calendly.com/users/me`; returns actual user metadata, not a token ping. | Scoped OAuth/PAT `users:read`; one resource read, email discarded. | **Not provided:** `OVID_LIVE_CALENDLY_ACCESS_TOKEN`. | **Blocked** |
| `miro` | `list_boards`: `GET https://api.miro.com/v2/boards`. | OAuth `boards:read`; limit 1–50, offset 0–9950. | **Not provided:** `OVID_LIVE_MIRO_ACCESS_TOKEN`. | **Blocked** |
| `canva` | `list_designs`: `GET https://api.canva.com/rest/v1/designs`. | OAuth `design:meta:read`; limit 1–100; temporary view/edit/thumbnail URLs discarded. | **Not provided:** `OVID_LIVE_CANVA_ACCESS_TOKEN`. | **Blocked** |
| `webflow` | `list_sites`: `GET https://api.webflow.com/v2/sites`. | Bearer `sites:read`; endpoint has no page args, so the response is capped and projection reports total/truncated. | **Not provided:** `OVID_LIVE_WEBFLOW_ACCESS_TOKEN`. | **Blocked** |
| `snowflake` | `list_databases`: `GET {account_url}/api/v2/databases`, REST metadata only; no SQL statement or warehouse compute. | OAuth with database USAGE and OAUTH token-type header; showLimit 1–50, history false, validated account origin. | **Not provided:** `OVID_LIVE_SNOWFLAKE_ACCESS_TOKEN`, `OVID_LIVE_SNOWFLAKE_ACCOUNT_URL`. | **Blocked** |
| `bigquery` | `list_datasets`: `GET https://bigquery.googleapis.com/bigquery/v2/projects/{project_id}/datasets`. Metadata only, no SQL/jobs. | OAuth `bigquery.readonly`; authenticated project ID validated; maxResults 1–50. | **Not provided:** `OVID_LIVE_BIGQUERY_ACCESS_TOKEN`, `OVID_LIVE_BIGQUERY_PROJECT_ID`. | **Blocked** |
| `databricks` | `list_warehouses`: `GET {workspace_url}/api/2.0/sql/warehouses`; metadata only, no statement execution or warehouse controls. | Scoped PAT uses `sql`; U2M instead requires `all-apis offline_access` plus separately verified warehouse-only workspace permissions. Page size 1–50, validated workspace origin. [PAT](https://docs.databricks.com/aws/en/dev-tools/auth/pat) and [U2M](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m) references are distinct, not one invented scope. | **Not provided:** `OVID_LIVE_DATABRICKS_ACCESS_TOKEN`, `OVID_LIVE_DATABRICKS_WORKSPACE_URL`. | **Blocked** |
| `pinecone` | `list_indexes`: `GET https://api.pinecone.io/indexes`, API `2026-07`. Control plane only; returned index hosts are never contacted. | Dedicated serverless-project `ControlPlaneViewer` key; Starter/Builder `All` keys and pod RBAC models are not accepted. Response/projection capped. | **Not provided:** `OVID_LIVE_PINECONE_API_KEY`. | **Blocked** |
| `elasticsearch` | `get_document`: `GET {instance_url}/{index}/_doc/{document_id}` from one configured named index; no search/PIT/job/write endpoints. | Expiring read-only ApiKey limited to named index; bounded 20 primitive `_source` fields, tenant origin and path traversal validation. | **Not provided:** API key, instance URL, index, document ID env vars below. | **Blocked** |
| `typesense` | `get_collection`: `GET {instance_url}/collections/{collection}` for one configured collection schema; no search or writes. | `collections:get` scoped key only; 50-field cap and strict tenant origin. | **Not provided:** API key, instance URL, collection env vars below. | **Blocked** |
| `brave-search` | `web_search`: `GET https://api.search.brave.com/res/v1/web/search`. [Official query constraints](https://api-dashboard.search.brave.com/api-reference/web/search/get): at most 600 characters **and independently 75 words**, validated before config/egress. | Dedicated web-search key; count 1–20, offset 0–2, web-only fixed filters. Quota may be consumed; no no-cost claim. | **Not provided:** `OVID_LIVE_BRAVE_SEARCH_API_KEY`. | **Blocked** |
| `tavily` | `search`: `POST https://api.tavily.com/search` (read-only search compute). | Dedicated Bearer key; fixed `basic` depth (documented 1 credit), one chunk/source, 1–10 results; no advanced search, answers, images, or raw content. | **Not provided:** `OVID_LIVE_TAVILY_API_KEY`. | **Blocked** |
| `serpapi` | `get_archived_search`: `GET https://serpapi.com/searches/{search_id}.json`; existing archive only, no fresh search or quota-consuming query. | Separate **full account key**, not a vendor archive-scoped credential. The connector's archive-only endpoint allowlist is the boundary. Required query-string auth remains in memory, is redacted in all output/errors, and never appears in the sanitized result. Ten organic results max. | **Not provided:** `OVID_LIVE_SERPAPI_API_KEY`, `OVID_LIVE_SERPAPI_SEARCH_ID`. | **Blocked** |
| `algolia` | `get_object`: `GET https://{app_id}-dsn.algolia.net/1/indexes/{index_name}/{object_id}` with both official headers. | Secured search-only key restricted to configured index; 20 primitive fields, no Admin key, no fallback-host credential replay. | **Not provided:** API key, app ID, index name, object ID env vars below. | **Blocked** |
| `google-maps` | `search_places`: `POST https://places.googleapis.com/v1/places:searchText`, Places API (New) only. | Places-only restricted key; fixed `places.id,nextPageToken` Essentials ID Only mask; pageSize 1–20. Each page may be billable. | **Not provided:** `OVID_LIVE_GOOGLE_MAPS_API_KEY`. | **Blocked** |
| `mixpanel` | `get_saved_insight`: `GET https://mixpanel.com/api/query/insights` for configured project/bookmark IDs. US only; no JQL or arbitrary filters. | Project-scoped Consumer service account Basic auth; response projection caps 10 series and 31 dates/series. Official Query API budget is 60 queries/hour and 5 concurrent. | **Not provided:** username, secret, project ID, bookmark ID env vars below. | **Blocked** |
| `amplitude` | `list_charts`: `GET https://developer-api.amplitude.com/v1/projects/{project_id}/charts`, US Developer API. | PAT/OAuth `analytics:read` bound to US; numeric project ID validated; limit 1–50; fixed sort. | **Not provided:** `OVID_LIVE_AMPLITUDE_ACCESS_TOKEN`, `OVID_LIVE_AMPLITUDE_PROJECT_ID`. | **Blocked** |
| `posthog` | `list_insights`: `GET https://us.posthog.com/api/projects/{project_id}/insights/`, US Cloud. | Project-scoped personal key `insight:read`; numeric project ID validated; limit 1–50, offset 0–1000, `basic=true`, `refresh=force_cache`. | **Not provided:** `OVID_LIVE_POSTHOG_PERSONAL_API_KEY`, `OVID_LIVE_POSTHOG_PROJECT_ID`. | **Blocked** |
| `segment` | `list_sources`: `GET https://api.segmentapis.com/sources`, US Public API. | Business-plan workspace token with Source read-only; count 1–25. Write keys/settings are discarded. Team plans without a read-only role are not accepted. | **Not provided:** `OVID_LIVE_SEGMENT_ACCESS_TOKEN`. | **Blocked** |
| `metabase` | `search_semantic_resources`: `POST {instance_url}/api/agent/v1/search` with one typed term query; no semantic execution or SQL. | Fresh user JWT (iat under 180s) and view-only user; 25-result projection, strict tenant origin. Auth is pinned by the [Agent API authentication reference](https://github.com/metabase/metabase/blob/master/src/metabase/agent_api/reference.md#authentication), not the API-key/header model. | **Not provided:** `OVID_LIVE_METABASE_JWT`, `OVID_LIVE_METABASE_INSTANCE_URL`. | **Blocked** |
| `redash` | **Blocked, descriptor absent.** The public endpoint list is explicitly incomplete V9-era material. A current complete version-specific cached-result API/auth contract and deployed-version compatibility review are still required. | No callable operation or admitted credential profile. Reserved ID retained; no fresh SQL, parameters, jobs, or query execution. | **Not provided + version blocker:** API key, instance URL, query ID not provided; deployment compatibility not proven. | **Blocked** |
| `superset` | `list_dashboards`: `GET {instance_url}/api/v1/dashboard/` on reviewed 6.1.0 contract with server-built Rison columns/page query. | User JWT/restricted API key with Gamma + dashboard-only RBAC; page 0–100, page size 1–25, both `ids` and `result` projections capped at 25 with truncation flags, no SQL Lab or arbitrary filters. | **Not provided:** `OVID_LIVE_SUPERSET_ACCESS_TOKEN`, `OVID_LIVE_SUPERSET_INSTANCE_URL`. | **Blocked** |
| `stripe` | `list_products`: `GET https://api.stripe.com/v1/products`, with static `Stripe-Version: 2026-09-30.endive` per the [official versioning reference](https://docs.stripe.com/api/versioning) current on 2026-10-24. Product metadata only. | Restricted key with **Products: Read** and everything else None; limit 1–100. No payment, charge, refund, payout, subscription, or other financial write exists. | **Not provided:** `OVID_LIVE_STRIPE_RESTRICTED_KEY`. | **Blocked** |
| `paypal` | `get_order`: `GET https://api-m.paypal.com/v2/checkout/orders/{order_id}` after request-scoped client-credentials exchange; Orders v2 only. | Dedicated per-connection merchant app credentials, never a shared token cache. The token is **not intrinsically read-only**; least privilege is app/product entitlement plus this connector's GET-only allowlist. Ten purchase units, amount/status only; no capture/refund/payout/transfer/invoice actions. | **Not provided:** `OVID_LIVE_PAYPAL_CLIENT_ID`, `OVID_LIVE_PAYPAL_CLIENT_SECRET`, `OVID_LIVE_PAYPAL_ORDER_ID`. | **Blocked** |

## Request and response boundaries

- Every descriptor has either a fixed official HTTPS origin or an authenticated
  tenant binding validated by the provider-specific handler. No model argument
  can supply `baseUrl`, `host`, `url`, headers, proxy settings, SQL, GraphQL, a
  job, webhook, or arbitrary body. Invalid operation args fail before connection
  resolution.
- BigQuery, Amplitude, PostHog, Mixpanel, and all new dynamic-tenant identifiers
  come only from authenticated connection configuration and are validated before
  any fetch. Dynamic tenants create one fresh production DNS-pinned
  `ProviderEgress` for the reviewed origin and close it after the call; no
  credential or token is cached across calls. DocuSign additionally validates
  the discovered base URI and exact account from UserInfo, and PayPal performs a
  request-scoped token exchange on the same fixed origin.
- POST is used only for documented read/search compute (Tavily, Places, and
  Metabase semantic discovery) or the request-scoped PayPal OAuth exchange.
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
  src/rest/descriptors/dataSearchGap.test.ts \
  test/providers/dataSearch.contract.test.ts
```

- RED before implementation: exit **1**, two failed suites/zero collected tests
  because `dataSearch.js` did not exist. Evidence:
  `/tmp/opencode/ovid-production-completion/connectors-task-9-data-search/red-contract.{log,exit}`.
- Additional REDs proved pagination-cursor projection, large-page handling, and rejection of lookalike descriptors with non-canonical origins.
- GREEN after implementation: exit **0**, **80/80 tests passed** across two
  files. Evidence:
  `/tmp/opencode/ovid-production-completion/connectors-task-9-data-search/green-contract.{log,exit}`.
- At the completed pre-drift contract run, **122/122** tests passed across three
  files. A later pre-pause descriptor-only run passed **84/84** tests after the
  final input-gate fixtures were added. They cover all 26 rows with official
  operation/version/auth, typed requests, sanitized responses, per-user secret
  isolation, fixed/validated origins, closed inputs, page/cost bounds,
  path-traversal denial, and production-catalog exclusion. The descriptor-gap
  RED was 75 passed/47 failed; evidence is under
  `/tmp/opencode/ovid-production-completion/connectors-task-9-descriptor-gap-fix/`.
  These are historical results, not verification of edits made after the pause.

Scoped typecheck (exit **0**):

```bash
./node_modules/.bin/tsc --noEmit --strict --target ES2022 --module ESNext \
  --moduleResolution Bundler --skipLibCheck --types node,vitest \
  src/rest/descriptors/dataSearch.ts \
  src/rest/descriptors/dataSearch.test.ts \
  src/rest/descriptors/dataSearchGap.test.ts \
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
  BRAVE_SEARCH TAVILY GOOGLE_MAPS MIXPANEL AMPLITUDE POSTHOG SEGMENT STRIPE \
  DOCUSIGN SNOWFLAKE DATABRICKS ELASTICSEARCH TYPESENSE SERPAPI ALGOLIA \
  METABASE REDASH SUPERSET PAYPAL; do
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
| DocuSign | `OVID_LIVE_DOCUSIGN_ACCESS_TOKEN`, `OVID_LIVE_DOCUSIGN_ACCOUNT_ID` |
| Snowflake | `OVID_LIVE_SNOWFLAKE_ACCESS_TOKEN`, `OVID_LIVE_SNOWFLAKE_ACCOUNT_URL` |
| Databricks | `OVID_LIVE_DATABRICKS_ACCESS_TOKEN`, `OVID_LIVE_DATABRICKS_WORKSPACE_URL` |
| Elasticsearch | `OVID_LIVE_ELASTICSEARCH_API_KEY`, `OVID_LIVE_ELASTICSEARCH_INSTANCE_URL`, `OVID_LIVE_ELASTICSEARCH_INDEX`, `OVID_LIVE_ELASTICSEARCH_DOCUMENT_ID` |
| Typesense | `OVID_LIVE_TYPESENSE_API_KEY`, `OVID_LIVE_TYPESENSE_INSTANCE_URL`, `OVID_LIVE_TYPESENSE_COLLECTION` |
| SerpApi | `OVID_LIVE_SERPAPI_API_KEY`, `OVID_LIVE_SERPAPI_SEARCH_ID` |
| Algolia | `OVID_LIVE_ALGOLIA_API_KEY`, `OVID_LIVE_ALGOLIA_APP_ID`, `OVID_LIVE_ALGOLIA_INDEX_NAME`, `OVID_LIVE_ALGOLIA_OBJECT_ID` |
| Metabase | `OVID_LIVE_METABASE_JWT`, `OVID_LIVE_METABASE_INSTANCE_URL` |
| Redash | `OVID_LIVE_REDASH_API_KEY`, `OVID_LIVE_REDASH_INSTANCE_URL`, `OVID_LIVE_REDASH_QUERY_ID` |
| Superset | `OVID_LIVE_SUPERSET_ACCESS_TOKEN`, `OVID_LIVE_SUPERSET_INSTANCE_URL` |
| PayPal | `OVID_LIVE_PAYPAL_CLIENT_ID`, `OVID_LIVE_PAYPAL_CLIENT_SECRET`, `OVID_LIVE_PAYPAL_ORDER_ID` |

Current outcome after the descriptor-gap fix: exit **1**, **26/26 live tests
failed** with `credentials not provided` after every per-provider read gate was
explicitly enabled and all credential variables were explicitly unset. No
credential values were present, no `ProviderEgress` was constructed, and no
provider network call was made. Evidence:
`/tmp/opencode/ovid-production-completion/connectors-task-9-descriptor-gap-fix/live-credentials-blocked.{log,exit}`.
The earlier 15-row missing-opt-in and missing-credential runs remain in the
previous evidence directory and were not converted into passes.

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

## Descriptor-gap closure and verification pause

Ten formerly descriptor-absent candidates now have a declared narrow read and a
live-harness row: DocuSign envelopes, Snowflake databases, Databricks SQL
warehouses, one Elasticsearch document, one Typesense collection, one archived
SerpApi search, one Algolia object, Metabase semantic resources, Superset
dashboards, and one PayPal order. No replacement IDs were needed; all 26
original IDs remain reserved in the inventory. Redash is the sole
`DATA_SEARCH_BLOCKED` row because its current complete version-specific
cached-result contract and deployed-version compatibility remain unproven.

The 11-resolution matrix and evidence are recorded at
`/tmp/opencode/ovid-production-completion/connectors-task-9-descriptor-gap-fix/report.md`.
No SQL/GraphQL/arbitrary body/job/webhook/query passthrough, generic ping,
financial/deployment write, or unsupported promotion was added. Dynamic tenant
origins use fresh pinned egress per call and close it afterward. PayPal tokens
are request-scoped and never cached; SerpApi query-string credentials never
enter the sanitized result.

**Pause state (2026-10-25):** `HEAVY-COMMANDS-PAUSED.md` is in force. No tests,
analysis commands, builds, typechecks, heavy commands, or provider calls were
run after it took effect. The 122/122, 84/84, full-suite, and typecheck results
above are historical evidence from their pre-pause logs only; later source or
documentation edits are not newly verified or claimed green. All 26 candidates
remain live-blocked pending credentials and real reads.

## Static review FIX ROUND 1 — regressions UNEXECUTED

The failed static review at
`/tmp/opencode/ovid-production-completion/connectors-task-9-descriptor-gap-fix/review-round-1.md`
was addressed without running tests, analysis commands, builds, typechecks,
network, or heavy commands. New regressions are **UNEXECUTED** under the pause.

| Provider | Static resolution and remaining blocker |
|---|---|
| `docusign` | Required nonblank `from_date`, full timeout/authorization/cancellation preflight now precede config/UserInfo discovery. Caller abort is linked to auxiliary discovery and rechecked after config. SPEC behavior retained; OAuth lifecycle still unproved. |
| `snowflake` | Unchanged static pass: REST metadata only, database USAGE, strict account origin, one bounded page, no SQL/job path. Still credential/live blocked. |
| `databricks` | Scoped-PAT and U2M profiles no longer share an invented scope: PAT `sql`; U2M `all-apis offline_access` plus separately verified warehouse-only workspace permissions. PAT and U2M official references are both cited. |
| `elasticsearch` | Blank `document_id` now fails before config/egress; pre-cancelled calls do no work. Named-index read and live compatibility remain unproved. |
| `typesense` | Unchanged static pass: collection-scoped `collections:get`, strict origin, 50-field projection. Still credential/live blocked. |
| `serpapi` | Static pass with corrected wording: the key is a separate **full account key**, not vendor archive-scoped; the connector archive endpoint allowlist is the boundary. Redaction and no-fresh-search behavior retained. |
| `algolia` | Blank `object_id` now fails before config/egress; pre-cancelled calls do no work. Search-only/index-restricted ACL remains live setup evidence. |
| `metabase` | Blank term now fails before config/egress; pre-cancelled calls do no work. Auth now cites the Agent API Authentication section directly, not the API-key model. Fresh `iat` and view-only RBAC remain setup/live requirements. |
| `redash` | **Descriptor removed and `DATA_SEARCH_BLOCKED` restored.** The incomplete V9-era reference cannot prove a current complete cached-result contract; deployed-version compatibility is unresolved. No callable descriptor or promotion. |
| `superset` | `ids` and `result` each cap at 25 and set truncation flags. SPEC behavior retained; actual tenant version/RBAC remain live checks. |
| `paypal` | Blank `order_id` and pre-cancelled calls cannot trigger token exchange; cancellation is rechecked after config and linked to the auxiliary request. Token is documented as not intrinsically read-only; app/product entitlement plus GET-only allowlist is the boundary. |

**UNEXECUTED regressions authored:** `dataSearchGap.test.ts` adds blank required
ID/term cases for Elasticsearch, Algolia, Metabase, PayPal, and DocuSign;
pre-cancelled calls for all five; cancellation-during-config cases for DocuSign
and PayPal; in-flight abort cases proving DocuSign creates no second tenant
egress and PayPal performs no order read; and a 40-ID/40-dashboard Superset
projection proving both lists cap at 25. `dataSearch.contract.test.ts` adds exact Databricks scope/PAT/U2M docs,
SerpApi full-key boundary, PayPal entitlement/GET allowlist, and Metabase JWT
citation checks. None was run after the pause, and no new green claim is made.

## Static FIX ROUND 2 — C1 scope correction, regressions UNEXECUTED

`authorizationContext` is now constructed once in the surrounding `callTool`
scope, before preflight and execution blocks, correcting round-2 C1's lexical
scope defect. No side effect was moved earlier: argument validation, required
nonblank strings, timeout parsing, authorization, and cancellation still run
before config resolution, discovery, token exchange, or auxiliary auth. The same
context drives all post-config/post-discovery cancellation fences.

UNEXECUTED table-driven regressions now cover every dynamic candidate's valid
call chain and all ten pre-cancelled/invalid-argument no-auth paths. They remain
unexecuted under the heavy-command pause, with no new green or readiness claim.
All round-1 fixes, 25 typed candidates, descriptor-absent Redash, and all 26
live-credential blockers remain unchanged.

## Static FIX ROUNDS 3–4 — operation conversion, regressions UNEXECUTED

The preflight uses the typed `dataSearchProviderOperation(descriptor, published)`
conversion helper before schema/required-string validation and authorization.
Only actual `PublishedRestToolDef` fields are consumed: name,
description/fallback, effect, approval, requiredScopes, inputSchema,
outputPolicy, request, and limits. The non-existent `custom` access was removed;
there is no custom behavior to preserve. No cast, suppression, or helper-type
weakening was added, and C1's shared context and all cancellation ordering remain
intact.

UNEXECUTED regressions now exercise the actual `restToolDefs` result for all ten
dynamic candidates and invoke the real conversion helper. They assert the actual
published description (or operation-name fallback), all other operation fields,
and no custom property. A separate missing-description fixture proves the
fallback only when description is absent. No new green, build, or live-read claim
is made; fresh scoped type verification remains required when permitted.

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
