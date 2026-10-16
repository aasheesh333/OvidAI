# MECHANISM.md — Ovid sandbox host-mechanism decision record (P2 Task 1)

**Status: SKELETON — awaiting the owner-gated host run (plan Steps 3–4).**
**Host:** vm-mtx87lmp · **Filled by:** owner, from the probe log
**Probe:** `cloud/deploy/sandbox/sandbox-probe.sh` · **Branch-b artifact:** `cloud/deploy/sandbox/ovid-sandbox.apparmor`

## How to run the probe (owner-gated)

```bash
sudo bash cloud/deploy/sandbox/sandbox-probe.sh 2>&1 | \
  tee /tmp/ovid-probe-$(date -u +%Y%m%dT%H%M%S).log
```

Stop-condition (what the run may change on the host): installs `bubblewrap`
via apt if absent; only on branch b, installs + loads the `ovid-sandbox`
AppArmor profile. Both are production prerequisites and are left in place.
All other state (scratch dirs, probe cgroups, child uid maps) is removed by
the probe's S7 cleanup. Expected gate: exactly one branch passes; the log
shows `uid=0(root)` inside the uid-200000 jail, `uid_map` line
`0 200000 1`, and the `touch` file owned by 200000 on the host
(`stat -c %u`).

## Decision matrix (research §8.2, ordered — first passing branch wins)

| # | Branch | Mechanism | DECISION value | Prerequisites / notes |
|---|--------|-----------|----------------|-----------------------|
| a | Unprivileged bwrap as uid 200000 | worker (root) forks → `setuid(200000)` → exec bwrap `--unshare-user --uid 0` (inner 0 ↔ outer 200000) | `DECISION: setuid` | Expected to work on bare metal: the host `unprivileged_userns` profile allows `file rwlkm /**` and bare-metal /proc paths are connected (the disconnected-path denial in research §2.1 is a docker artifact). No host changes needed. |
| b | Same as (a), after loading an AppArmor profile for bwrap | as (a), plus profile granting `userns_create` for `/usr/bin/bwrap` | `DECISION: setuid` | Profile artifact: `cloud/deploy/sandbox/ovid-sandbox.apparmor`, installed at `/etc/apparmor.d/ovid-sandbox`, loaded via `apparmor_parser -r`. Modeled on the on-box `flatpak`/`podman` precedents (named, unconfined-flagged, `userns,` grant). Keeps the kernel restriction ON for everything else. Record the installed profile path + `aa-status` evidence below. |
| c | rootmap: worker stays root | root pre-unshares a userns and writes the child's uid_map `0 200000 1` (parent writes child's maps; see probe S4), then execs bwrap **without** `--unshare-user`, joining the pre-made userns via `--userns FD` (`--uid 0 --gid 0` still apply; bwrap requires `--unshare-user` or `--userns` for `--uid`) | `DECISION: rootmap` | Root-run bwrap is proven working (research config b). Task 7's launcher must implement the map-writer mechanics: fork → child `unshare(CLONE_NEWUSER)` → root parent writes uid_map/gid_map (+ setgroups deny) → child opens `/proc/self/ns/user` as FD → exec `bwrap --userns FD`. Record the mechanics observed in S4 below. |

### Avoid-list (NOT options, per research §8.2)

- **No `dpkg-statoverride` setuid bwrap** — setuid bwrap is a host-wide
  privilege escalation surface (any user could use it to remap uids).
- **No disabling `kernel.apparmor_restrict_unprivileged_userns`** — host-wide
  weakening of the AppArmor userns restriction for every unprivileged binary.

If **all** of a/b/c fail: STOP — escalate to the owner before any later task
(no plan fallback beyond research §8.2).

## Evidence (filled by the owner from the probe log)

### S0 — environment

- `uname -r`: _<pending>_
- `kernel.unprivileged_userns_clone`: _<pending>_
- `user.max_user_namespaces`: _<pending>_
- `kernel.apparmor_restrict_unprivileged_userns`: _<pending>_
- `aa-status` (head): _<pending>_
- cgroup fs type: _<pending>_

### S1 — bwrap

- bwrap version installed: _<pending>_ (candidate on this box: `0.9.0-1ubuntu0.3`)

### S2 — spec-shaped jail (root / uid 200000)

- Root run: rc / `id` output / `uid_map` / host owner of `probe`: _<pending>_
- uid-200000 run: rc / `id` output / `uid_map` / host owner of `probe`: _<pending>_
- dmesg AppArmor evidence on failure: _<pending>_

### S3 — branch b retry (only if S2-uid200000 failed)

- Profile installed at `/etc/apparmor.d/ovid-sandbox`: _<pending>_
- `aa-status` ovid-sandbox line: _<pending>_
- Retry result: _<pending>_

### S4 — branch c smoke (only if S3 also failed)

- Map-writer mechanics observed (what the Task 7 launcher must implement):
  _<pending>_
- Ownership proof (`stat -c %u` of the jail's `touch` = 200000): _<pending>_

### S5 — ctty sanity (bwrap `--new-session` on a pty)

- Output (`/dev/pts/N` line + `stty size`): _<pending>_
- Result: _<pending>_ (node-pty-specific confirmation lands in Task 9)

### S6 — cpu.max throttling (research open item)

- Capped iterations / uncapped iterations / ratio (expect ≈ 0.50): _<pending>_
- Result: _<pending>_

### Full log excerpt

_<pending — paste the tee'd log (or its path under /tmp/ovid-probe-*.log)>_

## Decision (filled ONLY by the owner's Step-4 run)

DECISION:
