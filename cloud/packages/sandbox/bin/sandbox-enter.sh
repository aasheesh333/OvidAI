#!/bin/bash
# usage: sandbox-enter.sh <cgroup-procs-file> <uid> <gid> <nul-separated-argv-file>
set -euo pipefail
procs="$1"; uid="$2"; gid="$3"; argvfile="$4"
echo $$ > "$procs"                       # attach BEFORE dropping privileges (research §3)
args=(); while IFS= read -r -d '' a; do args+=("$a"); done < "$argvfile"
exec setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "${args[@]}"
