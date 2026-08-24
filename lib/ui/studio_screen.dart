import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Studio — coding harness (DeepSeek IDE style): file tree, editor with
/// syntax-y dummy code, agent activity rail, and proot Ubuntu terminal.
class StudioScreen extends StatelessWidget {
  const StudioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: const Text('Studio'),
        actions: [
          const Icon(Icons.play_arrow_rounded,
              size: 22, color: Aether.success),
          const SizedBox(width: 16),
          const Icon(Icons.account_tree_outlined,
              size: 18, color: Aether.textMuted),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Row(children: [
              Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                      color: Aether.success, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              const Text('proot ubuntu 24.04',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: Aether.mono,
                      color: Aether.textMuted)),
            ]),
          ),
        ],
      ),
      body: const SafeArea(
        child: Column(
          children: [
            _Tabs(),
            Expanded(child: _Editor()),
            Divider(height: 1),
            _Terminal(),
          ],
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs();
  @override
  Widget build(BuildContext context) {
    final tabs = ['main.dart', 'auth.js', 'README.md'];
    return Container(
      height: 38,
      color: Aether.surface,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (_, i) {
          final active = i == 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border(
                right: const BorderSide(color: Aether.hairline),
                top: BorderSide(
                    color: active ? Aether.accent : Colors.transparent,
                    width: 2),
              ),
              color: active ? Aether.bg : Aether.surface,
            ),
            child: Row(children: [
              Icon(Icons.description_outlined,
                  size: 13,
                  color: active ? Aether.text : Aether.textFaint),
              const SizedBox(width: 6),
              Text(tabs[i],
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          active ? Aether.text : Aether.textMuted)),
              const SizedBox(width: 8),
              const Icon(Icons.close, size: 12, color: Aether.textFaint),
            ]),
          );
        },
      ),
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor();

  static const code = '''
import 'package:flutter/material.dart';

void main() => runApp(const OvidApp());

class OvidApp extends StatelessWidget {
  const OvidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: const Scaffold(
        body: Center(child: Text('Hello from proot Ubuntu')),
      ),
    );
  }
}
''';

  @override
  Widget build(BuildContext context) {
    final lines = code.trimRight().split('\n');
    return Container(
      color: Aether.bg,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: lines.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 32,
                child: Text('${i + 1}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11.5,
                        height: 1.6,
                        color: Aether.textFaint)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(lines[i],
                    style: const TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 12,
                        height: 1.6,
                        color: Aether.text)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Terminal extends StatelessWidget {
  const _Terminal();

  static const out = [
    '\$ proot-distro login ubuntu',
    'root@localhost:~# apt install python3 -y',
    'Reading package lists... Done',
    'root@localhost:~# python3 --version',
    'Python 3.12.3',
    'root@localhost:~# agent --task "write tests" ',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 190,
      color: Aether.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            color: Aether.surfaceAlt,
            child: const Row(children: [
              Icon(Icons.terminal, size: 13, color: Aether.textMuted),
              SizedBox(width: 8),
              Text('TERMINAL — ubuntu@localhost',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Aether.textMuted)),
              Spacer(),
              Icon(Icons.add, size: 14, color: Aether.textFaint),
              SizedBox(width: 12),
              Icon(Icons.keyboard_arrow_up,
                  size: 16, color: Aether.textFaint),
            ]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final l in out)
                  Text(l,
                      style: TextStyle(
                          fontFamily: Aether.mono,
                          fontSize: 11.5,
                          height: 1.6,
                          color: l.startsWith('\$') ||
                                  l.startsWith('root@')
                              ? Aether.success
                              : Aether.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
