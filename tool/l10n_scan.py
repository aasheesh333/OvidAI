#!/usr/bin/env python3
"""Inventory hard-coded user-facing strings in the UI v2 tree.

Emits a CSV (`file,line,text`) that can be sorted, filtered and ticked off while
moving copy into `lib/l10n/app_en.arb`. This is a *scanner*, not a parser: it
lexes Dart strings/comments well enough to avoid commented-out code, then keeps
a literal when its calling context or declared name looks like UI copy.

Usage:
    python3 tool/l10n_scan.py                     # CSV on stdout, summary on stderr
    python3 tool/l10n_scan.py --out /tmp/l10n.csv
    python3 tool/l10n_scan.py --skip-todo         # ignore files already flagged
    python3 tool/l10n_scan.py --per-file          # per-file counts on stderr
    python3 tool/l10n_scan.py --self-test         # run the embedded cases

See docs/l10n/EXTRACTION.md for the extraction workflow.
"""
from __future__ import annotations

import argparse
import bisect
import csv
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOTS = ("lib/ui/v2",)

# Parameters that carry copy. Keep this aligned with the ratchet test in
# test/l10n_literal_ratchet_test.dart plus the v2 design-system components.
UI_PARAMS = frozenset(
    {
        "label",
        "tooltip",
        "tooltipMessage",
        "title",
        "titleText",
        "subtitle",
        "hint",
        "hintText",
        "labelText",
        "helper",
        "helperText",
        "supportingText",
        "message",
        "semanticsLabel",
        "semanticLabel",
        "errorText",
        "errorMessage",
        "emptyMessage",
        "emptyTitle",
        "emptyLabel",
        "emptyActionLabel",
        "eyebrow",
        "content",
        "text",
        "description",
        "caption",
        "heading",
        "header",
        "body",
        "note",
        "notice",
        "banner",
        "placeholder",
        "prompt",
        "confirmLabel",
        "cancelLabel",
        "actionLabel",
        "retryLabel",
        "submitLabel",
        "ctaLabel",
        "statusLabel",
        "valueLabel",
        "shortLabel",
        "longLabel",
        "name",
        "summary",
        "detail",
        "reason",
        "goal",
        "tagline",
        "group",
        "category",
        "audience",
    }
)

# Parameters whose string literals are plumbing, never translated.
NON_UI_PARAMS = frozenset(
    {
        "key",
        "id",
        "font",
        "fontFamily",
        "fontFamilyFallback",
        "package",
        "path",
        "asset",
        "assetPath",
        "url",
        "route",
        "mime",
        "mimeType",
        "extension",
        "format",
        "pattern",
        "regex",
        "prefix",
        "suffix",
        "jsonKey",
        "field",
        "code",
        "locale",
        "languageCode",
        "countryCode",
        "currency",
        "timezone",
        "timeZone",
    }
)

# Callees whose string arguments are widget copy.
COPY_CALLEES = frozenset(
    {
        "Text",
        "SelectableText",
        "TextSpan",
        "Semantics",
        "Tooltip",
        "OAppBar",
        "OEmptyState",
        "OErrorState",
        "OSheet",
        "ODialog",
        "OSnackBar",
        "OText",
    }
)

# Callees whose string arguments are logs, assertions or developer errors.
NON_UI_CALLEES = frozenset(
    {
        "print",
        "debugPrint",
        "log",
        "logger",
        "Logger",
        "debugLog",
        "assert",
        "assertion",
        "throw",
        "Exception",
        "StateError",
        "ArgumentError",
        "FormatException",
        "UnsupportedError",
        "RangeError",
        "RegExp",
        "Uri",
        "Uri.parse",
        "File",
        "Directory",
        "DateTime",
        "Duration",
        "runZonedGuarded",
        "FlutterError",
        "ValueKey",
        "Key",
        "PageStorageKey",
        "GlobalKey",
        "UniqueKey",
    }
)

# Declared names that hold copy: _accentLabels, errorMessage, composerHint,
# _densityLabel(), V2Thing.title, etc.
COPY_NAME = re.compile(
    r"(?i)(label|text|title|subtitle|message|msg|hint|placeholder|tooltip|"
    r"description|desc|caption|heading|header|body|error|empty|action|button|"
    r"cta|confirm|cancel|retry|copy|eyebrow|badge|note|notice|banner|prompt|"
    r"question|answer|summary|reason|detail|name|status)(?:s|es)?$"
)

# Declared names that sound like copy but hold plumbing (`searchText`,
# `toString`, `debugLabel`, cache keys) or raw serialized data.
NON_UI_NAME_WORDS = frozenset(
    {
        "search",
        "debug",
        "log",
        "key",
        "id",
        "path",
        "url",
        "uri",
        "route",
        "hash",
        "json",
        "serialize",
        "encode",
        "raw",
        "html",
        "css",
        "regex",
        "pattern",
        "format",
        "mime",
        "locale",
        "timezone",
        "asset",
        "font",
        "color",
        "colour",
        "icon",
        "padding",
        "margin",
        "radius",
        "duration",
        "offset",
    }
)


def is_non_ui_name(name: str) -> bool:
    """True for plumbing names; compare identifier words, not substrings."""
    if name.lower() in {"tostring", "hashcode"}:
        return True
    words = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name)
    return any(word in NON_UI_NAME_WORDS for word in re.split(r"[_\W]+", words.lower()))

CODE_EXT = re.compile(
    r"(?i)[A-Za-z0-9_.-]+\.(dart|json|png|jpe?g|gif|svg|webp|pdf|md|txt|log|"
    r"arb|ya?ml|html?|css|js|ts|tsx|sh|py|toml|lock)$"
)
PATH_LIKE = re.compile(r"[\\/]")
HEX_COLOR = re.compile(r"#[0-9A-Fa-f]{3,8}$")
KEY_LIST = re.compile(r"[\w$]+(?:[_.][\w$]+)*(?:\s*,\s*[\w$]+(?:[_.][\w$]+)*)+$")


@dataclass(frozen=True)
class Literal:
    path: str
    line: int
    column: int
    text: str


def _line_starts(source: str) -> list[int]:
    starts = [0]
    for match in re.finditer("\n", source):
        starts.append(match.end())
    return starts


def _line_col(starts: list[int], index: int) -> tuple[int, int]:
    line = bisect.bisect_right(starts, index)
    return line, index - starts[line - 1] + 1


def _skip_interpolation(source: str, index: int) -> int:
    """Return the index just after the `}` closing `${` at `index - 2`."""
    depth = 1
    i = index
    while i < len(source):
        char = source[i]
        if char in "'\"":
            end, _raw, _text = _scan_string(source, i)
            if end is None:  # malformed single-line string: consume the quote
                i += 1
            else:
                i = end
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def _scan_string(source: str, index: int) -> tuple[int | None, bool, str]:
    """Scan one Dart string starting at a quote (or its `r` prefix).

    Returns (end index, is raw, raw content). `end` is None for an unterminated
    single-line string, so the caller can recover at the newline.
    """
    raw = False
    if source[index] == "r" and index + 1 < len(source) and source[index + 1] in "'\"":
        raw = True
        index += 1
    quote = source[index]
    triple = source.startswith(quote * 3, index)
    start = index + (3 if triple else 1)
    i = start
    while i < len(source):
        char = source[i]
        if not raw and char == "\\":
            i += 2
            continue
        if not raw and char == "$" and i + 1 < len(source) and source[i + 1] == "{":
            i = _skip_interpolation(source, i + 2)
            continue
        if triple:
            if source.startswith(quote * 3, i):
                return i + 3, raw, source[start:i]
        else:
            if char == quote:
                return i + 1, raw, source[start:i]
            if char == "\n":
                return None, raw, source[start:i]
        i += 1
    return None, raw, source[start:]


def _iter_strings(source: str):
    """Yield (start, end, raw, content) for every Dart string outside comments."""
    i = 0
    length = len(source)
    while i < length:
        char = source[i]
        if char == "/" and i + 1 < length and source[i + 1] == "/":
            newline = source.find("\n", i)
            i = length if newline < 0 else newline
            continue
        if char == "/" and i + 1 < length and source[i + 1] == "*":
            # Dart block comments nest.
            depth = 1
            i += 2
            while i < length and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        is_raw_prefix = (
            char == "r"
            and i + 1 < length
            and source[i + 1] in "'\""
            and (i == 0 or not (source[i - 1].isalnum() or source[i - 1] in "_$"))
        )
        if char in "'\"" or is_raw_prefix:
            start = i
            end, raw, content = _scan_string(source, i)
            if end is None:
                newline = source.find("\n", i)
                i = length if newline < 0 else newline
                continue
            yield start, end, raw, content
            i = end
            continue
        i += 1


def _previous_token(source: str, index: int) -> tuple[str, int]:
    """Skip whitespace backwards and return (char, position)."""
    i = index - 1
    while i >= 0 and source[i].isspace():
        i -= 1
    return (source[i] if i >= 0 else ""), i


def _identifier_before(source: str, index: int) -> str:
    """Identifier ending just before the token at `index`."""
    i = index - 1
    while i >= 0 and source[i].isspace():
        i -= 1
    end = i + 1
    while i >= 0 and (source[i].isalnum() or source[i] in "_$"):
        i -= 1
    return source[i + 1 : end]


def _callee_name(source: str, paren_index: int) -> str:
    """Best-effort callee before an opening parenthesis, e.g. `Text.rich`."""
    i = paren_index - 1
    while i >= 0 and source[i].isspace():
        i -= 1
    parts = []
    while True:
        end = i + 1
        while i >= 0 and (source[i].isalnum() or source[i] in "_$"):
            i -= 1
        parts.append(source[i + 1 : end])
        if i >= 0 and source[i] == ".":
            i -= 1
            continue
        break
    return ".".join(reversed([p for p in parts if p]))


def _function_name(source: str, index: int) -> str | None:
    """Enclosing function/getter name for copy-returning helpers."""
    window = source[max(0, index - 600) : index]
    matches = list(
        re.finditer(
            r"(?:String|Widget|List<String>|Iterable<String>)\s+"
            r"([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*(?:async\s*)?(?:=>|\{)",
            window,
        )
    )
    return matches[-1].group(1) if matches else None


def _declared_name(source: str, index: int) -> str | None:
    """Name of the variable or field the literal is assigned to."""
    window = source[max(0, index - 800) : index]
    boundary = max(window.rfind(";"), window.rfind("{"), window.rfind("}"))
    statement = window[boundary + 1 :]
    # const List<String> _accentLabels = <String>['Violet', 'Blue'];
    matches = list(
        re.finditer(
            r"([A-Za-z_$][\w$]*)\s*=\s*(?:const\s+)?(?:<[^;=]*>)?\s*\[",
            statement,
        )
    )
    if matches:
        return matches[-1].group(1)
    func = _function_name(source, index)
    if func:
        return func
    getters = list(
        re.finditer(r"\bget\s+([A-Za-z_$][\w$]*)\s*(?:=>|\{)", statement)
    )
    if getters:
        return getters[-1].group(1)
    return None


def _looks_like_copy(text: str) -> bool:
    value = text.strip()
    if len(value) < 2 or not re.search(r"[A-Za-z]", value):
        return False
    lowered = value.lower()
    if lowered.startswith(
        (
            "http://",
            "https://",
            "package:",
            "dart:",
            "assets/",
            "mailto:",
            "tel:",
            "file:",
            "/",
            "./",
            "../",
            "~/",
        )
    ):
        return False
    if PATH_LIKE.search(value) and " " not in value:
        return False
    if re.search(r"(^|\s)(?:/|\./|~/)[^\s]*", value):
        return False
    if CODE_EXT.fullmatch(value) or HEX_COLOR.match(value):
        return False
    if "@" in value and " " not in value:
        return False
    if re.fullmatch(r"[\d\s.:%+\-]+", value):
        return False
    if KEY_LIST.fullmatch(value):
        return False
    if re.match(r"(?i)^(const|final|var|void|class|import|export|function|def|let)\b", value) and re.search(r"[;{}=]", value):
        return False
    # Single-word values are too ambiguous (ids, methods, font names); they are
    # kept only when the surrounding context proves they are copy.
    if " " not in value and not re.match(r"[A-Z]", value):
        return False
    return True


def _is_prose(text: str) -> bool:
    """Sentence-shaped copy, ignoring interpolation expressions.

    `'$count ${count == 1 ? 'run' : 'runs'}'` is copy because its call site
    carries it; a bare `'${a}::$b'` is an identifier, not copy.
    """
    value = re.sub(r"\$\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", " ", text)
    value = re.sub(r"\$[A-Za-z_$][\w$]*", " ", value)
    if re.search(r"[;{}=]|=>|::", value):
        return False
    words = re.findall(r"[A-Za-z][A-Za-z'’\-]*", value)
    return len(words) >= 2


def _display_text(raw_content: str, is_raw: bool) -> str:
    text = raw_content.strip()
    if not is_raw:
        text = re.sub(r"\\(['\"$\\])", r"\1", text)
    return text.replace("\r\n", "\n").replace("\n", "\\n").replace("\t", "\\t")


def _enclosing_call(source: str, index: int) -> tuple[str, int] | None:
    """Innermost call whose argument list contains `index`."""
    depth = 0
    i = index - 1
    while i >= 0:
        char = source[i]
        if char == ")":
            depth += 1
        elif char == "(":
            if depth == 0:
                return _callee_name(source, i), i
            depth -= 1
        elif char in ";{}":
            return None
        i -= 1
    return None


def _string_key_before(source: str, colon: int) -> str:
    """Key of a map literal entry, e.g. the `label` in `'label': 'Private'`."""
    match = re.search(r"""(['"])([A-Za-z_$][\w$]*)\1\s*:\s*$""", source[: colon + 1])
    return match.group(2) if match else ""


def classify(source: str, index: int, raw: bool, content: str) -> bool:
    """True when the string at `index` is user-facing copy."""
    text = _display_text(content, raw)
    if not _looks_like_copy(text):
        return False
    if raw and re.search(r"\\[dwsb.]|\[\^|\(\?:|\$$", text):
        return False

    char, position = _previous_token(source, index)
    param = ""
    callee = ""
    if char == ":":
        param = _identifier_before(source, position) or _string_key_before(source, position)
        if param in NON_UI_PARAMS:
            return False
        if param in UI_PARAMS:
            return True
    if char == "(":
        callee = _callee_name(source, position)
        if callee in NON_UI_CALLEES or callee.split(".")[-1] in NON_UI_CALLEES:
            return False
        if callee in COPY_CALLEES or callee.split(".")[-1] in COPY_CALLEES:
            return True

    enclosing = _enclosing_call(source, index)
    if enclosing:
        callee, _ = enclosing
        if callee in NON_UI_CALLEES or callee.split(".")[-1] in NON_UI_CALLEES:
            return False

    if char == "[":
        # List elements inherit the list's declared name.
        declared = _declared_name(source, index)
        if declared and COPY_NAME.search(declared):
            return True

    declared = _declared_name(source, index)
    if declared and is_non_ui_name(declared):
        return False
    if declared and COPY_NAME.search(declared):
        return True

    if char == ">":
        # switch (id) { 'x' => 'Copy', ... }
        if _is_prose(text):
            return True

    # A plain prose literal in a widget tree is copy in practice. Require a
    # real sentence shape so header names, MIME types and paths stay out.
    if _is_prose(text):
        return True
    return False


def scan_file(path: Path, root: Path) -> list[Literal]:
    source = path.read_text(encoding="utf-8")
    display_path = path.relative_to(root).as_posix()
    starts = _line_starts(source)
    seen: set[tuple[int, int, str]] = set()
    out: list[Literal] = []
    merged: list[tuple[int, str, str]] = []
    previous_end = -1
    for start, end, raw, content in _iter_strings(source):
        if merged and source[previous_end:start].strip() == "":
            prev_start, prev_raw, prev_content = merged[-1]
            merged[-1] = (
                prev_start,
                prev_raw and raw,
                prev_content + content,
            )
        else:
            merged.append((start, raw, content))
        previous_end = end

    for index, raw, content in merged:
        if not classify(source, index, raw, content):
            continue
        line, column = _line_col(starts, index)
        text = _display_text(content, raw)
        key = (line, column, text)
        if key in seen:
            continue
        seen.add(key)
        out.append(Literal(display_path, line, column, text))
    return out


def find_dart_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file() and root.suffix == ".dart":
            files.append(root)
        elif root.is_dir():
            files.extend(sorted(p for p in root.rglob("*.dart") if p.is_file()))
    return sorted(set(files))


def resolve_roots(raw: list[str]) -> tuple[list[Path], Path]:
    """Resolve CLI paths against cwd, then the repo root."""
    roots: list[Path] = []
    for item in raw:
        candidate = Path(item)
        if not candidate.is_absolute() and not candidate.exists():
            candidate = REPO_ROOT / item
        roots.append(candidate.resolve())
    if not roots:
        roots = [(REPO_ROOT / item).resolve() for item in DEFAULT_ROOTS]
    if len(roots) == 1:
        root = roots[0]
        if not root.is_dir():
            return roots, root.parent
        if not root.is_relative_to(REPO_ROOT):
            return roots, root
    return roots, REPO_ROOT


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inventory user-facing string literals in Dart UI code."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="files or directories to scan (default: lib/ui/v2)",
    )
    parser.add_argument(
        "--out",
        metavar="FILE",
        help="write the CSV to FILE instead of stdout",
    )
    parser.add_argument(
        "--skip-todo",
        action="store_true",
        help="skip files that already contain a TODO(l10n) marker",
    )
    parser.add_argument(
        "--per-file",
        action="store_true",
        help="print a per-file count table to stderr",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the embedded classification tests and exit",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    roots, relative_to = resolve_roots(args.paths)
    missing = [str(root) for root in roots if not root.exists()]
    if missing:
        parser.error(f"path not found: {', '.join(missing)}")

    files = find_dart_files(roots)
    skipped_todo = 0
    records: list[Literal] = []
    per_file: dict[str, int] = {}
    for path in files:
        source = path.read_text(encoding="utf-8")
        if args.skip_todo and "TODO(l10n)" in source:
            skipped_todo += 1
            continue
        literals = scan_file(path, relative_to)
        if literals:
            per_file[literals[0].path] = len(literals)
        records.extend(literals)

    rows = [
        (item.path, item.line, item.text)
        for item in sorted(records, key=lambda lit: (lit.path, lit.line, lit.column))
    ]

    if args.out:
        destination = Path(args.out)
        destination.parent.mkdir(parents=True, exist_ok=True)
        handle = destination.open("w", encoding="utf-8", newline="")
        close = True
        summary_stream = sys.stdout
    else:
        handle = sys.stdout
        close = False
        summary_stream = sys.stderr

    try:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(("file", "line", "text"))
        writer.writerows(rows)
    finally:
        if close:
            handle.close()

    scope = ", ".join(
        str(root.relative_to(relative_to)) if root.is_relative_to(relative_to) else str(root)
        for root in roots
    )
    if not scope or scope == ".":
        scope = roots[0].name if len(roots) == 1 else "."
    summary_stream.write(
        f"Scanned {len(files) - skipped_todo} Dart files in {scope}\n"
        f"Found {len(rows)} user-facing literals in {len(per_file)} files\n"
    )
    if skipped_todo:
        summary_stream.write(f"Skipped {skipped_todo} files with TODO(l10n)\n")
    if args.out:
        summary_stream.write(f"CSV written to {args.out}\n")
    if args.per_file:
        summary_stream.write("\nLiterals per file:\n")
        for path, count in sorted(per_file.items(), key=lambda pair: (-pair[1], pair[0])):
            summary_stream.write(f"{count:5d}  {path}\n")
    return 0


def _self_test() -> int:
    """Embedded fixtures: no extra test file, but behavior stays pinned."""
    cases = [
        # (source, expected texts)
        ("Text('Retry')", ["Retry"]),
        ("const Text('Delete this chat?')", ["Delete this chat?"]),
        ("OAppBar(title: 'Subagent')", ["Subagent"]),
        ("Semantics(label: 'Close')", ["Close"]),
        ("// Text('Commented out')", []),
        ("/* Text('Also gone') */", []),
        ("final s = 'files_modified';", []),
        ("const _accentLabels = <String>['Violet', 'Blue'];", ["Violet", "Blue"]),
        ("Text('Hello $name')", ["Hello $name"]),
        ("Text(r'C:\\temp')", []),
        ("throw StateError('boom')", []),
        ("debugPrint('hello there')", []),
        ("fontFamily: 'Fira Code'", []),
    ]
    failed = 0
    for source, expected in cases:
        got = []
        previous_end = -1
        for start, end, raw, content in _iter_strings(source):
            if got and source[previous_end:start].strip() == "":
                got[-1] += _display_text(content, raw)
            elif classify(source, start, raw, content):
                got.append(_display_text(content, raw))
            previous_end = end
        if got != expected:
            failed += 1
            print(f"FAIL: {source!r}\n  expected {expected!r}\n  got      {got!r}", file=sys.stderr)
    if failed:
        print(f"{failed} self-test case(s) failed", file=sys.stderr)
        return 1
    print(f"{len(cases)} self-test cases passed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
