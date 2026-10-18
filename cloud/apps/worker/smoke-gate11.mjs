// Gate 11 functional smoke — real production sandbox chain.
// Mirrors apps/worker/src/main.ts's composition exactly (same config loader,
// rootfs resolver, cgroup manager, quota backend, setuid launcher), minus the
// DB: the uid allocator is pinned to a scratch uid inside the production
// 200000-209999 range.
//
// Run as root with /opt/ovid-cloud/worker.env exported.

import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import {
  createCgroupManager,
  createSandboxManager,
  createSetuidLauncher,
  loadSandboxConfig,
  resolveRootfs,
  selectQuotaBackend,
} from "@ovid/sandbox";

const UID = 200777;
const USER = "smoke-gate11";
const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? "[ok]  " : "[FAIL]"} ${name}${detail ? ` — ${detail}` : ""}`);
}

const cfg = loadSandboxConfig(process.env);
console.log(`config: launch=${cfg.launch} rootfs=${cfg.rootfsPath} workspaces=${cfg.workspacesRoot} cgroup=${cfg.cgroupRoot}/${cfg.cgroupBase}`);

const rootfs = await resolveRootfs(cfg.rootfsPath);
check("rootfs resolved", true, rootfs.path ?? String(rootfs));

const cgroups = createCgroupManager(cfg);
await cgroups.init();
check("cgroups init (leaf-first)", true, readFileSync(join(cfg.cgroupRoot, cfg.cgroupBase, "cgroup.subtree_control"), "utf8").trim());

const quota = await selectQuotaBackend(cfg.workspacesRoot);
const launcher = createSetuidLauncher(cfg);
const manager = createSandboxManager({
  config: cfg,
  allocateUid: async () => UID,
  cgroups,
  quota,
  launcher,
  rootfs,
});

const handle = await manager.attach(USER, { tier: "free" });
check("sandbox attached", true, `uid=${handle.uid} workspace=${handle.workspaceDir}`);

const idOut = await handle.exec({ command: "id -u; id -g", timeoutMs: 10_000 });
check("jail reports uid 0 / gid 0", idOut.exitCode === 0 && /^0\s*\n?0/m.test(idOut.stdout.trim()), JSON.stringify(idOut.stdout.trim()));

const echoOut = await handle.exec({ command: "echo gate11-ok", timeoutMs: 10_000 });
check("run_shell echo", echoOut.exitCode === 0 && echoOut.stdout.includes("gate11-ok"), JSON.stringify(echoOut.stdout.trim()));

const writeOut = await handle.exec({ command: "printf 'hello-gate11' > /workspace/probe.txt && cat /workspace/probe.txt", timeoutMs: 10_000 });
check("write_file in workspace", writeOut.exitCode === 0 && writeOut.stdout.includes("hello-gate11"), JSON.stringify(writeOut.stdout.trim()));
const hostOwner = statSync(join(handle.workspaceDir, "probe.txt")).uid;
check("host file owned by sandbox uid", hostOwner === UID, `uid=${hostOwner}`);

// cgroup limits actually applied on the env leaf
const leaf = join(cfg.cgroupRoot, cfg.cgroupBase, `sandbox-${UID}`);
const mem = readFileSync(join(leaf, "memory.max"), "utf8").trim();
const pids = readFileSync(join(leaf, "pids.max"), "utf8").trim();
const cpu = readFileSync(join(leaf, "cpu.max"), "utf8").trim();
check("memory.max applied", mem === String(cfg.limits.memoryMaxBytes), mem);
check("pids.max applied", pids === String(cfg.limits.pidsMax), pids);
check("cpu.max applied", cpu.length > 0, cpu);

// egress: metadata endpoint must be unreachable from the jail
const meta = await handle.exec({ command: "curl -m 3 -s -o /dev/null -w '%{http_code}' http://169.254.169.254/ || echo BLOCKED", timeoutMs: 10_000 });
check("metadata endpoint blocked", /BLOCKED|000/.test(meta.stdout), JSON.stringify(meta.stdout.trim()));

// egress: the host's own public IP must be blocked too
const own = await handle.exec({ command: `curl -m 3 -s -o /dev/null -w '%{http_code}' http://${cfg.publicIp ?? "148.113.44.36"}/ || echo BLOCKED`, timeoutMs: 10_000 });
check("own public IP blocked", /BLOCKED|000/.test(own.stdout), JSON.stringify(own.stdout.trim()));

// heavy-build blocker (gcc shim)
const gcc = await handle.exec({ command: "gcc --version", timeoutMs: 10_000 });
check("heavy build blocked (gcc refused)", gcc.exitCode !== 0, `exit=${gcc.exitCode} ${JSON.stringify((gcc.stderr || gcc.stdout).slice(0, 80))}`);

// PTY: open a terminal, run a command, read output
let ptyText = "";
const pty = await handle.createPty(
  { cols: 100, rows: 30, argv: ["/bin/sh"] },
  {
    onData: (chunk) => { ptyText += Buffer.from(chunk.data, "base64").toString(); },
    onExit: () => {},
  },
);
pty.write("echo PTY-GATE11\r");
await new Promise((r) => setTimeout(r, 1200));
pty.kill();
check("PTY opens and echoes", ptyText.includes("PTY-GATE11"), JSON.stringify(ptyText.slice(-120)));

await handle.destroy();
check("sandbox destroyed", manager.get(USER) === undefined, `active=${manager.activeCount()}`);

const failed = results.filter((r) => !r.ok);
console.log(`\nGATE 11 SMOKE: ${results.length - failed.length}/${results.length} checks passed`);
if (failed.length > 0) {
  console.log("FAILED: " + failed.map((f) => f.name).join(", "));
  process.exit(1);
}
execFileSync("true");
