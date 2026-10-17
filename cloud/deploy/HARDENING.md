# Ovid Cloud — Phase-0 hardening checklist (owner-facing)

Closes the spec §11 "VPS hardening (Phase 0)" items
(`docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md`) — Task 12
of the P0+P1 spine plan — plus **item H: the P2 sandbox surface** (worker on
host systemd, uid block, egress filter, cgroup caps — activation in
`DEPLOY.md` §11). Companion to `DEPLOY.md` (activation runbook): this
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
| sshd effective config | **Corrected at re-check 2026-10-16 15:17 UTC: `passwordauthentication yes`** (the original audit row wrongly said `no`). Cause — include order: `/etc/ssh/sshd_config` line 12 is `Include /etc/ssh/sshd_config.d/*.conf`; drop-ins are read in lexicographic filename order *before* the rest of the main file, and sshd uses the **first obtained value** for a contested keyword. Full drop-in enumeration: `50-cloud-init.conf` (`PasswordAuthentication yes` — **rewritten by cloud-init on every boot**; observed: boot 07:11:33 today, file mtime 07:11:44) sorts BEFORE `50-ovid-limits.conf` (`MaxAuthTries 4`, `LoginGraceTime 30`, `MaxStartups 10:30:60` — no password directive) and `60-cloudimg-settings.conf` (`PasswordAuthentication no` — **dead letter, loses the ordering**), so the effective value is `yes`. The main file's own `yes` lines (57/79/83) come after the Include and are likewise irrelevant. Plus `kbdinteractiveauthentication yes` + `usepam yes` ⇒ **password login is fully ON for root and every account**. `pubkeyauthentication yes`, `permitrootlogin yes`. Socket-activated (`ssh.socket` enabled). | `sudo sshd -T \| grep -Ei 'passwordauth\|kbdinteractive\|permitroot\|usepam\|pubkey'`; `ls -la /etc/ssh/sshd_config.d/`; `grep -rn -i passwordauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/` |
| SSH keys | At original audit (2026-10-16 early): `/root/.ssh/authorized_keys` was EMPTY (0 bytes). **Dated re-check 2026-10-16 15:17 UTC: file is 89 bytes / 1 line — one `ssh-ed25519` key, comment `migrate`, fingerprint `SHA256:I3UV3LF/wOmF95WGw9etXAj0481SWqKEmnpie7uN6Q8`, mtime 2026-10-16 11:30, perms 0600.** It is proven working: journal (last 24 h) shows 179 × `Accepted publickey for root` with exactly this fingerprint, all from a single source. **One `migrate` key ≠ all owner devices proven** — item B's per-device gate (step 2) remains mandatory. Password paths are also in active use: last 24 h = 11 × `Accepted password` (non-root `ubuntu`) + 4 × `Accepted keyboard-interactive/pam` (root and `ubuntu`), ~928 failed/invalid-user lines | `ls -la /root/.ssh/authorized_keys`; `wc -l /root/.ssh/authorized_keys`; `ssh-keygen -lf /root/.ssh/authorized_keys`; `journalctl -u ssh --since -24h --no-pager \| grep -c Accepted` |
| fail2ban | `active` + `enabled` (jails `sshd`, `vsftpd`, `recidive` per the 2026-10-11 review) | `systemctl is-active fail2ban; systemctl is-enabled fail2ban` |
| Docker logging | driver `json-file`, **`/etc/docker/daemon.json` does not exist** ⇒ no size cap (unbounded growth; a scratch container created 2026-10-16 got `LogConfig {"Type":"json-file","Config":{}}`). Current largest container log: 3.0 MB — small today, uncapped forever | `docker info --format '{{.LoggingDriver}}'; cat /etc/docker/daemon.json` |
| litellm image | `/opt/ovid-gateway/docker-compose.yml` line 49: `image: ghcr.io/berriai/litellm:main-latest` — **floating tag, UNPINNED**. Running `ovid-gateway-litellm-1` (Up 12 h): image `sha256:a69f5f0c56b868d2fdfce7abfb037fed947b70ede202047ffc19c14dc96ab90a`, built `2026-09-30T08:33:20Z`, RepoDigest `ghcr.io/berriai/litellm@sha256:a69f5f0c…` (on this box the digest string equals the image ID) | `docker inspect ovid-gateway-litellm-1 --format '{{.Config.Image}}'`; `docker inspect ghcr.io/berriai/litellm:main-latest --format '{{.Id}} {{.Created}} {{json .RepoDigests}}'` |
| Caddy trusted_proxies | **ALREADY PRESENT** in the live Caddyfile global `servers` block: `trusted_proxies static` with all 15 IPv4 + 7 IPv6 Cloudflare CIDRs + `client_ip_headers CF-Connecting-IP X-Forwarded-For`. Fetched `cloudflare.com/ips-v4` + `/ips-v6` on 2026-10-16 → **identical** (item D). Caddy v2.11.4 (`caddy:2-alpine` container, host network) | see item D |
| Public health | `https://api.ovidsi.com/healthz` → **HTTP 200** (0.55 s). `/cloud/v1/health` not yet routed (activation pending, `DEPLOY.md` §6) | `curl -sS -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/healthz` |
| Public-repo exposure | Repo was flipped PUBLIC; HEAD is clean (`git ls-files` shows no keystore / `google-services.json` / firebase JSONs) but per `docs/HARDENING_TRACKER.md`: **signing key + Firebase config must be treated as exposed and rotated; git-history purge still pending** | `git ls-files \| grep -Ei 'keystore\|\.jks\|google-services\|firebase'` |
| Server-side secret inventory (names only — values never leave the box) | `/opt/ovid-gateway/.env` (0600): `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_PASSWORD`, `UI_PASSWORD`, `OVID_PROBE_KEY`, … plus `firebase-admin.json`, `caddy/origin.key`, `account.env`, `.db-password` (all 0600). Cloud secrets do not exist yet — placeholders in `cloud/deploy/.env.example`, filled at activation into `/opt/ovid-cloud/repo/cloud/deploy/.env` (the compose `env_file: [.env]`; the host worker uses the separate `/opt/ovid-cloud/worker.env`) | `cut -d= -f1 /opt/ovid-gateway/.env` |

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

**Why.** Effective sshd today (re-checked 2026-10-16 15:17 UTC):
**`passwordauthentication yes`** — `/etc/ssh/sshd_config.d/50-cloud-init.conf`
(`PasswordAuthentication yes`, rewritten by cloud-init on every boot) sorts
BEFORE `60-cloudimg-settings.conf` (`no`) in the lexicographic `Include`, and
sshd uses the first obtained value, so the `no` never takes effect (full
explanation in the "Current state" row). Together with
`kbdinteractiveauthentication yes` + `usepam yes` ⇒ **password login is fully
ON for root and every account** (journal, last 24 h: 11 × `Accepted password`
for non-root `ubuntu` + 4 × `keyboard-interactive/pam` for root/`ubuntu`,
~928 failed/invalid attempts — internet-wide brute force is constant;
fail2ban mitigates but does not remove it). The 2026-10-11 review
records this as an accepted risk because the owner connects from a phone and
a PC with changing IPs; that decision pre-dates the sandbox-hosting plan and
needs explicit re-confirmation.

**Blocker history (updated at re-check 2026-10-16 15:17 UTC).** At the original
audit `/root/.ssh/authorized_keys` was **EMPTY (0 bytes)** — no working key
login. Since then the file contains **1 `ssh-ed25519` key, comment `migrate`,
fingerprint `SHA256:I3UV3LF/wOmF95WGw9etXAj0481SWqKEmnpie7uN6Q8`, installed
2026-10-16 11:30** (file mtime), and the journal proves it works (179 ×
`Accepted publickey for root` with exactly this fingerprint in the last 24 h,
single source). **The gate is unchanged:** one `migrate` key is not proof for
all owner devices, and until step 2 passes from EVERY device (phone included)
password auth **cannot** simply be switched off — that would lock the owner
out (this VPS has no out-of-band console). The key-first order below is
mandatory.

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

**Step 4 — flip sshd to key-only.**

**4a — enumerate every `PasswordAuthentication` source first (read-only):**

```bash
grep -rn -i passwordauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

Output observed on this box (2026-10-16 15:17 UTC):

```
/etc/ssh/sshd_config:57:PasswordAuthentication yes
/etc/ssh/sshd_config:79:PasswordAuthentication yes
/etc/ssh/sshd_config:83:PasswordAuthentication yes
/etc/ssh/sshd_config.d/50-cloud-init.conf:1:PasswordAuthentication yes
/etc/ssh/sshd_config.d/60-cloudimg-settings.conf:1:PasswordAuthentication no
```

**The include order decides the winner:** the main file's line 12 is
`Include /etc/ssh/sshd_config.d/*.conf`; drop-ins are read in lexicographic
filename order *before* the rest of the main file, and sshd uses the **first
obtained value** per keyword. That is why `50-cloud-init.conf` (`yes`)
currently beats `60-cloudimg-settings.conf` (`no`) and `sshd -T` reports
`passwordauthentication yes`. A new drop-in therefore **must sort BEFORE
`50-cloud-init.conf`** to win. No main-file edit is needed: its `yes` lines
come after the Include and lose to any drop-in value.

**4b — write the key-only drop-in named `45-ovid-keyonly.conf` (`45-` sorts
before `50-cloud-init.conf`):**

```bash
sudo tee /etc/ssh/sshd_config.d/45-ovid-keyonly.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
```

This file alone is the durable control: because it sorts first, its `no` is
the first obtained value — even after a reboot in which cloud-init rewrites
`50-cloud-init.conf` back to `yes`.

**4c — [OWNER CHOICE, gated] neutralize the competing `yes` in
`50-cloud-init.conf`** (belt-and-braces, so future 4a audits see no
contradiction). **Warning: cloud-init rewrites this file on EVERY boot**
(observed today: boot 07:11:33 → file rewritten 07:11:44), so choose with that
in mind:

- **Option A (durable, recommended): make cloud-init itself write `no`:**

  ```bash
  echo 'ssh_pwauth: false' | sudo tee /etc/cloud/cloud.cfg.d/99-ovid-no-pwauth.cfg
  ```

  Gate: takes effect at the **next boot / cloud-init run** — after the next
  reboot, verify `grep -rn -i passwordauthentication /etc/ssh/sshd_config.d/`
  shows `50-cloud-init.conf` with `no`. Until that reboot the file still says
  `yes`; that is harmless because 4b already wins the ordering.

- **Option B (immediate, NOT durable): documented in-place edit:**

  ```bash
  sudo sed -i.bak-ovid 's/^PasswordAuthentication yes/PasswordAuthentication no/' \
    /etc/ssh/sshd_config.d/50-cloud-init.conf
  ```

  Gate: the 4a grep now shows
  `50-cloud-init.conf:1:PasswordAuthentication no` immediately. **The next
  boot rewrites it back to `yes`** — the 4b drop-in keeps the effective value
  `no` regardless, but re-run 4a after every reboot, and prefer Option A if
  this box reboots unattended.

**4d — syntax gate + restart + immediate effective-config check:**

```bash
sudo sshd -t                      # GATE: no output = syntax OK. Any output: fix before continuing.
sudo systemctl restart ssh.service   # socket-activated: listener stays up, your open session survives
sudo sshd -T | grep -Ei 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
# → passwordauthentication no / kbdinteractiveauthentication no / permitrootlogin prohibit-password
```

(`PermitRootLogin prohibit-password` = root may log in **with keys only** —
exactly what step 2 proved. `PasswordAuthentication no` in the `45-` drop-in
genuinely takes effect because it is the *first obtained* value — unlike the
dead-letter `no` in `60-cloudimg-settings.conf`, which loses the ordering.)

**Step 5 — verify from a NEW session (old one still open):**

```bash
ssh -o PreferredAuthentications=publickey root@"<SERVER_IP>" 'echo KEY-LOGIN-OK'
# → KEY-LOGIN-OK
ssh -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no root@"<SERVER_IP>"
# → Permission denied (publickey).        ← password path is closed
sudo sshd -T | grep -Ei 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
# → passwordauthentication no / kbdinteractiveauthentication no / permitrootlogin prohibit-password
grep -rn -i passwordauthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
# → first drop-in hit is 45-ovid-keyonly.conf:1:PasswordAuthentication no (first obtained
#   value wins; any `yes` in 50-cloud-init.conf behind it is inert)
```

**Post-reboot re-check (mandatory, once, after the next reboot):** cloud-init
rewrites `50-cloud-init.conf` at boot. Re-run
`sudo sshd -T | grep -i passwordauthentication` → must still print `no` (the
`45-` drop-in survives reboots; with 4c Option A the file itself will also say
`no` from that boot onward).

**Rollback (from the open session only):**
`sudo rm /etc/ssh/sshd_config.d/45-ovid-keyonly.conf && sudo systemctl restart ssh.service`.
If 4c Option B was used, also restore the backup:
`sudo mv /etc/ssh/sshd_config.d/50-cloud-init.conf.bak-ovid /etc/ssh/sshd_config.d/50-cloud-init.conf && sudo systemctl restart ssh.service`.
If 4c Option A was used, remove the override (effective from the next boot):
`sudo rm /etc/cloud/cloud.cfg.d/99-ovid-no-pwauth.cfg`.

Notes: fail2ban + recidive should stay enabled (they now protect a
key-only port — cheap insurance). If item A is *not* done, also set
`ftpuser`'s shell to `/usr/sbin/nologin` (`sudo usermod -s /usr/sbin/nologin ftpuser`),
otherwise the FTP account keeps a password SSH path. Also note: the journal at
re-check time showed the non-root `ubuntu` account actively logging in **by
password** (11 × `Accepted password` in 24 h) — flipping to key-only closes
that path too, so give whatever uses it a key (steps 1–2 against
`ubuntu`'s `authorized_keys`) or knowingly accept the breakage before 4d.

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
| `REDIS_Q_PASSWORD` (cloud) | `/opt/ovid-cloud/repo/cloud/deploy/.env` at activation | **generate fresh at activation; never reuse an exposed value** | none (pre-launch) |
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

**On-box layer (P10 Task 11):** `@ovid/watch`
(`cloud/apps/watch`, units + runbook in
`cloud/deploy/monitoring/MONITORING.md`) covers queue depth, worker lag,
disk, redis memory and spend parity, alerting through mint's existing
Telegram bot. It is complementary, not an external substitute: UptimeRobot
stays the layer that reports a whole-VPS or network outage. Install both.

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

## H. Sandbox surface (P2) — verification rows for untrusted-code hosting

**Why.** P2 moves the worker onto the host (`ovid-worker.service`, systemd —
`DEPLOY.md` §11) to run user agent sessions inside bwrap jails. That makes
this box a multi-tenant code-execution host: the isolation stack (uid block,
RO rootfs, cgroup caps, nftables egress filter, AppArmor mechanism state)
is now part of the attack surface, and each row below is the recurring
verification for one layer. Artifacts: `cloud/deploy/systemd/` (slice +
worker unit), `cloud/deploy/net/install-nft.sh`, `cloud/deploy/rootfs/`,
`cloud/deploy/sandbox/` (probe + `MECHANISM.md` decision record), compose
loopback proxies. Activation is owner-run and ordered: `DEPLOY.md` §11.

**H1 — sandbox uid block 200000–209999 stays reserved for jails only.**
Sandbox uids are `200000 + slot` (spec §11); no human/system account may
share the block or it inherits the block's egress rules and quota limits.

```bash
awk -F: '$3>=200000 && $3<=209999 {print}' /etc/passwd
# → NO output (empty). Re-run after ANY useradd tooling change on this box.
```

**H2 — AppArmor mechanism state (mirror of `MECHANISM.md` DECISION).**
The jail launcher runs bwrap as a sandbox uid (branch a `setuid`, the
default) — or branch b (profile granted `userns_create`) if that is what the
owner's probe decided. The kernel restriction itself **stays ON, always**:
disabling `kernel.apparmor_restrict_unprivileged_userns` is on the
MECHANISM.md avoid-list — it weakens the whole host, not just bwrap.

```bash
# branch b only (if MECHANISM.md DECISION says so):
aa-status | grep ovid-sandbox          # → ovid-sandbox profile loaded
# ALWAYS (branch a or b):
sysctl kernel.apparmor_restrict_unprivileged_userns   # → 1 (never disable it)
```

**H3 — nft egress table `ovid_sandbox`.** Rendered by `install-nft.sh`
(keyed to the same uid range the sandbox config validates). The rendered
output for a given env is deterministic — verify against the golden render
(Task 15 §7 egress drift check, `OVID_PUBLIC_IP=203.0.113.7` fixture).

```bash
nft list table inet ovid_sandbox        # → matches the rendered golden
# monthly counter review: nonzero drop counters are EXPECTED (the internet
# probes constantly); growth after quiet periods is a signal worth a look.
nft list ruleset | grep -A2 counter
```

**H4 — worker runs as root inside `ovid-sandboxes.slice` (review item).**
Rationale (research §8.1): pre-setuid cgroup.procs attach (a non-root
parent cannot move a then-root child into the leaf cgroup), `/workspaces`
binds, nftables adjacency. Review trigger: the de-rooting path is the
research §3 TEST C `Delegate=yes` + leaf-first pattern — if the kernel
proves delegate-based attach for an unprivileged worker, file the change
(Delegate=yes on the unit, root dropped, launcher updated) as a P-followup.
Until then: root worker, 4G unit cap, 10G slice — the slice is what
protects the box.

```bash
systemctl show ovid-worker -p User,MemoryMax     # → User=root, MemoryMax=4294967296
systemctl show ovid-sandboxes.slice -p CPUQuotaPerSecUSec,MemoryMax   # → 6s, 10737418240
```

**H5 — loopback proxies 5434/6391/6392 stay loopback-only.** The host
worker's only path to the live stack's postgres/mint-redis and the queue
redis; each backend requires its own password (postgres / live
`REDIS_PASSWORD` / `REDIS_Q_PASSWORD`) — the socat relays terminate nothing.

```bash
ss -tlnp | grep -E '5434|6391|6392'      # → every bind is 127.0.0.1:…
                                         #   (any 0.0.0.0/[::] bind here is a defect)
```

**H6 — `/workspaces` budget.** 32 G volume (XFS, project quotas) holding
per-user workspaces + the warm-sandbox cache (`OVID_MAX_WARM_GB`, default
8 G). Alert at 80 % — wire the threshold into whatever external pinger
item F installed; the volume filling also starves new sandboxes
(`minFreeGb` gate).

```bash
df -h /workspaces        # → alert if ≥ 80% Use%; tune OVID_MAX_WARM_GB in
                         #   /opt/ovid-cloud/worker.env (restart ovid-worker) to
                         #   trade warm-start latency for space
```

**H7 — rootfs rebuild cadence.** Monthly, or on a CVE scan hitting the
pinned toolchain (`versions.env`): `build.sh` → `install.sh` (atomic
`current` symlink flip, 2 revisions kept, smoke-jail gate runs inside) —
instant rollback by re-pointing `current`. Current artifact revision:
`ubuntu-noble-min-20261017-r2` (Task 10).

```bash
readlink /opt/ovid-rootfs/current   # → ubuntu-noble-min-20261017-r2 (or newer)
ls -1d /opt/ovid-rootfs/ubuntu-noble-min-*   # → exactly 2 revisions
```

**H8 — per-env caps reference (what a jail gets — spec §7.3).**

| Control | Value | Set by |
|---|---|---|
| `cpu.max` | `100000 100000` (1 core) | `OVID_SANDBOX_CPU_MAX` |
| `memory.max` | `536870912` (512 MiB) | `OVID_SANDBOX_MEMORY_MAX_MB` |
| `memory.swap.max` | `0` | `OVID_SANDBOX_SWAP_MAX_MB` |
| `pids.max` | `64` | `OVID_SANDBOX_PIDS_MAX` |
| slice (parent) | `CPUQuota=600%`, `MemoryMax=10G`, `MemorySwapMax=0` | `ovid-sandboxes.slice` |
| worker unit (inside slice) | `MemoryMax=4096M` — worker ~2G + P6 browser pool ~2G | `ovid-worker.service` (G5) |
| workspace quota | 500 MB (Pro 2048 MB) + agent store 2048 MB | XFS project quotas (`Task 8`) |
| concurrency | `OVID_MAX_ACTIVE_SANDBOXES=24` | `worker.env` |

```bash
# spot-check a live jail (uid NNNNN): find its leaf and dump the caps
cat /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/sandbox-*/cpu.max 2>/dev/null | sort -u
# → 100000 100000 (plus the same shape for memory.max/…)
```

- [ ] Verified at P2 activation (§11 step 8): H1 empty, H2 state matches
      MECHANISM.md DECISION, H3 table matches golden, H4 caps as tabled,
      H5 loopback-only, H6 under 80 %, H7 two revisions · date · by
- [ ] Recurring review (monthly): H3 counters, H6 budget, H7 rebuild
      cadence — next: date · by

---

## Spec §11 coverage map

| Spec §11 hardening item | Where | State (2026-10-16) |
|---|---|---|
| Disable root VNC/noVNC + vsftpd | item A | **owner pending** (services enabled+active, ports open) |
| Key-only SSH | item B | **owner pending — per-device key-proof gate open** (1 `migrate` ed25519 key installed 2026-10-16 11:30, proven from a single source; step 2 must still pass on EVERY owner device; effective sshd is `passwordauthentication yes` today — see item B step 4 for the include-order fix) |
| Cloudflare `trusted_proxies` in Caddy | item D | **DONE — already live, verified identical to official list** |
| Container mem/cpu limits | `cloud/deploy/docker-compose.yml` (Task 11) | DONE for the compose stack (gateway 1g/1cpu, redis-q 1536m, net-proxy-pg/mint 128m/0.5cpu); the WORKER left compose in P2 — its caps are host cgroup: unit 4G inside the 10G `ovid-sandboxes.slice` (item H) |
| Log rotation | item E | **owner pending** (no daemon.json, uncapped) |
| Pinned images | item G | **owner pending** (litellm floating); cloud images are built from committed source; P2 pinned `alpine/socat:1.8.1.3` (digest in compose comment) |
| Healthchecks + uptime alerting | compose healthchecks (Task 11) + item F | healthchecks DONE for cloud stack; **external alerting owner pending** |
| Redis split (mint cache vs cloud queue) | `cloud/deploy/docker-compose.yml` (Task 11) | DONE (separate `redis-q`, `noeviction`, ovid-cloud network only) |
| P2 jail + uid block + RO rootfs | Tasks 5/7/8 + item H | artifacts DONE (shims, minimal /etc, rootfs pipeline, uid allocation); **activation owner-gated** — `DEPLOY.md` §11 |
| P2 egress filter (nftables) | Task 11 + item H | artifacts DONE (renderer + golden, `install-nft.sh`, netns proof passed); **live load owner-gated** — `DEPLOY.md` §11 step 4 |
| P2 cgroup caps + capacity envelope | Task 6 + item H | artifacts DONE (leaf-first bootstrap, per-env caps, 24-slot ring); slice + unit activation owner-gated — `DEPLOY.md` §11 steps 5/7 |
| P2 no host /proc view | Task 15 §5 + item H | isolation-verification suite gates it (jails see a fresh `--proc`, not the host's); run the suite on the host at activation |

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
