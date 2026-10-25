# Measured SLO / load report — {{profile}}

> Template only. No measured run is supplied by this file. **REAL LOAD RUNS PENDING** until an authorized staged run produces the referenced JSON and this report. Publish only the contiguous highest passing measured point under the recorded conditions; never extrapolate.

## Identity and conditions

- runId: `{{runId}}`
- status: `{{status}}` (`pass`, `fail`, or `unmeasured`; missing facts are not passes)
- buildIds: `{{buildIds}}` — gateway/worker/Web/Android/load build IDs
- environment: `{{environment}}` — staged environment name and provider mode
- hardware: `{{hardware}}` — actual host CPU/RAM and measurement source
- container limits: `{{containerLimits}}`
- database configuration: `{{database}}` — redacted URL and non-secret configuration
- Redis configuration: `{{redis}}` — redacted URL and non-secret configuration
- R2 configuration: `{{r2}}` — bucket and non-secret configuration
- model configuration: `{{model}}`
- provider configuration: `{{provider}}` — mock LLM and live provider evidence remain separate files/runs
- profile and actual load point: `{{profile}}` / `{{loadPoint}}`
- samples: `{{samples}}`
- duration: `{{duration}}` actual wall-clock milliseconds

## Latency (separate measurement surfaces)

| Surface | Samples | p50 ms | p95 ms | p99 ms | Source |
|---|---:|---:|---:|---:|---|
| Primary (`{{latencySource}}`) | `{{latencySamples}}` | `{{p50}}` | `{{p95}}` | `{{p99}}` | `{{latencySource}}` |
| queue delay (not send→202) | `{{queue.samples}}` | `{{queue.p50}}` | `{{queue.p95}}` | `{{queue.p99}}` | `{{queue.source}}` |
| firstToken | `{{firstToken.samples}}` | `{{firstToken.p50}}` | `{{firstToken.p95}}` | `{{firstToken.p99}}` | `{{firstToken.source}}` |

Use `null` / `UNMEASURED`, never zero, for an absent sample. Zero is valid only when zero was actually measured. Queue and first-token targets require a measured baseline; this template invents none.

## Outcomes and integrity

- completion: `{{completion}}`
- failure (`run_failed`, including classified cancellations): `{{failure}}`
- cancellation classification: user `{{cancellation.user}}`, injected `{{cancellation.injected}}`, other `{{cancellation.other}}`
- Effective `run_failed`: `{{runFailedPct}}%` over `{{effectiveSamples}}` samples; only actual user/injected cancellations are excluded
- availability: `{{availability}}` (target ≥99.5%)
- crash-free sessions: `{{crashFreeSessions}}` (target ≥99.5%)
- ANR: `{{anr}}` (target ≤0.5%)
- lost / duplicates: `{{lost}}` / `{{duplicates}}`
- integrity evidence: `{{integrity}}` — real event-log ground truth and Postgres mirror diff, with sample count
- cross-tenant failures: `{{crossTenantFailures}}` (required zero)
- security failures: `{{securityFailures}}` (required zero)

## Resources and actual cost

- cpu: `{{cpu}}`
- memory: `{{memory}}`
- connections.database: `{{connections.database}}`
- connections.redis: `{{connections.redis}}`
- browserMemory: `{{browserMemory}}` — separate browser/Chromium measurement, not HTTP throughput
- browser viewers/frames: `{{browser}}`
- collab owner/members/competing joins/competing turns/long-polls/leases/host+sender accounting: `{{collab}}`
- provider request/live/per-provider rate-limit facts (reconciled to aggregates): `{{provider}}`
- provider lazyConnections: `{{provider.lazyConnections}}`
- provider schemaBudget: `{{provider.schemaBudget}}`
- provider oauthRefreshStorm: `{{provider.oauthRefreshStorm}}`
- modelCost: `{{modelCost}}` — actual metered USD and source/sample count; reserved or estimated cost is not actual cost

## Gates

- Existing harness thresholds: `{{harness}}`
- failedGates: `{{failedGates}}`
- unmeasuredGates: `{{unmeasuredGates}}`
- Notes/probe errors: `{{notes}}`

A nonzero CLI exit still writes this report and the complete JSON, including failed/unmeasured gates. `highestPassing` is only the contiguous highest actually passing measured point for one build/environment/series/provider mode. A later passing report cannot skip an earlier failed or unmeasured step. Mock and live results are never merged.

## Same-run observation input

`collab50` and `provider-catalog` use `runner: "observed"`: the CLI evaluates a specialized harness artifact and never substitutes generic HTTP traffic. The JSON file named by the profile's observation environment variable contains `{runId,profile,buildIds,providerMode,evidence}`. `evidence` is the complete `MeasuredRun`; its embedded run ID, profile, build IDs, kind, series, actual load point, environment, provider observation mode, and environment provider mode must agree with the envelope/profile/invocation. A missing provider measurement remains `UNMEASURED`; it never borrows the envelope mode. Live invocations additionally require actual live response samples. `browser-viewers` uses `runCapacityShard` and separately sampled browser-container memory, plus a same-run observation of the actual concurrent-viewer high-water mark and viewer/frame facts. The harness's cumulative `browserLiveUsersObserved` counter is never treated as a concurrency maximum. Scenario/capacity observation supplements must have the exact same `RELEASE_RUN_ID`, build, environment, series, profile/kind/load-point, and provider-mode identity. `runScenario` receives that ID and both scenario/capacity results must return it; stale availability, crash/ANR, cost, browser, or other supplements are rejected rather than merged. Nested `run.status` is always replaced by the computed evaluation status, or `fail` when evaluation cannot complete.

## Publishable statement

`{{capacityStatement}}`

If there is no passing measured point, use: **No passing measured load point; REAL LOAD RUNS PENDING.** Do not convert architectural targets, desired concurrency, HTTP throughput, or a mock-provider result into browser, provider, live-production, or general-user capacity.
