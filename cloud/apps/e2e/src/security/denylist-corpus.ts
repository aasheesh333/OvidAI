/**
 * P10 Task 8 — command-policy denylist corpus (spec §7), promoted from P2's
 * Task 4 corpora into the permanent security suite.
 *
 * Every §7 blocked command is crossed with the invocation forms an agent can
 * actually produce. Two layers are represented:
 *
 * - `expect: "layer1"` — P2's string-level interceptor
 *   (`checkCommandPolicy`) must refuse it with the exact §7 copy. This half
 *   runs on ANY host (no bwrap/cgroups needed) and is never skipped.
 * - `expect: "layer2"` — a documented layer-1 boundary: variable indirection
 *   (`G=gradle; $G build`) and base64 (`echo … | base64 -d | sh`) are not
 *   statically decidable, so only the rootfs PATH shims stop them. These
 *   entries are asserted ALLOWED at layer 1 and exercised in-jail by the
 *   gated execution test.
 *
 * `./gradlew` and the bare Gradle task words are layer-1-only: layer 2 is a
 * PATH shim, and `./gradlew` is a path, not a PATH lookup. The shim roster
 * cannot intercept a project-local wrapper (P2's proven design; the
 * interceptor is the defense for tool calls, the shim for interactive
 * terminals).
 *
 * `classifyCommand` is the Task 8 adapter over P2's landed
 * `checkCommandPolicy`: same verdict, with the exact refusal copy attached
 * (the plan's `{ allowed, refusal? }` shape).
 */

import { checkCommandPolicy, REFUSAL_MESSAGE } from "@ovid/sandbox";

export type InvocationForm =
  | "direct"
  | "bash-c"
  | "sh-lc"
  | "subshell"
  | "chain"
  | "pipe"
  | "env-indirection"
  | "base64"
  | "path-qualified";

export interface DenylistCase {
  /** Stable id (`<base-id>/<form>`). */
  id: string;
  /** The §7 base command being invoked. */
  base: string;
  form: InvocationForm;
  /** The literal command string handed to the interceptor / jail. */
  command: string;
  /** Which defense layer is expected to catch it. */
  expect: "layer1" | "layer2";
  /** Whether this case is meaningful as an in-jail execution case. */
  execution: boolean;
  /**
   * For execution cases: the command written into the jail script. Defaults
   * to `command`; path-qualified execution uses the real shim path
   * (`/usr/local/bin/<head>`) rather than the layer-1 `/usr/bin/<head>`
   * string.
   */
  executionCommand?: string;
}

/** POSIX single-quote a word (safe inside `bash -c '…'` / `sh -lc '…'`). */
function shSingle(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function b64(s: string): string {
  return Buffer.from(s, "utf8").toString("base64");
}

interface BaseSpec {
  id: string;
  command: string;
  /** PATH shim name (head word) when this is a runnable blocked command. */
  head?: string;
  /** Layer-2 execution is meaningful (a PATH shim exists for this form). */
  execution: boolean;
}

const BASES: BaseSpec[] = [
  // Spec §7 direct forms.
  { id: "gradle-build", command: "gradle build", head: "gradle", execution: true },
  { id: "gradle-assembleDebug", command: "gradle assembleDebug", head: "gradle", execution: true },
  { id: "gradlew-assembleDebug", command: "./gradlew assembleDebug", execution: false },
  { id: "gradlew-assembleRelease", command: "./gradlew assembleRelease", execution: false },
  { id: "assembleDebug", command: "assembleDebug", execution: false },
  { id: "assembleRelease", command: "assembleRelease", execution: false },
  { id: "flutter-build-apk", command: "flutter build apk", head: "flutter", execution: true },
  {
    id: "flutter-build-appbundle",
    command: "flutter build appbundle",
    head: "flutter",
    execution: true,
  },
  { id: "flutter-build-ios", command: "flutter build ios", head: "flutter", execution: true },
  { id: "kotlinc", command: "kotlinc Main.kt", head: "kotlinc", execution: true },
  { id: "javac", command: "javac Hello.java", head: "javac", execution: true },
  { id: "cargo-build", command: "cargo build", head: "cargo", execution: true },
  { id: "gcc", command: "gcc hello.c", head: "gcc", execution: true },
  { id: "gpp", command: "g++ hello.cpp", head: "g++", execution: true },
  { id: "make", command: "make", head: "make", execution: true },
  { id: "docker-build", command: "docker build .", head: "docker", execution: true },
  { id: "sdkmanager", command: "sdkmanager --list", head: "sdkmanager", execution: true },
  { id: "ndk-build", command: "ndk-build", head: "ndk-build", execution: true },
];

/** Spec §7 fork bombs + three general-shape variants. */
const FORK_BOMBS = [
  ":(){ :|:& };:",
  "f(){ f|f& }; f",
  "bomb(){ bomb | bomb & }; bomb",
  "x(){ x|x& };x",
] as const;

/** Layer-1 forms every base is crossed with (the plan's invocation matrix). */
const LAYER1_FORMS: InvocationForm[] = [
  "direct",
  "bash-c",
  "sh-lc",
  "subshell",
  "chain",
  "pipe",
  "path-qualified",
];

function commandFor(form: InvocationForm, base: string, head?: string): string {
  switch (form) {
    case "direct":
      return base;
    case "bash-c":
      return `bash -c ${shSingle(base)}`;
    case "sh-lc":
      return `sh -lc ${shSingle(base)}`;
    case "subshell":
      return `( ${base} )`;
    case "chain":
      return `true && ${base}`;
    case "pipe":
      return `echo x | ${base}`;
    case "path-qualified":
      // Layer 1 matches on the basename, so the conventional /usr/bin path
      // proves path-qualification does not evade the denylist.
      if (head !== undefined) return base.replace(head, `/usr/bin/${head}`);
      // ./gradlew has no head binary; qualify the wrapper name itself.
      return base.replace(/^\.\//, "/usr/bin/");
    case "env-indirection":
      return `G=${shSingle(base)}; $G`;
    case "base64":
      return `echo ${b64(base)} | base64 -d | sh`;
  }
}

function executionCommandFor(form: InvocationForm, base: string, head?: string): string {
  if (form === "path-qualified" && head !== undefined) {
    // Inside the jail the shim lives in /usr/local/bin (first on PATH).
    return base.replace(head, `/usr/local/bin/${head}`);
  }
  return commandFor(form, base, head);
}

function buildCorpus(): DenylistCase[] {
  const cases: DenylistCase[] = [];

  for (const spec of BASES) {
    for (const form of LAYER1_FORMS) {
      cases.push({
        id: `${spec.id}/${form}`,
        base: spec.command,
        form,
        command: commandFor(form, spec.command, spec.head),
        expect: "layer1",
        execution: spec.execution,
        ...(spec.execution
          ? { executionCommand: executionCommandFor(form, spec.command, spec.head) }
          : {}),
      });
    }
    // Documented layer-1 boundaries (only meaningful for runnable shims).
    if (spec.execution) {
      for (const form of ["env-indirection", "base64"] as const) {
        cases.push({
          id: `${spec.id}/${form}`,
          base: spec.command,
          form,
          command: commandFor(form, spec.command, spec.head),
          expect: "layer2",
          execution: true,
          executionCommand: executionCommandFor(form, spec.command, spec.head),
        });
      }
    }
  }

  for (const bomb of FORK_BOMBS) {
    // Fork bombs are raw-text matches; path qualification is meaningless and
    // the in-jail containment proof lives in the pids.max group.
    for (const form of [
      "direct",
      "bash-c",
      "sh-lc",
      "subshell",
      "chain",
      "pipe",
    ] as const) {
      cases.push({
        id: `fork-bomb-${FORK_BOMBS.indexOf(bomb)}/${form}`,
        base: bomb,
        form,
        command: commandFor(form, bomb),
        expect: "layer1",
        execution: false,
      });
    }
  }

  return cases;
}

/** The full matrix, generated deterministically at module load. */
export const DENYLIST_CORPUS: readonly DenylistCase[] = buildCorpus();

/** Layer-1 cases (must be refused by `classifyCommand`). */
export const LAYER1_DENYLIST_CORPUS: readonly DenylistCase[] = DENYLIST_CORPUS.filter(
  (c) => c.expect === "layer1",
);

/** Documented layer-1 boundaries (refused only by the in-jail shims). */
export const LAYER2_DENYLIST_CORPUS: readonly DenylistCase[] = DENYLIST_CORPUS.filter(
  (c) => c.expect === "layer2",
);

/** In-jail execution cases (PATH shims + interceptor on the exec path). */
export const EXECUTION_DENYLIST_CORPUS: readonly DenylistCase[] = DENYLIST_CORPUS.filter(
  (c) => c.execution,
);

/**
 * Spec §7 "Allowed" set — none of these may be blocked at any layer. The
 * first seven are pinned by the P10 Task 8 brief; the rest cover the P2
 * allowlist's highest-risk neighbours.
 */
export const ALLOWED_DENYLIST_CORPUS: readonly string[] = [
  "node -e",
  "python3 -V",
  "pnpm --version",
  "uv --version",
  "git --version",
  "echo",
  "cat",
  'node -e "console.log(\'hi\')"',
  "python3 x.py",
  "pnpm install",
  "cargo test",
  "cargo --version",
  "docker ps",
  "flutter analyze",
  "flutter test",
  "cat makefile",
  'echo "gcc is great"',
];

/**
 * Task 8 adapter over P2's landed interceptor. The exact §7 refusal copy is
 * attached here so callers (and the plan's `classifyCommand` contract) get
 * one shape regardless of P2's internal verdict type.
 */
export function classifyCommand(command: string): {
  allowed: boolean;
  refusal?: string;
  matched?: string;
} {
  const verdict = checkCommandPolicy(command);
  if (verdict.allowed) return { allowed: true };
  return {
    allowed: false,
    refusal: REFUSAL_MESSAGE,
    matched: verdict.matched,
  };
}
