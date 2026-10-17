#!/usr/bin/env bash
# Creates the /workspaces XFS volume (project quotas for per-user workspace
# caps — Task 8's quota backend refuses anything else). OWNER-GATED: part of
# DEPLOY.md §11 step 3; a task agent NEVER runs this (it mutates the host:
# a sparse image file, an /etc/fstab line, a mount).
#
# Idempotent: every mutation is guarded — safe to re-run at any time.
#   OVID_WORKSPACES_SIZE_GB   optional — volume size in GB (default 32)
#   OVID_WORKSPACES_IMG       optional — image path (default
#                             /opt/ovid-workspaces.img)
#   OVID_WORKSPACES_MOUNT     optional — mount point (default /workspaces)
#
# Gates (the runbook's step-3 exit criteria):
#   stat -fc %T /workspaces  → xfs
#   mount | grep prjquota    → the volume, mounted with prjquota
set -euo pipefail

SIZE_GB="${OVID_WORKSPACES_SIZE_GB:-32}"
IMG="${OVID_WORKSPACES_IMG:-/opt/ovid-workspaces.img}"
MOUNT="${OVID_WORKSPACES_MOUNT:-/workspaces}"
FSTAB=/etc/fstab
FSTAB_LINE="$IMG $MOUNT xfs loop,defaults,prjquota,nofail 0 2"

die() { echo "setup-workspaces: $*" >&2; exit 1; }
log() { printf '[setup-workspaces] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (owner-gated — DEPLOY.md §11 step 3)"
for cmd in mkfs.xfs fallocate mount; do
  command -v "$cmd" >/dev/null 2>&1 ||
    die "required command not found: $cmd (apt-get install -y xfs-progs util-linux)"
done

# ── 1. Sparse image ─────────────────────────────────────────────────────────
# fallocate gives a real preallocated file (not punch-hole sparse): XFS on a
# loop file with project quotas needs the backing to exist, and a
# half-allocated image wedges at the worst possible time. A fresh
# filesystem is only made when the image is absent — an existing image is
# NEVER reformatted (that would destroy every user workspace).
if [ ! -f "$IMG" ]; then
  log "creating $IMG (${SIZE_GB}G)"
  fallocate -l "${SIZE_GB}G" "$IMG"
else
  log "image already exists: $IMG (left untouched)"
fi

# ── 2. Filesystem (only on a fresh image) ───────────────────────────────────
# blkid guard: refuse to mkfs over something that already looks like a
# filesystem — an existing image is NEVER reformatted.
if ! blkid -p "$IMG" >/dev/null 2>&1; then
  log "mkfs.xfs $IMG"
  mkfs.xfs "$IMG"
else
  log "image already holds a filesystem (left untouched)"
fi

# ── 3. fstab line ───────────────────────────────────────────────────────────
if grep -qF "$FSTAB_LINE" "$FSTAB"; then
  log "fstab line already present"
else
  # Idempotent append with a trailing guard: an fstab without a final
  # newline would glue our line onto the previous entry.
  if [ -n "$(tail -c1 "$FSTAB")" ]; then printf '\n' >> "$FSTAB"; fi
  echo "$FSTAB_LINE" >> "$FSTAB"
  log "fstab line appended"
fi

# ── 4. Mount ────────────────────────────────────────────────────────────────
if mountpoint -q "$MOUNT"; then
  log "$MOUNT already mounted"
else
  install -d -m 755 "$MOUNT"
  # nofail in the fstab line means a broken image never blocks boot; here we
  # are interactive — a failure must be loud.
  mount -a || die "mount -a failed — check $FSTAB and dmesg"
  log "mounted $IMG on $MOUNT"
fi

# ── 5. Users root ───────────────────────────────────────────────────────────
# OVID_WORKSPACES_ROOT (Task 2 default /workspaces/users) — the directory
# SandboxManager allocates per-uid workspaces under.
install -d -m 755 "$MOUNT/users"

# ── 6. Gates ────────────────────────────────────────────────────────────────
FSTYPE="$(stat -fc %T "$MOUNT")"
[ "$FSTYPE" = "xfs" ] || die "gate failed: stat -fc %T $MOUNT = '$FSTYPE', expected xfs"
mount | grep "$MOUNT" | grep -q prjquota ||
  die "gate failed: $MOUNT is mounted without prjquota — quota caps (Task 8) will not enforce"
log "gates OK: $MOUNT is xfs with prjquota"
log "done. Next: DEPLOY.md §11 step 4 (nft install)."
