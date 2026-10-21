# M1 Monitoring Gate — Operations Runbook

**Scope:** the M1 spend/token gate on the Ovid mint + LiteLLM path.
**Owner:** Ovid platform on-call.
**Last reviewed:** 2026-10-21.

M1 has two independent jobs:

1. **Detect runaway free-tier spend** — one alert per free user per UTC day
   when their spend crosses the threshold, plus the legacy global spend alert.
2. **Stop the bleed** — free-plan token ceilings, and a global kill switch that
   denies every model call when upstream spend or abuse is out of control.

---

## 1. Thresholds and what they mean

| Control | Default | Where it lives | What happens |
|---|---|---|---|
| Free daily tokens | **50,000,000 / rolling 24h** | `ovid_plans.FREE_DAILY_TOKENS` | Next model call is denied with `free_daily_cap` (HTTP 429) until the window clears. |
| Free monthly tokens | **1,500,000,000 / rolling 30d** | `ovid_plans.FREE_MONTHLY_TOKENS` | Next call is denied with `free_monthly_cap` (HTTP 429). |
| Free monthly USD backstop | **$10 / 30d** | `free_monthly_cap_usd` (Redis `config:limits`, admin-editable) | `/mint` returns 402 once the LiteLLM user budget is exhausted. |
| Per-user daily spend alert | **$0.50 / UTC day** | `user_daily_spend_alert_usd` (Redis `config:limits`) | Queues **one** alert per user per UTC day; mint drains it and delivers it. Paid plans are excluded. |
| Global daily spend alert | **$20 / day** | `DAILY_SPEND_ALERT_USD` (mint env) | Legacy operator alert via the generic `_emit_alert` path, at most once/day. |
| Kill switch (runtime) | off | Redis `config:kill_switch` = `1` | Every model call is denied with `paid_models_disabled` (HTTP 503). Flipped from `/admin/kill-switch`. |
| Kill switch (env) | off | `OVID_PAID_MODELS_KILL_SWITCH=true` on **mint and LiteLLM** | Hard override. Denies even when the runtime flag is off. Requires a process restart to change. |

**Alert volume is intentionally low.** A single `user_spend` alert is normal
for a heavy free user. Investigate when you see several distinct users in a
short period, a sustained rise in the global daily alert, or a token-cap
spike — not on every single $0.50 alert.

---

## 2. Alert delivery and payload

Mint drains `alerts:pending:user_spend` every sweeper tick (default 30s) and
hands each item to the injectable `AlertSink` (`server/mint/m1_alerts.py`).

- **Webhook:** set `M1_ALERT_WEBHOOK_URL` on mint. One JSON payload per alert.
- **Retry:** one retry (two attempts total) on any transport error or HTTP
  status ≥ 400.
- **Log fallback:** if no webhook is configured, or both attempts fail, the
  same JSON is logged as
  `[mint] M1_ALERT` / `[mint] M1_ALERT_FALLBACK webhook failed (<Error>): <json>`.
  Alerting never raises into the sweeper.
- **History:** every delivered alert is also kept (newest first, capped at
  `M1_ALERTS_MAX`, default 200) for `GET /admin/alerts`.

Payload (exactly these fields):

```json
{
  "kind": "user_spend",
  "uid_hash": "9f2c...e41a",
  "spend_usd": 0.7531,
  "cap_usd": 0.5,
  "window": "utc_day:20261021",
  "timestamp": "2026-10-21T12:34:56Z"
}
```

- `uid_hash` is the SHA-256 of the Firebase uid. The raw uid is **never** sent,
  stored or logged by the alert path.
- There is no message/prompt content, email, API key or token in the payload.
- `window` is the UTC day the spend belongs to. `cap_usd` is the configured
  alert threshold, not the monthly backstop.
- The webhook must accept `POST` with `Content-Type: application/json` and
  return 2xx. Anything else counts as a failed attempt.

> The older `ALERT_WEBHOOK_URL` / Telegram settings still feed the generic
> operator alerts (`_emit_alert`: auto-ban, signup velocity, global spend).
> M1 structured alerts use **only** `M1_ALERT_WEBHOOK_URL`.

### Reading alerts

```bash
export MK='<LITELLM_MASTER_KEY>'
# Recent alerts + pending queue depth + whether a webhook is configured
curl -sS -H "Authorization: Bearer $MK" \
  'http://127.0.0.1:8090/admin/alerts?limit=50' | jq

# Kill-switch state (env + runtime + effective)
curl -sS -H "Authorization: Bearer $MK" \
  'http://127.0.0.1:8090/admin/kill-switch' | jq

# Admin audit trail (newest first)
curl -sS -H "Authorization: Bearer $MK" \
  'http://127.0.0.1:8090/admin/audit?limit=20' | jq '.entries[] | {ts,action,target,before,after}'
```

`/admin/*` is served on mint's local port only (Caddy does not route it
publicly). Reach it through an SSH tunnel to `127.0.0.1:8090`.

---

## 3. Kill-switch drill

Run this in staging first; in production, announce a short window because **all
model calls are denied while the switch is on**. A drill is safe: it does not
delete keys, budgets, spend counters or user data.

### Preconditions

- [ ] You have the master key and an SSH tunnel to mint.
- [ ] `M1_ALERT_WEBHOOK_URL` is configured and a test alert has arrived (or
      you accept the log fallback).
- [ ] You know a **test account** (or accept that one `/mint` call is denied).
- [ ] Baseline: `GET /admin/kill-switch` shows `"env": false, "runtime": false`.

### Steps (runtime flag — preferred)

1. **Announce** the drill and start a timer.
2. **Flip on:**
   ```bash
   curl -sS -X POST -H "Authorization: Bearer $MK" \
     -H 'Content-Type: application/json' \
     -d '{"enabled":true}' \
     'http://127.0.0.1:8090/admin/kill-switch' | jq
   ```
   Expect `kill_switch.active == true`, `runtime == true`, `env == false`.
3. **Verify mint denies:**
   ```bash
   curl -sS -i -X POST -H "Authorization: Bearer <test-firebase-id-token>" \
     -H 'X-Firebase-AppCheck: <test-app-check-token>' \
     'http://127.0.0.1:8090/mint'
   ```
   Expect **HTTP 503**, body `detail.error == "paid_models_disabled"`, header
   `x-ovid-error: paid_models_disabled`.
4. **Verify the LiteLLM hook denies:** send one chat completion through the
   proxy with a test key. Expect the same `paid_models_disabled` error. LiteLLM
   logs `[ovid_pools] kill switch active: denied model call` at most once a
   minute (no uid, no prompt).
5. **Verify the audit entry:** `GET /admin/audit` shows a `kill-switch` entry
   with `before.active=false`, `after.active=true`, actor `master-key`, and
   the request IP.
6. **Flip off:**
   ```bash
   curl -sS -X POST -H "Authorization: Bearer $MK" \
     -H 'Content-Type: application/json' \
     -d '{"enabled":false}' \
     'http://127.0.0.1:8090/admin/kill-switch' | jq
   ```
   Expect `active == false` (unless the env override is set — see below).
7. **Verify recovery:** repeat the `/mint` call from step 3 and expect 200;
   send one chat completion and expect a normal response. Confirm a second
   `kill-switch` audit entry.
8. **Record** the drill: start/end time, who ran it, result, any alert
   delivered, and the audit entry timestamps.

### Env override drill (hard override)

Only when you need to prove the env path (it requires restarts):

1. Set `OVID_PAID_MODELS_KILL_SWITCH=true` on **both** mint and LiteLLM, then
   restart both processes.
2. Verify `/mint` and the proxy return `paid_models_disabled`.
3. With the env flag still on, call `POST /admin/kill-switch {"enabled":false}`.
   The runtime flag clears, but `kill_switch.active` **stays true** and
   `env_override` is `true`. This is expected: env is the hard override.
4. Unset the env var and restart both processes. Verify calls recover.

> If the env flag is on and calls are still succeeding, the process did not
> pick up the env var (or LiteLLM was not restarted). Treat that as an
> incident: the kill switch is not actually armed.

---

## 4. Rollback

### Stop a kill-switch drill / bad flip

```bash
curl -sS -X POST -H "Authorization: Bearer $MK" \
  -H 'Content-Type: application/json' -d '{"enabled":false}' \
  'http://127.0.0.1:8090/admin/kill-switch' | jq
```

The runtime flag is a single Redis key (`config:kill_switch`). Deleting it has
the same effect:

```bash
redis-cli -n 2 DEL config:kill_switch
```

The env flag is **not** affected by either action. If `OVID_PAID_MODELS_KILL_SWITCH`
is set, unset it and restart mint + LiteLLM.

### Alert webhook is broken / noisy

- Unset `M1_ALERT_WEBHOOK_URL` and restart mint. Delivery falls back to the
  log (`[mint] M1_ALERT ...`) and the gate keeps working.
- Or point it at a known-good endpoint and restart.
- Alerts are also visible in `GET /admin/alerts`, so no alert is lost from the
  operator's view even while the webhook is down.
- Do **not** disable `user_daily_spend_alert_usd` to silence a noisy webhook;
  fix the transport or raise the threshold deliberately.

### Bad deploy / settings change

- Revert the mint image to the previous tag and redeploy. The runtime kill
  switch and alert history live in Redis and survive a redeploy; the env flag
  lives in the deployment config.
- If a settings change caused the problem, use `GET /admin/audit` to find the
  `settings` / `plan-edit` entry, then re-apply the `before` values with
  `POST /admin/settings` (or `POST /admin/plans`).
- The mint volume mirror (`/data/limits.json`) and audit JSONL
  (`/data/admin-audit.jsonl`) are the last-resort restore path after a Redis
  loss. See `server/mint/README.md`.

### Redis loss

- Runtime kill switch resets to **off**; the env override (if set) still
  applies.
- Pending spend alerts and recent alert history are lost. The per-day queue
  marker is lost too, so the hook can re-queue on the next threshold crossing
  in the same UTC day; a duplicate alert is possible after a Redis loss.
- Restore limits from the volume mirror (`restore_settings_if_missing()` runs
  at startup) and re-check `GET /admin/kill-switch` after recovery.

---

## 5. Who to page

| Trigger | Page | Target response |
|---|---|---|
| Global daily spend alert ($20) | **Ovid platform on-call** (primary) | Acknowledge in 15 min; decide whether to flip the kill switch. |
| 5+ distinct `user_spend` alerts in 1 hour, or a sustained spike | **Ovid platform on-call** | Acknowledge in 30 min; check per-user token/spend counters and abuse signals. |
| Kill switch flipped unintentionally / cannot flip it off | **Ovid platform on-call**, then **infra owner** if no ack in 15 min | Immediate. |
| Suspected credential/key abuse or a leaked master key | **Security on-call**, then platform on-call | Immediate; rotate keys and flip the kill switch. |
| Webhook down but gate healthy | **Platform on-call** (next business day unless alerts are also missing from `/admin/alerts`) | Fix transport; no user impact. |

**Escalation:** if the primary does not acknowledge within 15 minutes, page the
infra owner. If the issue involves payment/billing data, also page the billing
owner. Never post raw uids, prompts, API keys or tokens in the incident channel;
use the `uid_hash` from the alert and look up the user through
`GET /admin/user?q=<uid-or-email>` if you have legitimate access.

---

## 6. Quick reference

| Item | Value |
|---|---|
| Alert sink module | `server/mint/m1_alerts.py` |
| Queue | Redis `alerts:pending:user_spend` (set of JSON items) |
| Sent marker | `alert:user_spend:sent:<uid>:<day>` (2-day TTL) |
| Recent alerts | Redis `alerts:recent` (list, capped by `M1_ALERTS_MAX`) |
| Runtime switch | Redis `config:kill_switch` (`1` = on) |
| Env switch | `OVID_PAID_MODELS_KILL_SWITCH` (mint + LiteLLM) |
| Webhook | `M1_ALERT_WEBHOOK_URL` |
| Admin read | `GET /admin/alerts`, `GET /admin/kill-switch`, `GET /admin/audit` |
| Admin flip | `POST /admin/kill-switch` `{"enabled": true|false}` |
| Error code | `paid_models_disabled` (HTTP 503) |
