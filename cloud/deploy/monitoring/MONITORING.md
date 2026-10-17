# Monitoring & alerting — `@ovid/watch`

`@ovid/watch` is the **on-box** monitoring layer for the Ovid cloud stack. It
runs as a systemd timer every 60 s, writes one JSON state file, and alerts
through **mint's existing Telegram mechanism** (`ALERT_TELEGRAM_BOT_TOKEN` +
`ALERT_TELEGRAM_CHAT_ID`) plus the optional `OVID_ALERT_WEBHOOK_URL`.

It is **not** a replacement for external uptime monitoring: if the whole VPS
or its network dies, an on-box watcher cannot report it. **UptimeRobot remains
the external layer** (HARDENING.md item F). Use both:

| Layer | Watches | Alert path |
|---|---|---|
| External (UptimeRobot) | whole-box / Caddy / public healthz reachability | email + mobile push |
| On-box (`@ovid/watch`) | queue depth, worker lag, disk, redis memory, spend parity | Telegram (+ webhook) |

## Checks and locked thresholds

| Check | What it means | Default threshold (env) |
|---|---|---|
| `gateway-health` | `GET /cloud/v1/health` returns `{"status":"ok"}` | must be ok (`GATEWAY_HEALTH_URL`) |
| `queue-depth` | BullMQ waiting jobs per queue (prefix-aware) | `> 50` (`WATCH_QUEUE_WAITING`) |
| `worker-lag` | age of the oldest waiting job | `> 300 s` (`WATCH_WORKER_LAG_S`) |
| `disk-80` | filesystem used % at `WATCH_DISK_PATH` | `> 80 %` (`WATCH_DISK_PCT`) |
| `redis-mem-80` | `used_memory / maxmemory` from `INFO memory` | `> 80 %` (`WATCH_REDIS_MEM_PCT`) |
| `spend-parity` | per-user daily drift between the TS-mint ledger (`pool:{uid}:spend` in redis db2) and LiteLLM `LiteLLM_SpendLogs` | `> max(100 ¢, 2 %)` (`WATCH_SPEND_DRIFT_CENTS`, `WATCH_SPEND_DRIFT_PCT`) |

Notes:

- `redis-mem-80` computes the ratio from `INFO memory`; it never hardcodes
  the prod `maxmemory` (1468006400 = 1400 MiB). If `maxmemory=0` (unbounded)
  the check is `ok` and says so in its detail.
- `spend-parity` compares **integer cents**. `WATCH_LITELLM_DATABASE_URL`
  must be a **read-only** connection to LiteLLM's Postgres database (the
  table is `LiteLLM_SpendLogs`, not in `ovid_cloud`); `REDIS_MINT_URL` is the
  mint db2 projection URL (its path carries `/2`). If either is missing while
  `WATCH_SPEND_PARITY=on`, the check fails loudly — a blind money check is
  worse than a noisy one. Disable explicitly with `WATCH_SPEND_PARITY=off`
  only when a side is genuinely unavailable.
- Queue names are `WATCH_QUEUE_NAMES` (comma-separated; default
  `agent-runs`). `WATCH_QUEUE_PREFIX` must match the deployment (`bull` in
  production, `bull:staging` in staging).

## Edge-triggered alerting (Review Focus #5)

A check is evaluated every minute, but an alert is sent only on a **state
edge**:

1. **unknown/ok → fail** — alert immediately (a monitor installed while
   something is broken must speak up).
2. **fail → fail** — silent until `WATCH_REPEAT_AFTER_S` (default **1800 s**)
   has elapsed since the last *delivered* alert; then exactly one reminder.
3. **fail → ok** — exactly one recovery notice, then silence.

State lives in `WATCH_STATE_FILE`
(`/var/lib/ovid-cloud-watch/state.json`):

```json
{ "states": { "queue-depth": false }, "lastAlertAt": { "queue-depth": 1760700000000 } }
```

A delivery failure exits nonzero and does **not** record `lastAlertAt`, so the
next timer tick retries the edge. A dead Telegram token cannot silently
swallow an alert; `journalctl` shows the failure and the unit is red.

## Install (owner-gated)

Prerequisites: the repo is at `/opt/ovid-cloud/repo`, the watch package is
built (`cd /opt/ovid-cloud/repo/cloud && pnpm --filter @ovid/watch build`),
and mint's Telegram bot token/chat id are known.

```bash
# 1. State directory + env file
sudo install -d -m 755 /var/lib/ovid-cloud-watch
sudo cp /opt/ovid-cloud/repo/cloud/deploy/monitoring/watch.env.example /opt/ovid-cloud/watch.env
sudo $EDITOR /opt/ovid-cloud/watch.env      # fill every CHANGE_ME
sudo chmod 600 /opt/ovid-cloud/watch.env

# 2. Units
sudo cp /opt/ovid-cloud/repo/cloud/deploy/monitoring/ovid-cloud-watch.service \
        /opt/ovid-cloud/repo/cloud/deploy/monitoring/ovid-cloud-watch.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ovid-cloud-watch.timer

# 3. Prove the delivery path end to end (sends ONE real alert — owner confirms)
sudo /usr/bin/node /opt/ovid-cloud/repo/cloud/apps/watch/dist/main.js --self-test
```

`--self-test` sends exactly:

```text
TEST alert from ovid-cloud-watch on <host> at <iso-ts>
```

and exits `0` **only** when the configured sink returned HTTP 200. The owner
must confirm receipt in Telegram (or the webhook receiver).

## Verification gate

Run immediately after install and record the output below:

```bash
systemctl list-timers ovid-cloud-watch.timer        # NEXT is <= 60 s away
sleep 70
journalctl -u ovid-cloud-watch.service -n 20 --no-pager
```

A clean pass prints one line per check plus:

```text
[watch] pass: 6 checks, 0 alerts, 0 recoveries
```

Then prove the edge behaviour without waiting for a real incident:

```bash
# Force queue-depth to fail: 51 waiting jobs on a scoped prefix, then run.
# (Use a scratch prefix + delete only your keys; never FLUSHDB.)
node apps/watch/dist/main.js                 # ALERT queue-depth
node apps/watch/dist/main.js                 # no second alert (quiet window)
# Remove the jobs, run again:
node apps/watch/dist/main.js                 # RECOVERED queue-depth
```

In staging / dry validation, point `OVID_ALERT_WEBHOOK_URL` at a local
one-shot HTTP server (or inject a fake sender in the unit tests) — **never**
send a real Telegram message from a test.

## Troubleshooting

| Symptom | Cause / action |
|---|---|
| `config error: no alert sink configured` | neither Telegram pair nor webhook set; fill `/opt/ovid-cloud/watch.env` |
| `config error: WATCH_LITELLM_DATABASE_URL is required…` | spend parity is on but a ledger seam is missing; wire both or set `WATCH_SPEND_PARITY=off` |
| `alert delivery failed: telegram … HTTP 401` | bot token revoked/wrong; rotate it in mint's env and here |
| unit red every minute, one check | inspect `journalctl -u ovid-cloud-watch.service`; the state file shows the failing check |
| `queue-depth` always 0 | wrong `WATCH_QUEUE_PREFIX` / `REDIS_Q_URL` (the timer is watching a different key space) |

## Verification log

Record each install/drill here (newest first): date, host, `--self-test`
result, `list-timers` next-run, journal tail, owner confirmation.

- **2026-10-17 — Task 11 dry validation (staging-equivalent, fake sink):**
  `--self-test` delivered to a loopback webhook and exited 0; a forced
  queue-depth failure produced one alert, a repeat run produced none, and
  clearing the queue produced one recovery. No real Telegram message was
  sent. (Unit-level proof: `pnpm --filter @ovid/watch test`.)
- **Pending `[OWNER]`:** live install + real-sink `--self-test` (see above).
