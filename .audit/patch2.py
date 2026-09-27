#!/usr/bin/env python3
"""Add a durable-write-failure banner to OvidShell.

Fixes the write-only `AppState.lastSessionPersistFailed` flag: state.dart sets
it when a session write fails, but a repo-wide grep finds ZERO readers — so a
failed write silently loses chat history (the user keeps chatting on top of
non-durable state and it is gone on restart).

Applies to the LIVE bytes with an exact-match assertion on every edit.
"""
import io
import os
import sys

REPO = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")
FILE = 'lib/ui/shell.dart'
EDITS = []

# 1) fields + timer
EDITS.append((
    'class _OvidShellState extends State<OvidShell> with WidgetsBindingObserver {\n'
    '  @override\n'
    '  void initState() {\n',
    'class _OvidShellState extends State<OvidShell> with WidgetsBindingObserver {\n'
    '  /// DURABILITY WARNING (2026-09-27): [AppState.lastSessionPersistFailed]\n'
    '  /// was written on a failed session write but never read by anything, so\n'
    '  /// chat history could silently stop being saved. This polls the flag and\n'
    '  /// surfaces a persistent banner instead of failing invisibly.\n'
    '  Timer? _persistWarnTimer;\n'
    '  bool _persistWarned = false;\n'
    '\n'
    '  @override\n'
    '  void initState() {\n',
))

# 2) start the watcher
EDITS.append((
    '    WidgetsBinding.instance.addPostFrameCallback(\n'
    '      (_) => unawaited(AppState.I.maybeStartBackgroundRuntimeInstall()),\n'
    '    );\n'
    '  }\n',
    '    WidgetsBinding.instance.addPostFrameCallback(\n'
    '      (_) => unawaited(AppState.I.maybeStartBackgroundRuntimeInstall()),\n'
    '    );\n'
    '    // Durability watchdog: a few seconds is enough for the debounced\n'
    '    // session write to land, so a genuine failure shows up promptly.\n'
    '    _persistWarnTimer = Timer.periodic(const Duration(seconds: 3), (_) {\n'
    '      final failed = AppState.I.lastSessionPersistFailed;\n'
    '      if (failed != _persistWarned && mounted) {\n'
    '        setState(() => _persistWarned = failed);\n'
    '      }\n'
    '    });\n'
    '  }\n',
))

# 3) cancel on dispose
EDITS.append((
    '  void dispose() {\n'
    '    WidgetsBinding.instance.removeObserver(this);\n',
    '  void dispose() {\n'
    '    _persistWarnTimer?.cancel();\n'
    '    WidgetsBinding.instance.removeObserver(this);\n',
))

# 4) render the banner above the body
EDITS.append((
    '      body: wide\n'
    '          ? Row(\n'
    '              children: [\n'
    '                const SessionsSidebar(isDrawer: false),\n'
    '                const VerticalDivider(width: 1),\n'
    '                Expanded(child: chat),\n'
    '              ],\n'
    '            )\n'
    '          : chat,\n'
    '    );\n'
    '  }\n',
    '      body: Column(\n'
    '        children: [\n'
    '          if (_persistWarned) const _PersistWarningBanner(),\n'
    '          Expanded(\n'
    '            child: wide\n'
    '                ? Row(\n'
    '                    children: [\n'
    '                      const SessionsSidebar(isDrawer: false),\n'
    '                      const VerticalDivider(width: 1),\n'
    '                      Expanded(child: chat),\n'
    '                    ],\n'
    '                  )\n'
    '                : chat,\n'
    '          ),\n'
    '        ],\n'
    '      ),\n'
    '    );\n'
    '  }\n',
))

# 5) the banner widget itself
EDITS.append((
    '/// Chat-first shell, DeepSeek-web style. The chat IS the app; everything\n',
    '/// Shown when the debounced session write has failed, i.e. chat history is\n'
    '/// no longer being persisted. Deliberately non-dismissible: the condition\n'
    '/// clears on its own as soon as a write succeeds again.\n'
    'class _PersistWarningBanner extends StatelessWidget {\n'
    '  const _PersistWarningBanner();\n'
    '\n'
    '  @override\n'
    '  Widget build(BuildContext context) {\n'
    '    return Material(\n'
    '      color: Aether.danger.withValues(alpha: 0.16),\n'
    '      child: const Padding(\n'
    '        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),\n'
    '        child: Row(\n'
    '          children: [\n'
    '            Icon(Icons.warning_amber_rounded,\n'
    '                size: 16, color: Aether.danger),\n'
    '            SizedBox(width: 8),\n'
    '            Expanded(\n'
    '              child: Text(\n'
    '                "Chat history isn\'t being saved — free up storage and "\n'
    '                "restart Ovid to protect this conversation.",\n'
    '                style: TextStyle(fontSize: 12, height: 1.35),\n'
    '              ),\n'
    '            ),\n'
    '          ],\n'
    '        ),\n'
    '      ),\n'
    '    );\n'
    '  }\n'
    '}\n'
    '\n'
    '/// Chat-first shell, DeepSeek-web style. The chat IS the app; everything\n',
))

path = os.path.join(REPO, FILE)
with io.open(path, encoding='utf-8') as fh:
    src = fh.read()

for i, (old, new) in enumerate(EDITS, 1):
    n = src.count(old)
    if n != 1:
        print('!! ABORT edit %d: expected 1 match, found %d' % (i, n))
        print('   pattern head: %r' % old[:80])
        sys.exit(1)
    src = src.replace(old, new, 1)
    print('OK  edit %d applied' % i)

with io.open(path, 'w', encoding='utf-8') as fh:
    fh.write(src)
print('RESULT: %s patched (%d edits).' % (FILE, len(EDITS)))
