# Provider readiness — commerce, observability, infrastructure, media, automation

Review and implementation date: **2026-10-24**. Candidate inventory: **27**.
Contract read definitions: **26** (including the `jira-service-management`
ID that supersedes `opsgenie`). Production-live-supported rows: **0**.

`COMMERCE_INFRA_PROVIDERS` and `COMMERCE_INFRA_MANIFEST` are internal
contract/live-verification projections. They are not evidence of production
readiness. No batch ID was added to `CURATED_IDS` or `CURATED_MANIFEST` by this
task, and no provider is activatable merely because a descriptor exists.

Official evidence came from the assigned first-party batch C/D review, with
current first-party spot checks during implementation. Every documented read
below has a closed typed request, bounded paging, a 262,144-byte response/page
cap, an 8,192-byte model-output cap, response-shape validation, sanitized
errors, and request-scoped reviewed `ProviderEgress`. All exposed operations
have `effect: "read"` and `approval: "mode"`. There are no advertised writes.

## Candidate matrix

“Contract” means the read definition and isolation tests pass. “Live blocked”
means the required explicit opt-in/credential/resource was not provided; it is
not a provider outage and not a live pass.

| Candidate | Contract ID / named read | Minimum credential or permission | Status and actual live outcome |
|---|---|---|---|
| razorpay | `razorpay/list_payments` | Partner OAuth `read_only` | Contract passed; **live blocked — not provided**. No capture, order, refund, payout, or transfer action. |
| square | `square/list_payments` | Seller OAuth `PAYMENTS_READ`; `Square-Version: 2026-09-16` | Contract passed; **live blocked — not provided**. No payment/refund action. |
| shopify | `shopify/list_products` | `read_products`; Admin GraphQL `2026-10` | Contract passed; **live blocked — not provided**. Fixed document only; no arbitrary GraphQL/mutation. |
| woocommerce | `woocommerce/list_products` | HTTPS Basic Read consumer key/secret | Contract passed; **live blocked — not provided**. Authenticated store origin only; no order/refund write. |
| hubspot | `hubspot/list_contacts` | `crm.objects.contacts.read` | Contract passed; **live blocked — not provided**. Minimal properties; no sensitive/write scope. |
| salesforce | `salesforce/list_accounts` | OAuth `api` plus read-only integration-user CRUD/FLS | Contract passed; **live blocked — not provided**. v67.0 fixed SOQL and OAuth My Domain origin. |
| pipedrive | `pipedrive/list_deals` | OAuth `deals:read` | Contract passed; **live blocked — not provided**. v2 company origin and cursor only. |
| datadog | `datadog/list_dashboards` | Scoped PAT/SAT `dashboards_read` | Contract passed; **live blocked — not provided**. Documented site enum; no alert/mute action. |
| grafana | `grafana/list_folders` | Service-account `folders:read` | Contract passed; **live blocked — not provided**. Grafana 12+ fixed Folder API; no delete/config write. |
| pagerduty | `pagerduty/list_services` | Scoped OAuth `services.read` | Contract passed; **live blocked — not provided**. No incident, note, escalation, or alert action. |
| opsgenie | **Blocked original ID** | — | **Blocked/superseded** by `jira-service-management`; vendor shutdown horizon is 2027-04-05. No Opsgenie alert API call. |
| jira-service-management (replacement) | `jira-service-management/list_service_desks` | OAuth 3LO `read:servicedesk-request`, bound cloud ID | Contract passed; **live blocked — not provided**. Uses `api.atlassian.com/ex/jira/{cloud_id}`; new ID supersedes `opsgenie`; no request/customer write. |
| newrelic | `newrelic/get_account` | Dedicated read-only user key and connection-bound account | Contract passed; **live blocked — not provided**. Regional enum and fixed NerdGraph document; no GraphQL/NRQL input. |
| rollbar | `rollbar/get_item` | Token `read`, connection-bound `project_id` | Contract passed; **live blocked — not provided**. Numeric item ID; no status/assignment write. |
| docker-hub | `docker-hub/list_repositories` | PAT exchanged for request-scoped JWT; `repo:read` | Contract passed; **live blocked — not provided**. API 2-beta namespace route; no JWT/PAT cache or image push. |
| kubernetes | `kubernetes/get_version` | Required dedicated read-only service-account bearer token; `/version` non-resource metadata | Contract passed; **live blocked — not provided**. Fixed structured major/minor/gitVersion read only; public origin/system TLS trust. Raw resource API, proxy, watch, exec, secret, scale, rollout, restart, and delete remain denied. |
| terraform-cloud | `terraform-cloud/list_workspaces` | Team token with **Read permission for Terraform runs** | Contract passed; **live blocked — not provided**. No run, plan, apply, deploy, restart, state, or delete operation. |
| youtube | `youtube/list_channels` | `https://www.googleapis.com/auth/youtube.readonly` | Contract passed; **live blocked — not provided**. Official `pageToken` continuation; no upload, playlist write, or publish. |
| vimeo | `vimeo/list_videos` | OAuth `public private`; API 3.4 | Contract passed; **live blocked — not provided**. Field-filtered metadata only; no upload/edit. |
| spotify | `spotify/list_playlists` | `playlist-read-private` | Contract passed; **live blocked — not provided**. No playback, library, or playlist mutation. |
| imgur | `imgur/get_image` | Public Client-ID; no user scope | Contract passed; **live blocked — not provided**. Public metadata only; no upload/account/remote-URL ingestion. |
| cloudinary | `cloudinary/list_resources` | Read-only Media Library identity, Basic key/secret | Contract passed; **live blocked — not provided**. No upload, signed delivery, or root-key requirement. |
| mux | `mux/list_assets` | `Mux Video: Read only` | Contract passed; **live blocked — not provided**. No direct upload, signing key, or playback signing. |
| cloudflare-images | `cloudflare-images/list_images` | Account-scoped `Cloudflare Images Read` | Contract passed; **live blocked — not provided**. Images v2 continuation token; no direct upload or Images Edit. |
| zapier | **External-approval blocker; original ID reserved** | — | No safe generic personal connector. Concrete path: publish/approve a publicly listed Ovid integration, bind user OAuth scope `zap`, then implement only bounded `GET https://api.zapier.com/v2/zaps`. Until that approval exists, no action, webhook, workflow invocation, or substitute ID is exported. |
| make | `make/list_scenarios` | `scenarios:read`; documented zone and team binding | Contract passed; **live blocked — not provided**. Metadata columns only; no run/start/activate/webhook. |
| n8n | `n8n/list_workflows` | Enterprise granular `workflow:list` key | Contract passed; **live blocked — not provided**. Non-Enterprise/full-trust keys are rejected; no execution data/activation/invocation. |
| stackexchange | `stackexchange/list_questions` | Bearer API key; public read, no user scope | Contract passed; **live blocked — not provided**. v2.3 fixed `site=stackoverflow`; no `write_access`. |

## Origin and isolation rules

- Tenant IDs and origins come from authenticated connection config, never model
  arguments. The New Relic account argument must exactly equal the
  authenticated account binding.
- Shopify, Pipedrive, Salesforce, Datadog, New Relic, and Make use
  label/suffix or enumerated-host validation. Jira Service Management instead
  binds the cloud ID discovered during OAuth 3LO setup in authenticated config
  and calls only `https://api.atlassian.com/ex/jira/{cloud_id}/rest/servicedeskapi`;
  tenant hostnames and model-supplied cloud IDs are not accepted.
- Self-hosted WooCommerce, Grafana,
  and n8n accept origin-only HTTPS config: no userinfo, path, query, fragment,
  IP literal, loopback, or non-443 port. Production `ProviderEgress` additionally
  performs public-DNS/address checks and TLS verification on every call.
- Private/custom-CA Grafana, WooCommerce, n8n, and Kubernetes trust is not
  implemented. Kubernetes additionally exposes no discovery/resource path at
  all: only the fixed `/version` document on the authenticated origin. Raw query
  and fragment delimiters (including empty `?`/`#`), userinfo, paths, duplicate
  slashes, and encoded dot-segments are rejected before egress. A legitimate
  single root trailing slash is normalized only to the origin, and the actual
  request remains exactly `GET /version` with no query or fragment. Its
  dedicated service-account token is required; custom CA/client certificates,
  raw API paths, and cluster-admin credentials are neither needed nor accepted.
- Redirects are denied. Next-page values are typed cursor/page fields, never
  arbitrary next-page URLs. Credential-forwarding URLs and generic `fetch`
  delegation are denied.
- Docker Hub performs its documented `POST /v2/auth/token` exchange with
  `identifier`/`secret`, then discards the JWT after the read. No token is shared
  across calls or users.
- HTTP 200 error envelopes are failures, not live evidence. Numeric secret
  echoes remain redacted without corrupting JSON.

## Verification commands and actual outcomes

Contract RED before implementation:

```bash
cd /root/OvidBackend/cloud/packages/mcp
./node_modules/.bin/vitest run src/rest/descriptors/commerceInfra.test.ts test/providers/commerceInfra.contract.test.ts
```

Result: **FAIL / exit 1**, both suites unable to load the absent
`commerceInfra` definitions. Later RED cycles also proved 25 HTTP-200 error
envelopes were falsely accepted, blocked-candidate docs were absent, and the
Rollbar item ID was not yet numeric.

Initial contract GREEN: **PASS / exit 0 — 127 tests** across 2 files.
After independent review round 1, the contract command passed **154 tests**.
After the descriptor-gap fix, the current contract command is **PASS / exit 0 —
165 tests** across 2 files, including JSM OAuth 3LO cloud-ID routing, YouTube
`pageToken`, exact credential/derived-JWT response-echo canaries for all 26
rows, and the fixed Kubernetes `/version` read with trust/isolation denials.
Logs and exit-code files are under
`/tmp/opencode/ovid-production-completion/connectors-task-10-commerce/` and
`/tmp/opencode/ovid-production-completion/connectors-task-10-descriptor-gap-fix/`.

Live command actually run:

```bash
cd /root/OvidBackend/cloud/packages/mcp
OVID_LIVE_PROVIDER_TESTS=1 ./node_modules/.bin/vitest run test/providers/commerceInfra.live.test.ts
```

Actual result after the descriptor-gap fix: **FAIL / exit 1 — 26/26 rows
recorded `not provided`** because no per-provider
`OVID_LIVE_<PROVIDER>=1` opt-in or credentials were present.
**0 live reads passed, 0 provider calls occurred, 0 writes occurred.** There
were no skipped tests presented as passes. Since no write is advertised,
`OVID_LIVE_PROVIDER_WRITE_TESTS`, disposable resources, approval-bound writes,
and cleanup were not applicable and were not attempted.

To run a real read later, set both the global and exact provider opt-in, then
supply `OVID_<PROVIDER>_<CONFIG_KEY>` for every required connection field and
`OVID_<PROVIDER>_ARG_<ARG_NAME>` for required resource arguments (for example
`OVID_ROLLBAR_ARG_ITEM_ID`). The harness fails closed with the exact missing
variable names and never logs a successful response body.

## Remaining blockers

1. Every contract candidate still needs a real scoped test-account read and
   sanitized evidence before production promotion. OAuth app registration,
   refresh/revoke/disconnect lifecycle evidence is not claimed by this batch.
2. No private/custom-CA self-hosted origins are supported. n8n additionally
   requires Enterprise granular scopes.
3. No payment/order/refund mutation, infrastructure mutation, media
   upload/publish, external alert action, webhook, or workflow invocation is
   independently proven or exported. No disposable-write approval/cleanup
   evidence exists.
