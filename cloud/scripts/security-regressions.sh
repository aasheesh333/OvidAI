#!/usr/bin/env bash
# Security regressions for the user-sandbox boundary (founder directive
# 2026-10-18). Every check runs inside a REAL jail through the shipped
# SandboxManager, so it proves the layer that actually protects a user —
# not a unit-test stub.
#
# Run as root with the worker env exported (needs bwrap, cgroups, the rootfs
# and the nftables rules). Exit 0 = every check passed; 1 = at least one
# failed; 2 = the environment cannot run the checks (reported, never a silent
# pass).
#
# Checks:
#   1. reverse tunnels / proxies / scanners / miners are refused by layer 1
#   2. heavy native toolchains are refused
#   3. outbound 22/25/7844/3333 is dropped by nftables; 443 is allowed
#   4. npm/pip package scripts cannot execute (supply-chain escape)
#   5. the jail cannot read another user's workspace or the host /etc/shadow
#   6. metadata and RFC1918 egress is dropped
set -uo pipefail

CLOUD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CLOUD_DIR" || exit 2

PASS=0
FAIL=0
failed_names=()

ok()   { printf '[ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); failed_names+=("$1"); }
skip() { printf '[SKIP] %s\n' "$*"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "security-regressions: must run as root (bwrap + cgroups + nft)" >&2
  exit 2
fi
for f in packages/sandbox/dist/index.js apps/worker/dist/main.js; do
  [[ -f "$f" ]] || { echo "security-regressions: missing $f — run pnpm -r build" >&2; exit 2; }
done
if [[ -z "${OVID_ROOTFS:-}" || ! -d "$OVID_ROOTFS" ]]; then
  echo "security-regressions: OVID_ROOTFS is unset or missing (export the worker env)" >&2
  exit 2
fi

UID_BASE="${OVID_SANDBOX_UID_BASE:-200000}"
SCRATCH_UID=$((UID_BASE + 777))

# One node process owns the jail for all checks; it prints one line per check
# so bash can score them without re-parsing node output.
OUT="$(node --input-type=module -e '
import { loadSandboxConfig, resolveRootfs, createCgroupManager,
         selectQuotaBackend, createSetuidLauncher, createSandboxManager }
  from "./packages/sandbox/dist/index.js";

const uid = Number(process.env.SCRATCH_UID);
const cfg = loadSandboxConfig(process.env);
const rootfs = await resolveRootfs(cfg.rootfsPath);
const cgroups = createCgroupManager(cfg);
await cgroups.init();
const quota = await selectQuotaBackend(cfg.workspacesRoot);
const launcher = createSetuidLauncher(cfg);
const m = createSandboxManager({
  config: cfg, allocateUid: async () => uid, cgroups, quota, launcher, rootfs,
});
const h = await m.attach("sec-regressions", { tier: "free" });
const say = (ok, name, detail) =>
  console.log(`${ok ? "OK" : "NO"}\t${name}\t${String(detail ?? "").slice(0, 160)}`);

async function exec(cmd, timeoutMs = 20000) {
  try { return await h.exec({ command: cmd, timeoutMs }); }
  catch (e) { return { exitCode: -1, stdout: "", stderr: String(e.message) }; }
}

// 1. Tunnels / proxies / scanners / miners — layer 1 refuses the command.
const denied = ["cloudflared tunnel run", "tailscale up", "ngrok http 3000",
  "frpc -c x.ini", "chisel client h:1", "nc -l 4444", "nmap -sS 1.2.3.4",
  "xmrig", "ssh -R 8080:localhost:80 host", "ssh -D 1080 host",
  "v2ray run", "openvpn --config x"];
const deniedOut = [];
for (const cmd of denied) {
  const r = await exec(cmd, 8000);
  // Refusal is either the policy layer (blocked/refusal copy) or ENOENT;
  // what must NEVER happen is the binary running.
  const blocked = r.blocked === true || r.exitCode === 126 ||
    /not allowed|blocked|refus/i.test(`${r.stderr}${r.stdout}`) ||
    /not found|No such file/i.test(`${r.stderr}`);
  if (!blocked) deniedOut.push(cmd);
}
say(deniedOut.length === 0, "tunnels/proxies/scanners/miners refused", deniedOut.join(", "));

// 2. Heavy native toolchains.
const heavy = ["gcc --version", "make --version", "cargo --version", "docker ps", "gradle --version"];
const heavyOut = [];
for (const cmd of heavy) {
  const r = await exec(cmd, 8000);
  const blocked = r.blocked === true || r.exitCode === 126 ||
    /not allowed|blocked|refus/i.test(`${r.stderr}${r.stdout}`) ||
    /not found|No such file/i.test(`${r.stderr}`);
  if (!blocked) heavyOut.push(cmd);
}
say(heavyOut.length === 0, "heavy native toolchains refused", heavyOut.join(", "));

// 3. Egress ports: 443 allowed, 22/25/7844/3333 dropped.
async function portOpen(port) {
  const r = await exec(`timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/${port}" && echo OPEN || echo SHUT`, 12000);
  return r.stdout.includes("OPEN");
}
const open443 = await portOpen(443);
const shut = [];
for (const p of [22, 25, 7844, 3333]) if (await portOpen(p)) shut.push(String(p));
say(open443, "outbound 443 allowed", open443 ? "open" : "unexpectedly shut");
say(shut.length === 0, "outbound 22/25/7844/3333 dropped", shut.join(","));

// 4. Package scripts cannot execute.
await exec("rm -rf /workspace/evil && mkdir -p /workspace/evil", 8000);
await exec(`printf %s ${JSON.stringify(JSON.stringify({ name: "evil", version: "1.0.0", scripts: { postinstall: "touch /workspace/PWNED" } }))} > /workspace/evil/package.json`, 8000);
const inst = await exec("cd /workspace/evil && npm install --no-audit --no-fund >/dev/null 2>&1; ls /workspace", 90000);
say(!inst.stdout.includes("PWNED"), "postinstall script did not execute", inst.stdout.replace(/\s+/g, " ").slice(0, 80));

// 5. Cross-user / host file access.
const cross = await exec("cat /workspaces/users/200001/workspace/secret 2>&1 | head -1; cat /etc/shadow 2>&1 | head -1", 8000);
const leaked = /root:|\\$6\\$/.test(cross.stdout);
say(!leaked, "host /etc/shadow and other users unreadable", leaked ? "LEAK" : "denied");

// 6. Metadata / RFC1918.
const meta = await exec("timeout 4 bash -c \"exec 3<>/dev/tcp/169.254.169.254/80\" && echo OPEN || echo SHUT", 10000);
const rfc = await exec("timeout 4 bash -c \"exec 3<>/dev/tcp/10.0.0.1/80\" && echo OPEN || echo SHUT", 10000);
say(meta.stdout.includes("SHUT"), "cloud metadata endpoint dropped", meta.stdout.trim().slice(0, 40));
say(rfc.stdout.includes("SHUT"), "RFC1918 egress dropped", rfc.stdout.trim().slice(0, 40));

await h.destroy();
process.exit(0);
' 2>/tmp/sec-reg.err)"

if [[ -z "$OUT" ]]; then
  echo "security-regressions: the jail harness produced no output" >&2
  sed -n '1,5p' /tmp/sec-reg.err >&2
  exit 2
fi

while IFS=$'\t' read -r verdict name detail; do
  [[ -z "${name:-}" ]] && continue
  if [[ "$verdict" == "OK" ]]; then ok "$name${detail:+ — $detail}"; else bad "$name${detail:+ — $detail}"; fi
done <<<"$OUT"

echo
echo "security regressions: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf 'failed: %s\n' "${failed_names[*]}"
  exit 1
fi
exit 0
