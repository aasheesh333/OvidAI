#!/usr/bin/env python3
"""Brace/paren/bracket balance check, BEFORE (git HEAD) vs AFTER (working tree)."""
import io
import os
import subprocess

REPO = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")
FILES = [
    'lib/core/theme.dart',
    'lib/core/state.dart',
    'lib/ui/chat_screen.dart',
    'lib/ui/shell.dart',
]


def strip(src):
    out = []
    i = 0
    n = len(src)
    mode = None
    while i < n:
        c = src[i]
        if mode is None:
            if c == '/' and i + 1 < n and src[i + 1] == '/':
                while i < n and src[i] != '\n':
                    i += 1
                continue
            if c == '/' and i + 1 < n and src[i + 1] == '*':
                i += 2
                while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                    i += 1
                i += 2
                continue
            if c in ("'", '"'):
                mode = c
                i += 1
                continue
            out.append(c)
            i += 1
        else:
            if c == '\\':
                i += 2
                continue
            if c == mode:
                mode = None
            i += 1
    return ''.join(out)


def bal(src):
    s = strip(src)
    return (s.count('{') - s.count('}'),
            s.count('(') - s.count(')'),
            s.count('[') - s.count(']'))


print('%-26s %-7s %8s %8s %9s' % ('file', 'rev', 'braces', 'parens', 'brackets'))
delta_bad = []
for f in FILES:
    live = io.open(os.path.join(REPO, f), encoding='utf-8').read()
    head = subprocess.run(['git', 'show', 'HEAD:' + f], cwd=REPO,
                          capture_output=True).stdout.decode('utf-8')
    hb, lb = bal(head), bal(live)
    for label, b in (('BEFORE', hb), ('AFTER', lb)):
        print('%-26s %-7s %+8d %+8d %+9d' % (f, label, b[0], b[1], b[2]))
    if hb != lb:
        delta_bad.append((f, hb, lb))

print()
if delta_bad:
    print('RESULT: PROBLEM — patch changed delimiter balance:')
    for row in delta_bad:
        print('   ', row)
else:
    print('RESULT: every edited file balances IDENTICALLY to HEAD.')
    print('        (A non-zero absolute value is a string-interpolation artifact')
    print('         of this naive stripper; only the BEFORE/AFTER delta matters.)')
