# Ovid Cloud — Phase-0 hardening checklist (owner-facing)

Closes the spec §11 "VPS hardening (Phase 0)" items
(`docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md`) — Task 12
of the P0+P1 spine plan. Companion to `DEPLOY.md` (activation runbook): this
file is about hardening **the box**, not about deploying the cloud stack.

**How to use this file**

- Items flagged **[OWNER DECISION]** stop services, restart production daemons,
  or rotate secrets. They must be decided and executed by the owner explicitly
  (an agent may run one only with per-item authorization, after reading the
  item). Nothing here was executed while writing this file — the audit that
  produced "Current state" below was **read-only**.
- Unflagged steps are verification-only (read-only commands, safe anytime).
- Suggested order: **D + F now** (zero downtime) → **E + G batched into the
  activation window** (`DEPLOY.md` §5–6; each causes brief downtime) →
  **A, B, C** as the security gate before real users reach the cloud stack
  (spec R3: a box that will host untrusted user sandboxes must not carry an
  internet-exposed root desktop or plaintext-password services).
- Every item ends with a decision/verification line to fill in — an item is
  only "done" when its expected output was observed and recorded.
- **Repo-visibility note:** this file is committed, and the repo has been
  PUBLIC before (`docs/HARDENING_TRACKER.md` S1). It deliberately contains no
  secrets and no client IPs — only host configuration state that is largely
  discoverable by any port scanner anyway. Keep it that way if you extend it.

---

## Current state (observed 2026-10-16, read-only — facts, not changes)

Reproduce any row with the command shown. All outputs below were captured on
2026-10-16 without modifying anything.

| Area | Observed | Command |
|---|---|---|
| novnc / vncserver@1 / vsftpd | **all three `enabled` + `active`** | `systemctl is-enabled novnc vncserver@1 vsftpd; systemctl is-active novnc vncserver@1 vsftpd` |
| Internet-facing listeners | `0.0.0.0:22`+`[::]:22` (sshd), `0.0.0.0:21` (vsftpd), `0.0.0.0:5901`+`[::]:5901` (Xtigervnc, **root desktop**), `0.0.0.0:6080` (websockify/noVNC), `*:80`+`*:443` (Caddy). Everything else is loopback-only: `127.0.0.1:` 2019+8081 (caddy admin), 4000 (litellm), 8090 (mint), 8080 (account-dev), 5433 (postgres), 6390, 9222 (chrome devtools) | `ss -tlnp` |
| ufw | `active`; ALLOW from Anywhere (v4+v6): **22, 443, 6080, 5901, 21, 40000:50000** (last = vsftpd passive range) | `ufw status numbered` |
| sshd effective config | `passwordauthentication no` (drop-in `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` overrides `PasswordAuthentication yes` in the main file), **but `kbdinteractiveauthentication yes` + `usepam yes` ⇒ password login is effectively ON** via keyboard-interactive/PAM. `pubkeyauthentication yes`, `permitrootlogin yes`. Socket-activated (`ssh.socket` enabled). Hardening drop-in `50-ovid-limits.conf` present (`MaxAuthTries 4`, `LoginGraceTime 30`, `MaxStartups 10:30:60`) | `sshd -T \| grep -Ei 'passwordauth\|kbdinteractive\|permitroot\|usepam\|pubkey'` |
| SSH keys | **`/root/.ssh/authorized_keys` is EMPTY (0 bytes) — no working key login exists today.** Journal (last 24 h): 6 × `Accepted keyboard-interactive/pam for root` from 4 distinct client IPs (= the owner's actual login path), ~310 failed/invalid-user lines | `wc -c /root/.ssh/authorized_keys`; `journalctl -u ssh --since -24h --no-pager \| grep -c Accepted` |
| fail2ban | `active` + `enabled` (jails `sshd`, `vsftpd`, `recidive` per the 2026-10-11 review) | `systemctl is-active fail2ban; systemctl is-enabled fail2ban` |
| Docker logging | driver `json-file`, **`/etc/docker/daemon.json` does not exist** ⇒ no size cap (unbounded growth; a scratch container created 2026-10-16 got `LogConfig {"Type":"json-file","Config":{}}`). Current largest container log: 3.0 MB — small today, uncapped forever | `docker info --format '{{.LoggingDriver}}'; cat /etc/docker/daemon.json` |
| litellm image | `/opt/ovid-gateway/docker-compose.yml` line 49: `image: ghcr.io/berriai/litellm:main-latest` — **floating tag, UNPINNED**. Running `ovid-gateway-litellm-1` (Up 12 h): image `sha256:a69f5f0c56b868d2fdfce7abfb037fed947b70ede202047ffc19c14dc96ab90a`, built `2026-09-30T08:33:20Z`, RepoDigest `ghcr.io/berriai/litellm@sha256:a69f5f0c…` (on this box the digest string equals the image ID) | `docker inspect ovid-gateway-litellm-1 --format '{{.Config.Image}}'`; `docker inspect ghcr.io/berriai/litellm:main-latest --format '{{.Id}} {{.Created}} {{json .RepoDigests}}'` |
| Caddy trusted_proxies | **ALREADY PRESENT** in the live Caddyfile global `servers` block: `trusted_proxies static` with all 15 IPv4 + 7 IPv6 Cloudflare CIDRs + `client_ip_headers CF-Connecting-IP X-Forwarded-For`. Fetched `cloudflare.com/ips-v4` + `/ips-v6` on 2026-10-16 → **identical** (item D). Caddy v2.11.4 (`caddy:2-alpine` container, host network) | see item D |
| Public health | `https://api.ovidsi.com/healthz` → **HTTP 200** (0.55 s). `/cloud/v1/health` not yet routed (activation pending, `DEPLOY.md` §6) | `curl -sS -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/healthz` |
| Public-repo exposure | Repo was flipped PUBLIC; HEAD is clean (`git ls-files` shows no keystore / `google-services.json` / firebase JSONs) but per `docs/HARDENING_TRACKER.md`: **signing key + Firebase config must be treated as exposed and rotated; git-history purge still pending** | `git ls-files \| grep -Ei 'keystore\|\.jks\|google-services\|firebase'` |
| Server-side secret inventory (names only — values never leave the box) | `/opt/ovid-gateway/.env` (0600): `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_PASSWORD`, `UI_PASSWORD`, `OVID_PROBE_KEY`, … plus `firebase-admin.json`, `caddy/origin.key`, `account.env`, `.db-password` (all 0600). Cloud secrets do not exist yet — placeholders in `cloud/deploy/.env.example`, filled at activation into `/opt/ovid-cloud/.env` | `cut -d= -f1 /opt/ovid-gateway/.env` |

**Prior owner decisions this checklist re-opens.** The 2026-10-11 security
review (`docs/screen-review/10-vps-server.md`, deliberately untracked) records
root VNC/noVNC exposure and root password SSH as **"Accepted risk (owner)"**.
Both decisions predate the choice to host untrusted user sandboxes on this
machine; the cloud spec (§11, R3, R5) re-opens them. Items A and B therefore
need **explicit re-confirmation** — a new decision, not a silent carry-over.

---

## A. [OWNER DECISION] Disable novnc + vncserver@1 + vsftpd

**Why.** A **root** graphical desktop (TigerVNC `:1`, `-localhost no`,
VncAuth) plus its noVNC bridge are open to the whole internet (ufw allows
5901 + 6080 from Anywhere). The VNC password protocol is DES-era, capped at 8
significant characters, and noVNC serves the session over **plain HTTP** —
one guessed or sniffed password = root on the production box, every secret,
every user's data. The desktop also runs Chrome as root with a logged-in
profile. vsftpd is a second plaintext-credential path (port 21 + passive
40000–50000 open, `write_enable=YES`, `force_local_logins_ssl=NO`), and
`ftpuser` has `/bin/bash` — it can SSH too (interacts with item B). Once this
box hosts user sandboxes (spec R3), an exposed root desktop is not an
acceptable risk: any sandbox-escape bug becomes a root-desktop bug.

**Decide first:** do you still use the root desktop or FTP? Replacements that
keep the capability without the exposure:

- Desktop: SSH tunnel — run VNC with `-localhost yes` and connect via
  `ssh -L 5901:localhost:5901 root@<SERVER>` (any VNC viewer on 127.0.0.1:5901).
- Files: **SFTP over port 22** (`sftp root@<SERVER>`) — already works, no new
  software; nothing else is needed from vsftpd.

**Commands (owner).** Warning: stopping `vncserver@1` kills the running root
desktop session (including any open Chrome windows) — save work first.

```bash
# 1. Record what you are about to stop (read-only):
systemctl status novnc.service vncserver@1.service vsftpd.service --no-pager | head -20

# 2. Disable + stop:
sudo systemctl disable --now novnc.service
sudo systemctl disable --now vncserver@1.service
sudo systemctl disable --now vsftpd.service

# 3. Close the firewall holes (each `delete allow` removes the v4+v6 pair):
sudo ufw delete allow 6080/tcp
sudo ufw delete allow 5901/tcp
sudo ufw delete allow 21/tcp
sudo ufw delete allow 40000:50000/tcp
```

**Expected output (gate):**

```bash
systemctl is-enabled novnc vncserver@1 vsftpd   # → disabled  disabled  disabled
systemctl is-active  novnc vncserver@1 vsftpd   # → inactive  inactive  inactive
ss -tlnp | grep -E ':(21|5901|6080)\b'          # → no output
ufw status numbered | grep -E '6080|5901|21|40000'   # → no output (22 + 443 remain)
```

**Rollback** (if the desktop/FTP is genuinely needed, prefer the tunnel/SFTP
alternatives above instead): `sudo systemctl enable --now <unit>` and re-add
the `ufw allow` rules.

- [ ] Decision: ☐ disable all three ☐ keep (re-confirmed accepted risk, reason: ＿＿＿) · date · by
- [ ] Verified: gate output observed and pasted into the decision log below.

---

## B. [OWNER DECISION] SSH key-only (after proving a key login works)

**Why.** Effective sshd today: `passwordauthentication no` but
`kbdinteractiveauthentication yes` + `usepam yes` ⇒ **root password login is
effectively on** (journal: 6 successful `keyboard-interactive/pam` logins in
the last 24 h, ~310 failed/invalid attempts — internet-wide brute force is
constant; fail2ban mitigates but does not remove it). The 2026-10-11 review
records this as an accepted risk because the owner connects from a phone and
a PC with changing IPs; that decision pre-dates the sandbox-hosting plan and
needs explicit re-confirmation.

**Blocker observed 2026-10-16: `/root/.ssh/authorized_keys` is EMPTY.** There
is no working key login today, so password auth **cannot** simply be switched
off — that would lock the owner out (this VPS has no out-of-band console).
The key-first order below is mandatory.

**Step 0 — decide.** Every device the owner uses (phone included — Termius,
Blink, etc. all support ed25519 keys) must be able to authenticate with a
key. If any daily-driver device cannot, stop here and keep the mitigated
status quo (fail2ban + `50-ovid-limits.conf` stay).

**Step 1 — install keys (per device, while password login still works).**
On each client: `ssh-keygen -t ed25519 -C "owner-<device>"`. Then either
`ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<SERVER_IP>` or append the public
key manually:

```bash
# on the server, per device (public keys are not secret):
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '<PUBKEY LINE>' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

**Step 2 — GATE: prove key login from EVERY device** (new session each time):

```bash
ssh -o PreferredAuthentications=publickey root@<SERVER_IP> 'echo KEY-LOGIN-OK'
# → KEY-LOGIN-OK   (and log in from the phone's SSH app once, key-only)
wc -l /root/.ssh/authorized_keys    # → ≥ one line per device
```

**Do not continue until this passes on every device.**

**Step 3 — KEEP THE WORKING SESSION OPEN.** Leave one verified root session
open in a terminal until step 5 passes from a *second, new* connection. If
anything goes wrong, that open session is the only way back in.

**Step 4 — flip sshd to key-only:**

```bash
sudo tee /etc/ssh/sshd_config.d/51-ovid-keyonly.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sudo sshd -t                      # GATE: no output = syntax OK. Any output: fix before continuing.
sudo systemctl restart ssh.service   # socket-activated: listener stays up, your open session survives
```

(`PermitRootLogin prohibit-password` = root may log in **with keys only** —
exactly what step 2 proved. `PasswordAuthentication no` here also normalizes
the contradiction with the main `sshd_config`, which still says `yes`.)

**Step 5 — verify from a NEW session (old one still open):**

```bash
ssh -o PreferredAuthentications=publickey root@<SERVER_IP> 'echo KEY-LOGIN-OK'
# → KEY-LOGIN-OK
ssh -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no root@<SERVER_IP>
# → Permission denied (publickey).        ← password path is closed
sshd -T | grep -Ei 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
# → passwordauthentication no / kbdinteractiveauthentication no / permitrootlogin prohibit-password
```

**Rollback (from the open session only):**
`sudo rm /etc/ssh/sshd_config.d/51-ovid-keyonly.conf && sudo systemctl restart ssh.service`.

Notes: fail2ban + recidive should stay enabled (they now protect a
key-only port — cheap insurance). If item A is *not* done, also set
`ftpuser`'s shell to `/usr/sbin/nologin` (`sudo usermod -s /usr/sbin/nologin ftpuser`),
otherwise the FTP account keeps a password SSH path.

- [ ] Decision: ☐ key-only ☐ keep password (re-confirmed, reason: ＿＿＿) · date · by
- [ ] Verified: step-2 gate on all devices + step-5 outputs recorded below.

---

## C. [OWNER DECISION] Secret rotation checklist

**Why.** `docs/HARDENING_TRACKER.md` (verification log): the repo was flipped
**PUBLIC**; confidential files were removed from HEAD but **the git history
still contains the signing key material and Firebase config — treat them as
exposed and rotate; history purge still pending.** HEAD today is clean
(`git ls-files` finds no keystore / `google-services.json` / firebase JSONs).
Server-side secrets in `/opt/ovid-gateway` were 0600 files never committed —
rotate those only if you believe they left the box; they are inventoried so
the decision is explicit. Generate every new secret with
`openssl rand -hex 24` (or stronger), never commit it, never paste it into
issues/chats.

**Known-exposed (in public git history) — rotate these:**

1. **Firebase service-account key** (`/opt/ovid-gateway/firebase-admin.json`;
   the cloud gateway mounts the same class of file per `FIREBASE_CREDENTIALS_HOST_PATH`
   in `cloud/deploy/.env.example`).
   Firebase console → Project settings → Service accounts → **Generate new
   private key**; replace the file (`chmod 600`), restart its consumers
   (`cd /opt/ovid-gateway && docker compose restart <services mounting it>`;
   cloud gateway/worker after activation), verify app auth still works, then
   **delete the old key** in the console. Service-affecting: brief auth
   failures during the swap — schedule it.
2. **Android signing keystore.** If enrolled in **Play App Signing**: Play
   Console → Testing/Setup → App signing → *Request upload key rotation*,
   generate a new upload keystore locally, ship the new upload cert through
   the flow. If NOT enrolled: the actual APK signing key was exposed — enroll
   in Play App Signing (migration) so Google's re-signing key supersedes it.
   Store the new keystore + passwords **off this machine** (password manager /
   CI secret). Never re-commit.
3. **Anything else that was in the repo while public** — audit history if in
   doubt: `git log --all --diff-filter=A --name-only | grep -Ei 'json|jks|keystore|pem|key'`
   and rotate whatever real credentials show up.

**Server-side inventory (not repo-exposed; rotate only on suspicion or on a
scheduled window — each is service-affecting):**

| Secret | Lives in | Rotation sketch | Impact |
|---|---|---|---|
| `LITELLM_MASTER_KEY` | `/opt/ovid-gateway/.env` | new value → `docker compose up -d litellm` → update every admin client that uses it | seconds of LiteLLM downtime |
| `LITELLM_SALT_KEY` | same | **careful:** encrypts provider keys stored in the LiteLLM DB — rotating requires re-entering every provider credential afterwards. Rotate only if you believe it left the box | high effort |
| `POSTGRES_PASSWORD` / `DATABASE_URL` | same | `ALTER ROLE … PASSWORD` inside the container → update `.env` → recreate dependents | brief DB-auth outage |
| `REDIS_PASSWORD` (live) | same | update `.env` → recreate redis + dependents | brief |
| `REDIS_Q_PASSWORD` (cloud) | `/opt/ovid-cloud/.env` at activation | **generate fresh at activation; never reuse an exposed value** | none (pre-launch) |
| `UI_PASSWORD`, `OVID_PROBE_KEY`, `account.env`, `.db-password`, `caddy/origin.key` | `/opt/ovid-gateway/**` | regenerate + restart the one consumer | low |
| VNC password / `ftpuser` password | VNC config / `/etc/passwd` | only relevant if item A keeps those services open | — |

**Repo hygiene (owner, non-destructive):**

```bash
# Enable GitHub secret scanning + push protection on the repo:
#   https://github.com/<owner>/OvidAI/settings/security  → tick both.
# Optional history purge (does NOT undo forks/clones — rotation above is the real control):
#   git filter-repo --path <secret-path> --invert-paths   # on a mirror; coordinate force-push
```

- [ ] Decision per row above (rotate / defer + reason) · date · by
- [ ] Verified: post-rotation smoke — `curl -sf https://api.ovidsi.com/healthz` → 200; app sign-in works; LiteLLM `/v1/models` responds.

---

## D. Cloudflare `trusted_proxies` for Caddy — ALREADY LIVE, verification only

**Observed 2026-10-16:** the live `/opt/ovid-gateway/caddy/Caddyfile` global
`servers` block already contains `trusted_proxies static` with the full
Cloudflare list (15 IPv4 + 7 IPv6) and `client_ip_headers CF-Connecting-IP
X-Forwarded-For`; a `comm` diff against today's official lists returned
**empty (identical)**. Caddy v2.11.4 (feature requires ≥ 2.7). ⇒ **No change
is needed at activation** — the `/cloud/*` snippet automatically benefits:
`header_up X-Forwarded-For {client_ip}` resolves `{client_ip}` to the real
visitor IP behind Cloudflare (and only trusts those headers when the peer is
a Cloudflare edge — direct origin hits cannot spoof it).

For DR / fresh provisioning the global block is documented at the bottom of
`cloud/deploy/caddy-snippet.conf` (it goes in the **top-level** `{ servers { … } }`
block, never inside a site block). Do not copy it into the live Caddyfile —
it is already there.

**Verification (read-only, safe anytime; re-run quarterly — Cloudflare
changes ranges rarely):**

```bash
grep -n 'trusted_proxies\|client_ip_headers' /opt/ovid-gateway/caddy/Caddyfile
# → both lines present in the top { servers { … } } block

comm -3 \
  <( { curl -s https://www.cloudflare.com/ips-v4; echo; curl -s https://www.cloudflare.com/ips-v6; } \
     | sed '/^$/d' | sort ) \
  <( sed -n 's/.*trusted_proxies static //p' /opt/ovid-gateway/caddy/Caddyfile \
     | tr ' ' '\n' | sed '/^$/d' | sort )
# → NO output (exit 0) = the live list matches Cloudflare's official list exactly
```

Official fetch commands (source of truth):
`curl -s https://www.cloudflare.com/ips-v4` and `curl -s https://www.cloudflare.com/ips-v6`.

- [x] Verified 2026-10-16: lists identical (empty `comm` output), Caddy v2.11.4 — Task 12 audit.
- [ ] Next quarterly re-check: date · by

---

## E. [OWNER DECISION] Docker log rotation (`/etc/docker/daemon.json`)

**Why.** Observed: logging driver `json-file` with **no `/etc/docker/daemon.json`**
⇒ every container log grows without bound (a scratch container created during
this audit got `LogConfig {"Type":"json-file","Config":{}}`). Largest log
today is only 3.0 MB, but LiteLLM/mint are chatty and the disk is finite.
`max-size 50m` × `max-file 3` caps each container at 150 MB.

**Cost: `systemctl restart docker` restarts EVERY container** (postgres,
redis×2, litellm, mint, account-dev, shim, caddy) — ~30–60 s of downtime for
`api.ovidsi.com`, live WS/SSE connections drop, in-flight LLM calls fail.
Containers come back automatically (`restart: unless-stopped` / compose
policies). **Sequence it with the activation window** (`DEPLOY.md` §5–6):
do it *before* `docker compose up` of the cloud stack so the new containers
are born with rotation.

**Commands (owner, inside the window):**

```bash
# 1. The file does not exist today (verified 2026-10-16) — create it:
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
#    (If a daemon.json EVER exists by then: merge with jq, never blind-overwrite:
#     jq '. + {"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"3"}}')

# 2. Restart docker (the downtime moment):
sudo systemctl restart docker

# 3. Gate — new containers must inherit the cap (uses any local image):
cid=$(docker create redis:7-alpine true) \
  && docker inspect "$cid" --format '{{json .HostConfig.LogConfig}}' \
  && docker rm "$cid" >/dev/null
# → {"Type":"json-file","Config":{"max-file":"3","max-size":"50m"}}

# 4. Everything came back:
docker ps --format '{{.Names}}\t{{.Status}}'      # all Up, no Restarting loop
curl -sS -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/healthz   # → 200
```

**Gotcha:** daemon defaults apply **at container creation** — *existing*
containers keep their uncapped config until recreated. Check with:
`docker inspect $(docker ps -q) --format '{{.Name}}: {{json .HostConfig.LogConfig}}'`.
They get recreated naturally on the next `docker compose up -d` with changes;
forcing it (`up -d --force-recreate`) is another window — usually not worth it
for 3 MB logs; just don't be surprised that rotation "hasn't applied" yet.

**Rollback:** `sudo rm /etc/docker/daemon.json && sudo systemctl restart docker`
(same brief downtime).

- [ ] Decision: ☐ apply in activation window ☐ defer · date · by
- [ ] Verified: step-3 + step-4 outputs recorded below.

---

## F. [OWNER DECISION] External uptime alerting

**Why.** Nothing outside the box currently watches it: if Caddy, LiteLLM or
the whole VPS dies at 3 a.m., the owner finds out from users. Two endpoints
matter:

- `https://api.ovidsi.com/healthz` — live stack (**HTTP 200 verified 2026-10-16**);
- `https://api.ovidsi.com/cloud/v1/health` — cloud gateway, monitor **after
  activation** (`DEPLOY.md` §6). It returns 200 `{"status":"ok",…}` or **503**
  when db/redis-q are degraded — external pingers treat non-2xx as DOWN, which
  is exactly the desired alert.

**Free option documented: UptimeRobot** (free plan verified 2026-10-16: 50
monitors, 5-minute checks, HTTP(s)/port/ping/keyword, email + mobile-push
alerts, no credit card). It is external by construction — a same-box solution
(Uptime Kuma) would be blind to whole-VPS outages, so it is not a substitute.

**Setup (owner, ~10 minutes, zero server impact):**

1. Sign up at `https://uptimerobot.com` with the owner email; install the
   mobile app and enable push for alerts.
2. Monitor 1: **Add new monitor** → type `HTTP(s)` → URL
   `https://api.ovidsi.com/healthz` → interval 5 min → name `ovid-live-healthz`.
3. Monitor 2 (after activation): type `HTTP(s)` → URL
   `https://api.ovidsi.com/cloud/v1/health` → interval 5 min → name
   `ovid-cloud-health`. Optional keyword variant: monitor type *keyword*,
   keyword `ok`, "exists" — also alerts if the body changes while status stays 200.
4. Alert-contact test **without touching production**: create a third monitor
   for `https://api.ovidsi.com/__definitely_down_test__` → expect a DOWN alert
   email/push within ~5–10 min → delete that monitor. This proves the whole
   notification path.
5. Gate: both real monitors show **UP** in the dashboard within 10 minutes.

- [ ] Decision: ☐ UptimeRobot ☐ other (name: ＿＿＿) ☐ defer · date · by
- [ ] Verified: DOWN-alert test received; monitors UP. Monitor 2 added at activation.

---

## G. [OWNER DECISION] Pin `litellm:main-latest` to the running digest

**Why.** Observed **current unpinned state**: `/opt/ovid-gateway/docker-compose.yml`
line 49 says `image: ghcr.io/berriai/litellm:main-latest` — a floating tag.
Any `docker compose pull` / `up -d` after an upstream push silently swaps the
LLM gateway to untested code (LiteLLM also runs forward-only DB migrations —
a bad `main` release can wedge the live proxy). Pinning by digest makes
recreates deterministic: the container always restarts with the bits that are
proven to work, and upgrades become deliberate edits.

**Running version observed 2026-10-16** (re-run the inspect at execution time
— the value below is only valid if the container has not been recreated
since; "Up 12 hours" at audit time, image built 2026-09-30):

```
image ref   ghcr.io/berriai/litellm:main-latest
image ID    sha256:a69f5f0c56b868d2fdfce7abfb037fed947b70ede202047ffc19c14dc96ab90a
RepoDigest  ghcr.io/berriai/litellm@sha256:a69f5f0c56b868d2fdfce7abfb037fed947b70ede202047ffc19c14dc96ab90a
```

**Commands (owner; brief LiteLLM downtime — chat completions 502 for seconds;
batch into the same window as item E):**

```bash
cd /opt/ovid-gateway

# 1. Re-capture the digest of what is RUNNING right now (source of truth):
docker inspect ghcr.io/berriai/litellm:main-latest --format '{{index .RepoDigests 0}}'

# 2. Timestamped backup (matches the existing .bak-* convention on this file):
cp docker-compose.yml "docker-compose.yml.bak-pin-$(date -u +%Y%m%dT%H%M%SZ)"

# 3. Edit line 49:
#      image: ghcr.io/berriai/litellm:main-latest
#    → image: ghcr.io/berriai/litellm@sha256:<digest from step 1>

# 4. Validate + apply (recreates only litellm):
docker compose config -q                      # GATE: no output, exit 0
docker compose up -d litellm

# 5. Verify identical bits + routes alive:
docker inspect ovid-gateway-litellm-1 --format '{{.Image}}'
#   → sha256:a69f5f0c… (== the image ID captured in step 1)
curl -sf http://127.0.0.1:4000/health/liveliness && echo ' LIVE'
curl -s -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/v1/models   # 200 or 401 = routing fine
```

**Rollback:** `cp docker-compose.yml.bak-pin-<TS> docker-compose.yml && docker compose up -d litellm`.

**Upgrading later (deliberate):** `docker pull ghcr.io/berriai/litellm:main-latest`
→ note the new `RepoDigests[0]` → repeat steps 2–5 with the new digest
→ smoke-test a chat completion; on trouble, roll back to the previous digest
(one-line edit — that is the point of pinning).

Same treatment is optional-but-recommended later for the other floating tags
in that compose file (`postgres:16-alpine`, `redis:7-alpine`, `caddy:2-alpine`)
and was already recommended by the 2026-10-11 review (top-10 fix #6).

- [ ] Decision: ☐ pin now ☐ pin in activation window ☐ defer · date · by
- [ ] Verified: step-5 image ID matches the pre-edit running image; liveliness OK.

---

## Spec §11 coverage map

| Spec §11 hardening item | Where | State (2026-10-16) |
|---|---|---|
| Disable root VNC/noVNC + vsftpd | item A | **owner pending** (services enabled+active, ports open) |
| Key-only SSH | item B | **owner pending — blocked: no keys installed** |
| Cloudflare `trusted_proxies` in Caddy | item D | **DONE — already live, verified identical to official list** |
| Container mem/cpu limits | `cloud/deploy/docker-compose.yml` (Task 11) | DONE for the cloud stack (gateway 1g/1cpu, worker 2g/2cpu, redis-q 1536m) |
| Log rotation | item E | **owner pending** (no daemon.json, uncapped) |
| Pinned images | item G | **owner pending** (litellm floating); cloud images are built from committed source |
| Healthchecks + uptime alerting | compose healthchecks (Task 11) + item F | healthchecks DONE for cloud stack; **external alerting owner pending** |
| Redis split (mint cache vs cloud queue) | `cloud/deploy/docker-compose.yml` (Task 11) | DONE (separate `redis-q`, `noeviction`, ovid-cloud network only) |

## Backup restore proof

`cloud/deploy/backup/README.md` §"Verification log" records the **passed
scratch-restore drill of 2026-10-16** (88 tables restored from the live
`litellm` dump into a disposable postgres:16-alpine). Re-run the drill after
the first timer-produced backup, then quarterly.

## Decision log (fill in as items are executed)

| Date | Item | Decision | Executed by | Gate output observed |
|---|---|---|---|---|
| 2026-10-16 | D | verified (no change needed) | Task-12 audit (read-only) | `comm` diff empty; Caddy v2.11.4; healthz 200 |
| | | | | |
