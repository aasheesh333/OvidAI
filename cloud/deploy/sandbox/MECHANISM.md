# MECHANISM.md — Ovid sandbox host-mechanism decision record (P2 Task 1)

**Status: DECIDED — probe run 2026-10-18 on this host.**
**Host:** vm-mtx87lmp · **Filled by:** controller from the probe log
(`/tmp/ovid-probe-final2.log`), owner-authorized run.
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

- `uname -r`: `6.8.0-136-generic`
- `kernel.unprivileged_userns_clone`: `1`
- `user.max_user_namespaces`: `93703`
- `kernel.apparmor_restrict_unprivileged_userns`: `1`
- `aa-status` (head): module loaded, **119 profiles loaded, 24 in enforce**
  (`/usr/bin/man`, `/usr/lib/snapd/snap-confine`, …)
- cgroup fs type: `cgroup2fs`
- cgroup root `subtree_control`: `cpuset cpu io memory hugetlb pids rdma misc`

### S1 — bwrap

- bwrap: `/usr/bin/bwrap` **0.9.0-1ubuntu0.3** (already installed; not added
  by this run)

### S2 — spec-shaped jail (root / uid 200000)

- Root run: **rc=0**, `uid=0 gid=0 groups=0`, `uid_map` = `0 0 1`,
  host owner of `probe` = **0**
- uid-200000 run: **rc=0**, `uid=0 gid=0 groups=0`, `uid_map` =
  **`0 200000 1`**, host owner of `probe` = **200000**
- dmesg AppArmor evidence: **none** — the branch-a run produced no denial.

### S3 — branch b retry (not taken)

Branch a passed, so the AppArmor profile was not installed. `aa-status` shows
no `ovid-sandbox` profile loaded.

### S4 — branch c smoke (not taken)

Branch a passed, so the rootmap map-writer was not exercised.

### S5 — ctty sanity (bwrap `--new-session` on a pty)

- Output: `tty` → `/dev/console`; `stty size` → **`24 80`**
- Result: **PASS**. The jail uses `--dev /dev` (a minimal devtmpfs), so the
  pty slave node is not visible inside it and the controlling terminal
  resolves to `/dev/console`; the load-bearing evidence is `stty size`
  returning the geometry set on the probe's pty. Node-pty-specific
  confirmation still lands in Task 9.
- Probe bug found and fixed by this run: the assertion demanded `/dev/pts/N`
  (unreachable with `--dev /dev`) and did not strip the pty's CRLF.

### S6 — cpu.max throttling (research open item)

- Capped 794 / uncapped 1633 iterations → **ratio 0.49** (expected ≈ 0.50)
- `cpu.max` after run: `50000 100000`
- Result: **PASS**

### Probe defects found and fixed by this run

The first run failed **all three branches** with
`bwrap: execvp /bin/sh: No such file or directory`. The cause was the probe,
not the host: Ubuntu 24.04 is usrmerge, so `/bin`, `/sbin`, `/lib` and
`/lib64` are symlinks into `/usr`, and `--ro-bind /bin /bin` does not
reconstruct them. The probe now binds `/usr` and recreates the four symlinks
(`--symlink usr/bin /bin`, …). Production is unaffected: the real invocation
binds a complete rootfs at `/` (`packages/sandbox/src/invocation.ts:71`).

### Full log

`/tmp/ovid-probe-final2.log` (the earlier failed run:
`/tmp/ovid-probe-20261018T061341.log`).

## Decision (from the owner-authorized Step-4 run, 2026-10-18)

DECISION: **setuid** (branch a — unprivileged bwrap as uid 200000, no
AppArmor profile, no rootmap). `OVID_SANDBOX_LAUNCH=setuid` is the correct
production value on this host; the branch-b profile and the branch-c launcher
are NOT needed.
