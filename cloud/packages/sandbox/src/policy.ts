/**
 * Command policy layer (P2 Task 4, spec §7 layer 1): a quote/escape-aware
 * shell tokenizer, a denylist over the resulting segments, and the exact
 * refusal copy shared with the Task 3 PATH shims (parity pinned by
 * policy.test.ts — one source of truth).
 *
 * Scope: pure package code. No host interaction, no jail. Layer 2 (the
 * rootfs PATH shims) and layer 3 (cgroup caps) back this up.
 */

/** Spec §7 refusal copy, VERBATIM — every blocking layer prints exactly this. */
export const REFUSAL_MESSAGE =
  "Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead.";

/** Layer-1 verdict. `segment` is the offending segment's source text. */
export type PolicyVerdict = { allowed: true } | { allowed: false; matched: string; segment: string };

/** Thrown by Task 9 job start when a command is refused at layer 1. */
export class CommandBlockedError extends Error {
  constructor(readonly refusal: string, readonly matched: string) {
    super(refusal);
    this.name = "CommandBlockedError";
  }
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

/** An internal segment: its words (quotes joined, escapes resolved) and source text. */
interface Segment {
  words: string[];
  text: string;
}

/**
 * Index of the `)` matching the `(` at `openIdx`, or `command.length` when
 * unbalanced. Skips quoted spans and escapes so `)` inside quotes does not
 * close the substitution.
 */
function findMatchingParen(command: string, openIdx: number): number {
  let depth = 0;
  let i = openIdx;
  while (i < command.length) {
    const c = command[i];
    if (c === "'") {
      const close = command.indexOf("'", i + 1);
      i = close === -1 ? command.length : close + 1;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      while (j < command.length && command[j] !== '"') {
        if (command[j] === "\\") j++;
        j++;
      }
      i = j + 1;
      continue;
    }
    if (c === "\\") {
      i += 2;
      continue;
    }
    if (c === "(") depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) return i;
    }
    i++;
  }
  return command.length;
}

/**
 * Approximates the output words of a command substitution: the LAST inner
 * segment's words minus its head. Exact for `echo`/`printf` — the realistic
 * evasion vector (`eval "$(echo gradle) build"`) — and merely conservative
 * otherwise: it can only surface words the inner command already contains.
 */
function substitutionOutputWords(inner: Segment[]): string[] {
  const last = inner[inner.length - 1];
  return last ? last.words.slice(1) : [];
}

// Here-doc operator: `<<EOF`, `<<-EOF`, `<<'EOF'`, `<<"EOF"`, `<<-'EOF'`.
const HEREDOC_RE = /^<<-?(['"]?)([A-Za-z0-9_]+)\1?/;

// A pending word that is exactly an assignment prefix (`X=`) — the
// tokenizer joins unquoted substitution output into such a word instead of
// splicing it into head position (real shells do not word-split the
// right-hand side of an assignment; review F2).
const ASSIGNMENT_PREFIX_RE = /^[A-Za-z_][A-Za-z0-9_]*=$/;

/**
 * Single-pass, quote/escape-aware tokenizer. Splits `command` into segments
 * at `;`, `&&`, `||`, `|`, `&`, `(`, `)`, newlines and here-doc bodies;
 * adjacent quoted fragments join into one word (`"g""cc"` → `gcc`); escapes
 * keep operator characters inside words. Command-substitution contents
 * (`$( … )`, including inside double quotes) are parsed as their own
 * segments, and their approximated output words take the substitution's
 * place in the parent segment.
 */
function tokenize(command: string): Segment[] {
  const out: Segment[] = [];
  let words: string[] = [];
  let word = "";
  let hasWord = false;
  let segStart = 0;
  let i = 0;

  const endWord = () => {
    if (hasWord) {
      words.push(word);
      word = "";
      hasWord = false;
    }
  };
  const endSegment = (endIdx: number) => {
    endWord();
    if (words.length > 0) {
      out.push({ words, text: command.slice(segStart, endIdx).trim() });
    }
    words = [];
  };

  while (i < command.length) {
    const ch = command[i];

    // Operator boundaries — each ends the current command segment.
    if (ch === ";" || ch === "\n") {
      endSegment(i);
      i++;
      segStart = i;
      continue;
    }
    if (ch === "&") {
      endSegment(i);
      i += command[i + 1] === "&" ? 2 : 1;
      segStart = i;
      continue;
    }
    if (ch === "|") {
      endSegment(i);
      i += command[i + 1] === "|" ? 2 : 1;
      segStart = i;
      continue;
    }
    if (ch === "(" || ch === ")") {
      endSegment(i);
      i++;
      segStart = i;
      continue;
    }

    // Plain whitespace ends a word but not a segment.
    if (ch === " " || ch === "\t" || ch === "\r") {
      endWord();
      i++;
      continue;
    }

    // Escapes: the next character joins the word literally (a backslash
    // before a newline is a continuation and disappears).
    if (ch === "\\" && i + 1 < command.length) {
      if (command[i + 1] !== "\n") {
        word += command[i + 1];
        hasWord = true;
      }
      i += 2;
      continue;
    }

    // Single quotes: everything until the next ' is literal.
    if (ch === "'") {
      const close = command.indexOf("'", i + 1);
      if (close === -1) {
        word += command.slice(i + 1);
        i = command.length;
      } else {
        word += command.slice(i + 1, close);
        i = close + 1;
      }
      hasWord = true;
      continue;
    }

    // Double quotes: `"` `\` `$` and backtick are the only specials.
    if (ch === '"') {
      hasWord = true;
      i++;
      while (i < command.length && command[i] !== '"') {
        const c = command[i];
        if (
          c === "\\" &&
          i + 1 < command.length &&
          (command[i + 1] === '"' ||
            command[i + 1] === "\\" ||
            command[i + 1] === "$" ||
            command[i + 1] === "`")
        ) {
          word += command[i + 1];
          i += 2;
          continue;
        }
        // Command substitution runs inside double quotes too.
        if (c === "$" && i + 1 < command.length && command[i + 1] === "(") {
          const open = i + 1;
          const close = findMatchingParen(command, open);
          const inner = tokenize(command.slice(open + 1, close));
          out.push(...inner);
          // Quoted context: the output stays inside the current word.
          word += substitutionOutputWords(inner).join(" ");
          i = Math.min(close + 1, command.length);
          continue;
        }
        word += c;
        i++;
      }
      i++; // closing quote (or end of string)
      continue;
    }

    // Here-docs: `<<[-]['"]?DELIM` — the body (until the delimiter line)
    // is parsed as its own command string, because e.g. `sh <<'EOF'`
    // executes the body.
    if (ch === "<" && command[i + 1] === "<" && command[i + 2] !== "<") {
      const m = HEREDOC_RE.exec(command.slice(i));
      if (m) {
        const stripTabs = m[0].startsWith("<<-");
        const delim = m[2];
        endWord();
        const nl = command.indexOf("\n", i + m[0].length);
        if (nl === -1) break; // no body — nothing more to do
        endSegment(nl);
        // Scan line by line until the delimiter line.
        let pos = nl + 1;
        let bodyEnd = pos;
        let after = command.length;
        for (;;) {
          const eol = command.indexOf("\n", pos);
          const atEof = eol === -1;
          const lineEnd = atEof ? command.length : eol;
          const line = command.slice(pos, lineEnd);
          const candidate = stripTabs ? line.replace(/^\t+/, "") : line;
          if (candidate === delim) {
            // Closed: the body ends before the delimiter line.
            bodyEnd = pos;
            after = lineEnd < command.length ? lineEnd + 1 : command.length;
            break;
          }
          if (atEof) {
            // Unterminated here-doc (F1): a real shell executes the body to
            // EOF, so the REMAINDER is body content, not dropped text.
            bodyEnd = command.length;
            after = command.length;
            break;
          }
          pos = lineEnd + 1;
        }
        const body = command.slice(nl + 1, bodyEnd);
        if (body.trim().length > 0) out.push(...tokenize(body));
        i = after;
        segStart = i;
        continue;
      }
    }

    // Command substitution in unquoted context.
    if (ch === "$" && i + 1 < command.length && command[i + 1] === "(") {
      const open = i + 1;
      const close = findMatchingParen(command, open);
      const inner = tokenize(command.slice(open + 1, close));
      out.push(...inner);
      const output = substitutionOutputWords(inner);
      if (hasWord && ASSIGNMENT_PREFIX_RE.test(word)) {
        // Assignment RHS (F2): real shells do not word-split substitution
        // output in an assignment — join it into the pending word so it
        // never lands in head position after assignment stripping.
        word += output.join(" ");
      } else {
        // Fresh word: the output word-splits into the parent segment.
        endWord();
        for (const w of output) words.push(w);
      }
      i = Math.min(close + 1, command.length);
      continue;
    }

    // Anything else is word content.
    word += ch;
    hasWord = true;
    i++;
  }
  endSegment(command.length);
  return out;
}

/**
 * Quote/escape-aware split of a command string into segments (arrays of
 * words). See {@link tokenize} for the exact rules.
 */
export function splitShellSegments(command: string): string[][] {
  return tokenize(command).map((s) => s.words);
}

// ---------------------------------------------------------------------------
// Denylist
// ---------------------------------------------------------------------------

/** Spec §7 layer-1 denylist — matched on the head word's basename, exactly. */
const DENYLIST = new Set([
  "gradle",
  "gradlew",
  "kotlinc",
  "javac",
  "gcc",
  "g++",
  "make",
  "sdkmanager",
  "ndk-build",
]);

/** Leading words stripped before matching: wrappers (and VAR= assignments). */
const WRAPPER_HEADS = new Set(["sudo", "nice", "nohup", "time", "command", "builtin", "xargs", "env"]);

/** Shells whose `-c` argument is recursively parsed as a command string. */
const SHELL_HEADS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);

const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// A `-c`-style short flag: `-c`, `-lc`, `-ce`, … (not long options).
const C_FLAG_RE = /^-[A-Za-z]*c/;

// Fork bombs (spec §7) — they span operator boundaries, so they are matched
// on raw text, not on tokenized segments. Both shapes verbatim from the plan.
// Known limitation (review note F4): raw-text matching cannot see quotes, so
// quoted text shaped like a fork bomb (e.g. `echo "f(){ f | f & }; f"`) is
// also refused — contrived input, over-blocking direction, accepted.
const FORK_BOMB_RE = /:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/;
const FORK_BOMB_GENERAL_RE = /(\w+)\s*\(\)\s*\{\s*\1\s*\|\s*\1\s*&\s*\}\s*;\s*\1/;

/** Returns the head word's basename (`/usr/bin/gcc` → `gcc`, `./gradlew` → `gradlew`). */
function basename(word: string): string {
  return word.slice(word.lastIndexOf("/") + 1);
}

/** Applies the pinned matching rules to one segment; null when it is clean. */
function matchSegment(segment: Segment): PolicyVerdict | null {
  const { words, text } = segment;

  // Strip leading VAR=value assignments and wrapper heads, in any order.
  let i = 0;
  while (i < words.length && (ASSIGNMENT_RE.test(words[i]) || WRAPPER_HEADS.has(words[i]))) i++;
  if (i >= words.length) return null;

  const head = basename(words[i]);
  const rest = words.slice(i + 1);

  // Recursive descent: shell -c '<command>' → parse the argument.
  if (SHELL_HEADS.has(head)) {
    const ci = rest.findIndex((w) => C_FLAG_RE.test(w));
    if (ci !== -1 && ci + 1 < rest.length) {
      const inner = checkCommandPolicy(rest[ci + 1]);
      if (!inner.allowed) return inner;
    }
    return null;
  }

  // Recursive descent: eval <words…> → parse the words joined.
  if (head === "eval") {
    if (rest.length > 0) {
      const inner = checkCommandPolicy(rest.join(" "));
      if (!inner.allowed) return inner;
    }
    return null;
  }

  // Exact denylist on the head word's basename.
  if (DENYLIST.has(head)) return { allowed: false, matched: head, segment: text };

  // Positional rules: flutter build (apk|appbundle|ios), cargo build, docker build.
  if (head === "flutter" && rest[0] === "build" && rest[1] !== undefined) {
    if (rest[1] === "apk" || rest[1] === "appbundle" || rest[1] === "ios") {
      return { allowed: false, matched: `flutter build ${rest[1]}`, segment: text };
    }
  }
  if ((head === "cargo" || head === "docker") && rest[0] === "build") {
    return { allowed: false, matched: `${head} build`, segment: text };
  }
  // `docker image build` — the word[2] alias of `docker build` (review F3;
  // the brief's "positional: word[1]/word[2]" pinned to mean build at
  // either of the first two post-head positions).
  if (head === "docker" && rest[1] === "build") {
    return { allowed: false, matched: "docker build", segment: text };
  }

  // Gradle task names as any word of the segment.
  const task = words.find((w) => w === "assembleDebug" || w === "assembleRelease");
  if (task) return { allowed: false, matched: task, segment: text };

  return null;
}

/**
 * Layer-1 pre-parse check on a command string (spec §7). Fork bombs are
 * matched on the raw text first (they span operator boundaries); then every
 * tokenized segment is checked in order — first match wins.
 */
export function checkCommandPolicy(command: string): PolicyVerdict {
  const forkBomb = FORK_BOMB_RE.exec(command) ?? FORK_BOMB_GENERAL_RE.exec(command);
  if (forkBomb) return { allowed: false, matched: forkBomb[0], segment: forkBomb[0] };

  for (const segment of tokenize(command)) {
    const verdict = matchSegment(segment);
    if (verdict !== null) return verdict;
  }
  return { allowed: true };
}
