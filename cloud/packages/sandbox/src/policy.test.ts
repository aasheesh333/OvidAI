import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  ALLOWED_COMMAND_CORPUS,
  BLOCKED_COMMAND_CORPUS,
  PATH_ESCAPE_CORPUS,
} from "./corpora.js";
import {
  CommandBlockedError,
  REFUSAL_MESSAGE,
  checkCommandPolicy,
  splitShellSegments,
} from "./policy.js";

// <cloud>/deploy/rootfs/shims, resolved from this file's location in src/
// (same computation as Task 3's shims.test.ts).
const SHIMS_DIR = fileURLToPath(new URL("../../../deploy/rootfs/shims", import.meta.url));

// Layer-1 must refuse the same nine heads the Task 3 rootfs shims refuse
// unconditionally (shims.test.ts pins the full 13-file contract).
const UNCONDITIONAL_SHIMS = [
  "gcc",
  "g++",
  "make",
  "gradle",
  "gradlew",
  "kotlinc",
  "javac",
  "sdkmanager",
  "ndk-build",
] as const;

// The three conditional shims carry the same copy for their blocked forms.
const CONDITIONAL_SHIMS = ["cargo", "docker", "flutter"] as const;

/** Runs a shim with the host `sh` (Task 3's portable harness pattern). */
function runShim(name: string, args: string[]): { status: number | null; stdout: string } {
  const r = spawnSync("sh", [join(SHIMS_DIR, name), ...args], {
    encoding: "utf8",
    timeout: 15_000,
  });
  if (r.error) throw r.error;
  return { status: r.status, stdout: r.stdout };
}

describe("corpus contract (shared with Tasks 12 and 15)", () => {
  it("BLOCKED has ≥ 35 entries, all classified, unique", () => {
    expect(BLOCKED_COMMAND_CORPUS.length).toBeGreaterThanOrEqual(35);
    expect(new Set(BLOCKED_COMMAND_CORPUS.map((e) => e.command)).size).toBe(
      BLOCKED_COMMAND_CORPUS.length,
    );
    for (const e of BLOCKED_COMMAND_CORPUS) {
      expect(["layer1", "shim"]).toContain(e.expect);
    }
  });

  it("at least one documented layer-1 boundary (shim) entry exists", () => {
    expect(BLOCKED_COMMAND_CORPUS.some((e) => e.expect === "shim")).toBe(true);
  });

  it("ALLOWED has ≥ 15 unique entries", () => {
    expect(ALLOWED_COMMAND_CORPUS.length).toBeGreaterThanOrEqual(15);
    expect(new Set(ALLOWED_COMMAND_CORPUS).size).toBe(ALLOWED_COMMAND_CORPUS.length);
  });

  it("no command is in both corpora", () => {
    const blocked = new Set(BLOCKED_COMMAND_CORPUS.map((e) => e.command));
    for (const c of ALLOWED_COMMAND_CORPUS) expect(blocked.has(c)).toBe(false);
  });

  it("PATH_ESCAPE has the six pinned entries plus extras, unique, non-empty", () => {
    expect(PATH_ESCAPE_CORPUS.length).toBeGreaterThanOrEqual(6);
    expect(new Set(PATH_ESCAPE_CORPUS).size).toBe(PATH_ESCAPE_CORPUS.length);
    for (const p of [
      "../../etc/passwd",
      "/etc/passwd",
      "/workspace/../../etc/shadow",
      "/workspaces/users/999999/x",
      "a/../../..",
      "",
    ]) {
      expect(PATH_ESCAPE_CORPUS).toContain(p);
    }
  });
});

describe("splitShellSegments", () => {
  it("preserves ; and operators inside quoted strings", () => {
    expect(splitShellSegments('echo "a; b && c"')).toEqual([["echo", "a; b && c"]]);
    expect(splitShellSegments("echo 'x | y; z'")).toEqual([["echo", "x | y; z"]]);
  });

  it("splits on every operator boundary", () => {
    expect(splitShellSegments("a; b")).toEqual([["a"], ["b"]]);
    expect(splitShellSegments("a && b")).toEqual([["a"], ["b"]]);
    expect(splitShellSegments("a || b")).toEqual([["a"], ["b"]]);
    expect(splitShellSegments("a | b")).toEqual([["a"], ["b"]]);
    expect(splitShellSegments("a & b")).toEqual([["a"], ["b"]]);
    expect(splitShellSegments("(a) (b)")).toEqual([["a"], ["b"]]);
    expect(splitShellSegments("a\nb")).toEqual([["a"], ["b"]]);
  });

  it("treats && as one boundary, not two & segments", () => {
    const segs = splitShellSegments("cd app && ./gradlew assembleRelease");
    expect(segs).toEqual([["cd", "app"], ["./gradlew", "assembleRelease"]]);
  });

  it("escapes keep operator characters inside words", () => {
    expect(splitShellSegments("echo a\\ b")).toEqual([["echo", "a b"]]);
    expect(splitShellSegments("echo \\; grep x")).toEqual([["echo", ";", "grep", "x"]]);
  });

  it("joins adjacent quoted fragments into one word", () => {
    expect(splitShellSegments('"g""cc" x.c')).toEqual([["gcc", "x.c"]]);
    expect(splitShellSegments("foo'bar'baz q")).toEqual([["foobarbaz", "q"]]);
  });

  it("here-doc body becomes its own segments", () => {
    const segs = splitShellSegments("sh <<'EOF'\ngradle build\nEOF\necho done");
    expect(segs).toEqual([["sh"], ["gradle", "build"], ["echo", "done"]]);
  });

  it("here-doc with <<- strips leading tabs from the delimiter line", () => {
    const segs = splitShellSegments("bash <<-X\n\tmake\n\tX\necho ok");
    expect(segs).toEqual([["bash"], ["make"], ["echo", "ok"]]);
  });

  it("unterminated here-doc: the body still becomes segments (F1 — a real shell executes it to EOF)", () => {
    expect(splitShellSegments("bash <<'EOF'\nmake")).toEqual([["bash"], ["make"]]);
    expect(splitShellSegments("cat <<'EOF'\necho hi")).toEqual([["cat"], ["echo", "hi"]]);
  });

  it("$( ) subshell content is parsed as segments", () => {
    const segs = splitShellSegments("echo $(gradle build)");
    expect(segs).toContainEqual(["gradle", "build"]);
  });

  it("command substitution output is approximated into the parent words", () => {
    // `eval "$(echo gradle) build"` must reach the checker as `gradle build`.
    const segs = splitShellSegments('eval "$(echo gradle) build"');
    expect(segs).toContainEqual(["eval", "gradle build"]);
  });

  it("single quotes are inert inside double quotes", () => {
    expect(splitShellSegments('node -e "console.log(\'hi\')"')).toEqual([
      ["node", "-e", "console.log('hi')"],
    ]);
  });
});

describe("checkCommandPolicy — BLOCKED corpus (Review Focus #1 positive half)", () => {
  for (const entry of BLOCKED_COMMAND_CORPUS) {
    if (entry.expect !== "layer1") continue;
    it(`blocks: ${JSON.stringify(entry.command)}`, () => {
      const v = checkCommandPolicy(entry.command);
      expect(v.allowed).toBe(false);
      if (!v.allowed) {
        expect(v.matched.length).toBeGreaterThan(0);
        expect(v.segment.length).toBeGreaterThan(0);
      }
    });
  }

  it("documents the layer-1 boundary: base64|sh is NOT caught by layer 1", () => {
    // The shim entries are refused by the Task 3 PATH shims (layer 2);
    // Task 15 proves that refusal in-jail. Layer 1 lets them through by
    // design — pinning this keeps the two layers' contracts distinct.
    for (const entry of BLOCKED_COMMAND_CORPUS) {
      if (entry.expect !== "shim") continue;
      expect(checkCommandPolicy(entry.command)).toEqual({ allowed: true });
    }
  });
});

describe("checkCommandPolicy — ALLOWED corpus (Review Focus #1 negative half)", () => {
  for (const command of ALLOWED_COMMAND_CORPUS) {
    it(`allows: ${JSON.stringify(command)}`, () => {
      expect(checkCommandPolicy(command)).toEqual({ allowed: true });
    });
  }
});

describe("checkCommandPolicy — pinned matching rules", () => {
  it("strips wrapper heads and VAR= assignments in any order", () => {
    expect(checkCommandPolicy("sudo make").allowed).toBe(false);
    expect(checkCommandPolicy("sudo nice nohup time make").allowed).toBe(false);
    expect(checkCommandPolicy("env CC=gcc make").allowed).toBe(false);
    expect(checkCommandPolicy("CC=gcc command make").allowed).toBe(false);
    expect(checkCommandPolicy("xargs make < list.txt").allowed).toBe(false);
  });

  it("matches the head word's basename, not its full path", () => {
    expect(checkCommandPolicy("/usr/bin/gcc x.c").allowed).toBe(false);
    expect(checkCommandPolicy("./gradlew assembleRelease").allowed).toBe(false);
    expect(checkCommandPolicy("bin/ndk-build").allowed).toBe(false);
  });

  it("descends into shell -c arguments (all five shells)", () => {
    for (const sh of ["bash", "sh", "zsh", "dash", "ksh"]) {
      expect(checkCommandPolicy(`${sh} -c 'gradle build'`).allowed).toBe(false);
    }
    expect(checkCommandPolicy("bash -lc 'make'").allowed).toBe(false);
  });

  it("descends into eval's joined words", () => {
    expect(checkCommandPolicy("eval make").allowed).toBe(false);
    expect(checkCommandPolicy('eval "javac" Hello.java').allowed).toBe(false);
  });

  it("blocks assembleDebug/assembleRelease as any word of a segment", () => {
    expect(checkCommandPolicy("python bot.py assembleDebug").allowed).toBe(false);
    expect(checkCommandPolicy("cat assembleRelease-notes").allowed).toBe(true);
  });

  it("applies the positional rules to flutter/cargo/docker only", () => {
    expect(checkCommandPolicy("flutter build apk").allowed).toBe(false);
    expect(checkCommandPolicy("flutter build appbundle --release").allowed).toBe(false);
    expect(checkCommandPolicy("flutter build ios").allowed).toBe(false);
    expect(checkCommandPolicy("cargo build --release").allowed).toBe(false);
    expect(checkCommandPolicy("docker build -t x .").allowed).toBe(false);
    // Pass-through forms the spec §7 explicitly allows.
    expect(checkCommandPolicy("flutter analyze").allowed).toBe(true);
    expect(checkCommandPolicy("cargo test").allowed).toBe(true);
    expect(checkCommandPolicy("docker ps").allowed).toBe(true);
  });

  it("blocks both fork-bomb forms", () => {
    expect(checkCommandPolicy(":(){ :|:& };:").allowed).toBe(false);
    expect(checkCommandPolicy("f(){ f | f & }; f").allowed).toBe(false);
    expect(checkCommandPolicy(":() { : | : & } ; :").allowed).toBe(false);
  });

  it("blocks unclosed here-doc bodies, allows the benign ones (F1)", () => {
    // Deleting the closing delimiter must not delete the body: the shell
    // feeds everything after the operator to the receiving command.
    expect(checkCommandPolicy("bash <<'EOF'\nmake").allowed).toBe(false);
    expect(checkCommandPolicy("sh <<EOF\ngcc x.c").allowed).toBe(false);
    expect(checkCommandPolicy("bash <<'EOF'\ngradle build").allowed).toBe(false);
    // A benign unclosed here-doc still passes the policy.
    expect(checkCommandPolicy("cat <<'EOF'\necho hi")).toEqual({ allowed: true });
  });

  it("unquoted substitution output does not land in head position (F2)", () => {
    // Assignment RHS: no word splitting — the output joins the pending word.
    expect(checkCommandPolicy("X=$(which make)")).toEqual({ allowed: true });
    expect(checkCommandPolicy('X="$(which make)"')).toEqual({ allowed: true });
    // But a fresh-word substitution still splices (output word-splits).
    expect(checkCommandPolicy("$(gradle build)").allowed).toBe(false);
    // And an argument substitution to a denylisted head stays blocked.
    expect(checkCommandPolicy("gcc $(echo -O2) x.c").allowed).toBe(false);
  });

  it("docker build is also matched at word[2] — docker image build (F3)", () => {
    expect(checkCommandPolicy("docker image build .").allowed).toBe(false);
    expect(checkCommandPolicy("docker image pull x")).toEqual({ allowed: true });
    expect(checkCommandPolicy("docker image rm x").allowed).toBe(true);
  });

  it("first match wins and reports the offending segment text", () => {
    const v = checkCommandPolicy("echo ok; gcc x.c");
    expect(v.allowed).toBe(false);
    if (!v.allowed) {
      expect(v.segment).toBe("gcc x.c");
      expect(v.matched).toBe("gcc");
    }
  });

  it("empty and whitespace-only commands are allowed", () => {
    expect(checkCommandPolicy("")).toEqual({ allowed: true });
    expect(checkCommandPolicy("   \n\t ")).toEqual({ allowed: true });
  });
});

describe("refusal copy parity with Task 3 shims (one source of truth)", () => {
  it.each(UNCONDITIONAL_SHIMS)("%s stdout is REFUSAL_MESSAGE byte-for-byte", (name) => {
    const r = runShim(name, []);
    // echo appends exactly one trailing newline — the full stdout is the
    // message plus that newline, byte-for-byte (shims.test.ts pins the same).
    expect(r.stdout).toBe(`${REFUSAL_MESSAGE}\n`);
  });

  it.each(UNCONDITIONAL_SHIMS)("%s file content carries the message verbatim", (name) => {
    expect(readFileSync(join(SHIMS_DIR, name), "utf8")).toContain(REFUSAL_MESSAGE);
  });

  it.each(CONDITIONAL_SHIMS)("%s file content contains the message", (name) => {
    expect(readFileSync(join(SHIMS_DIR, name), "utf8")).toContain(REFUSAL_MESSAGE);
  });

  it("conditional shims print the same copy for their blocked forms", () => {
    expect(runShim("cargo", ["build"]).stdout).toBe(`${REFUSAL_MESSAGE}\n`);
    expect(runShim("docker", ["build", "."]).stdout).toBe(`${REFUSAL_MESSAGE}\n`);
    expect(runShim("flutter", ["build", "apk"]).stdout).toBe(`${REFUSAL_MESSAGE}\n`);
  });
});

describe("CommandBlockedError", () => {
  it("carries the exact refusal copy and the matched rule", () => {
    const v = checkCommandPolicy("gradle build");
    expect(v.allowed).toBe(false);
    if (!v.allowed) {
      const err = new CommandBlockedError(REFUSAL_MESSAGE, v.matched);
      expect(err).toBeInstanceOf(Error);
      expect(err.refusal).toBe(REFUSAL_MESSAGE);
      expect(err.refusal).toBe(
        "Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead.",
      );
      expect(err.matched).toBe(v.matched);
      expect(err.name).toBe("CommandBlockedError");
    }
  });
});
