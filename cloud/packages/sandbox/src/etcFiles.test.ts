import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
  renderEtcBundle,
  renderHomeDotfiles,
  writeEnvFiles,
  type EtcBundle,
} from "./etcFiles.js";

// The golden bundle (Task 5 brief): passwd carries root + nobody ONLY — a
// jail must not leak the host's user list; group mirrors it; hosts resolves
// localhost on both stacks; nsswitch keeps name resolution local-first.
const GOLDEN_BUNDLE: EtcBundle = {
  passwd: "root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n",
  group: "root:x:0:\nnogroup:x:65534:\n",
  hosts: "127.0.0.1 localhost\n::1 localhost\n",
  resolvConf: "nameserver 1.1.1.1\nnameserver 9.9.9.9\n",
  nsswitch: "passwd: files\ngroup: files\nhosts: files dns\n",
};

const tmpDirs: string[] = [];
afterAll(() => {
  for (const d of tmpDirs) rmSync(d, { recursive: true, force: true });
});

describe("renderEtcBundle", () => {
  it("golden: matches the brief's five files verbatim", () => {
    expect(renderEtcBundle({ dns: ["1.1.1.1", "9.9.9.9"] })).toEqual(GOLDEN_BUNDLE);
  });

  it("renders one nameserver line per dns entry, in order", () => {
    expect(renderEtcBundle({ dns: ["1.1.1.1"] }).resolvConf).toBe("nameserver 1.1.1.1\n");
    expect(renderEtcBundle({ dns: ["9.9.9.9", "1.1.1.1"] }).resolvConf).toBe(
      "nameserver 9.9.9.9\nnameserver 1.1.1.1\n",
    );
  });

  it("never renders the systemd-resolved stub 127.0.0.53", () => {
    expect(renderEtcBundle({ dns: ["1.1.1.1"] }).resolvConf).not.toContain("127.0.0.53");
    expect(renderEtcBundle({ dns: ["9.9.9.9", "8.8.8.8"] }).resolvConf).not.toContain(
      "127.0.0.53",
    );
    // And it refuses the stub outright rather than silently dropping it — a
    // jail pointed at loopback stub would get no DNS at all.
    expect(() => renderEtcBundle({ dns: ["127.0.0.53"] })).toThrow(/127\.0\.0\.53/);
    expect(() => renderEtcBundle({ dns: ["1.1.1.1", "127.0.0.53"] })).toThrow(
      /127\.0\.0\.53/,
    );
  });
});

describe("renderHomeDotfiles", () => {
  it("golden: pins pnpm's store dir and silences fund/audit noise", () => {
    expect(renderHomeDotfiles()).toEqual({
      npmrc: "store-dir=/root/.cache/pnpm-store\nfund=false\naudit=false\n",
    });
  });
});

describe("writeEnvFiles", () => {
  it("creates all five /etc files and ~/.npmrc (mkdir -p), 0644, owned by ownerUid", async () => {
    const base = mkdtempSync(join(tmpdir(), "ovid-etcfiles-"));
    tmpDirs.push(base);
    // Nested on purpose: proves mkdir -p, not plain mkdir.
    const etcDir = join(base, "sbx-1/etc");
    const homeDir = join(base, "sbx-1/home");
    const bundle = renderEtcBundle({ dns: ["1.1.1.1"] });
    const dotfiles = renderHomeDotfiles();

    // Portable variant of the chown assertion: current process uid.
    const ownerUid = process.getuid();
    await writeEnvFiles({ etcDir, homeDir, bundle, dotfiles, ownerUid });

    const expected: Array<[string, string]> = [
      [join(etcDir, "passwd"), bundle.passwd],
      [join(etcDir, "group"), bundle.group],
      [join(etcDir, "hosts"), bundle.hosts],
      [join(etcDir, "resolv.conf"), bundle.resolvConf],
      [join(etcDir, "nsswitch.conf"), bundle.nsswitch],
      [join(homeDir, ".npmrc"), dotfiles.npmrc],
    ];
    for (const [path, content] of expected) {
      expect(readFileSync(path, "utf8")).toBe(content);
      const st = statSync(path);
      expect(st.mode & 0o777).toBe(0o644);
      expect(st.uid).toBe(ownerUid);
    }
  });

  it("re-asserts 0644 when a file already exists with another mode", async () => {
    const base = mkdtempSync(join(tmpdir(), "ovid-etcfiles-mode-"));
    tmpDirs.push(base);
    const etcDir = join(base, "etc");
    const homeDir = join(base, "home");
    // Pre-create etc/resolv.conf as 0600 — writeEnvFiles must normalize it.
    const { mkdirSync, writeFileSync, chmodSync } = await import("node:fs");
    mkdirSync(etcDir, { recursive: true });
    const stale = join(etcDir, "resolv.conf");
    writeFileSync(stale, "nameserver 0.0.0.0\n");
    chmodSync(stale, 0o600);

    await writeEnvFiles({
      etcDir,
      homeDir,
      bundle: renderEtcBundle({ dns: ["1.1.1.1"] }),
      dotfiles: renderHomeDotfiles(),
      ownerUid: process.getuid(),
    });
    expect(statSync(stale).mode & 0o777).toBe(0o644);
    expect(readFileSync(stale, "utf8")).toBe("nameserver 1.1.1.1\n");
  });
});
