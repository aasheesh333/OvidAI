/**
 * Shared command-policy corpora (P2 Task 4).
 *
 * ONE source of truth, consumed by:
 * - Task 4: `policy.test.ts` (the layer-1 unit tests below),
 * - Task 12: run_shell tool tests (blocked content === REFUSAL_MESSAGE),
 * - Task 15: in-jail acceptance (the "shim" entries prove the layer-2
 *   PATH shims refuse inside the jail).
 *
 * The BLOCKED corpus must cover every spec §7 blocked form plus the
 * Review Focus #1 evasion shapes; the ALLOWED corpus every spec §7
 * "Allowed" form. Do not edit individual entries without reconciling
 * all three consumers.
 */

export interface BlockedCorpusEntry {
  command: string;
  /**
   * "layer1" = the pre-parse interceptor (checkCommandPolicy) must refuse.
   * "shim" = a documented layer-1 boundary: the command is only caught by
   * the Task 3 PATH shims (layer 2), e.g. `base64 -d | sh`; Task 15 proves
   * the shim refusal in-jail.
   */
  expect: "layer1" | "shim";
}

/** Spec §7 blocked forms + Review Focus #1 evasions (≥ 25 entries). */
export const BLOCKED_COMMAND_CORPUS: BlockedCorpusEntry[] = [
  // Spec §7 denylist, direct forms.
  { command: "gradle build", expect: "layer1" },
  { command: "gradle assembleDebug", expect: "layer1" },
  { command: "./gradlew assembleRelease", expect: "layer1" },
  { command: "./gradlew assembleDebug", expect: "layer1" },
  { command: "kotlinc Main.kt", expect: "layer1" },
  { command: "javac Hello.java", expect: "layer1" },
  { command: "gcc hello.c", expect: "layer1" },
  { command: "g++ hello.cpp", expect: "layer1" },
  { command: "make", expect: "layer1" },
  { command: "make -j4", expect: "layer1" },
  { command: "sdkmanager --list", expect: "layer1" },
  { command: "ndk-build", expect: "layer1" },
  { command: "flutter build apk", expect: "layer1" },
  { command: "flutter build appbundle", expect: "layer1" },
  { command: "flutter build ios", expect: "layer1" },
  { command: "cargo build", expect: "layer1" },
  { command: "docker build .", expect: "layer1" },
  { command: "docker build -t x .", expect: "layer1" },
  // Fork bomb (spec §7, both regex shapes).
  { command: ":(){ :|:& };:", expect: "layer1" },
  // Review Focus #1 evasions.
  { command: "bash -c 'gradle build'", expect: "layer1" },
  { command: "sh -c \"gcc x.c\"", expect: "layer1" },
  { command: "CC=gcc make", expect: "layer1" },
  { command: "echo hi | gcc -x c -", expect: "layer1" },
  { command: "$(gradle build)", expect: "layer1" },
  { command: 'eval "$(echo gradle) build"', expect: "layer1" },
  { command: "sudo make", expect: "layer1" },
  { command: "xargs make < list.txt", expect: "layer1" },
  { command: "sh <<'EOF'\nmake\nEOF", expect: "layer1" },
  { command: "cd app && ./gradlew assembleRelease", expect: "layer1" },
  { command: '"g""cc" x.c', expect: "layer1" },
  // Unclosed here-doc: a real shell executes the body to EOF (review F1).
  { command: "bash <<'EOF'\nmake", expect: "layer1" },
  { command: "sh <<EOF\ngcc x.c", expect: "layer1" },
  { command: "bash <<'EOF'\ngradle build", expect: "layer1" },
  // `docker image build` — the word[2] alias of `docker build` (review F3).
  { command: "docker image build .", expect: "layer1" },
  // Layer-1 boundary: only the base64/gcc shims (layer 2) refuse this.
  { command: "echo Z3JhZGxlIHg= | base64 -d | sh", expect: "shim" },
];

/** Spec §7 "Allowed" forms — must NOT be blocked at any layer. */
export const ALLOWED_COMMAND_CORPUS: string[] = [
  'node -e "console.log(\'hi\')"',
  "node server.js",
  "python3 x.py",
  'python3 -c "print(\'hi\')"',
  "pnpm i",
  "pnpm add is-number",
  "npm install",
  "pip install six",
  "uv add six",
  "apt-get install -y jq",
  "git commit -m x",
  "flutter analyze",
  "flutter test",
  "flutter pub get",
  "cargo test",
  "cargo run",
  "cargo --version",
  "docker ps",
  "cat makefile",
  'echo "gcc is great"',
  "touch gradlew.txt",
  // Benign unclosed here-doc: the body must parse but contains no rule match.
  "cat <<'EOF'\necho hi",
  // word[2] alias shape with a pass-through subcommand (review F3).
  "docker image pull x",
];

/**
 * Path-escape corpus for Task 12 (path confinement) and Task 15 (in-jail
 * acceptance): every entry must resolve OUTSIDE a sandbox workspace root.
 * The first six are pinned by the plan.
 */
export const PATH_ESCAPE_CORPUS: string[] = [
  "../../etc/passwd",
  "/etc/passwd",
  "/workspace/../../etc/shadow",
  "/workspaces/users/999999/x",
  "a/../../..",
  "",
  "..",
  "/etc",
  "sub/../../..",
  "/root/.ssh/id_rsa",
  "/workspace/../../../etc/passwd",
];
