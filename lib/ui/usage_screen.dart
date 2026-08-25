import 'package:flutter/material.dart';
import '../core/theme.dart';

/// One connected client app that consumed model usage (dummy data).
class ClientUsage {
  final String name;
  final String kind; // CLI / Desktop / Mobile
  final String version;
  final IconData icon;
  final String lastActive;
  final int requests;
  final String tokensIn;
  final String tokensOut;
  final double cost;
  final List<double> daily; // last 14 days, relative heights
  final List<(String, int, String, double)> models; // model, req, tokens, $
  const ClientUsage({
    required this.name,
    required this.kind,
    required this.version,
    required this.icon,
    required this.lastActive,
    required this.requests,
    required this.tokensIn,
    required this.tokensOut,
    required this.cost,
    required this.daily,
    required this.models,
  });
}

const _clients = [
  ClientUsage(
    name: 'OvidAI App',
    kind: 'Mobile · this device',
    version: '0.1.0',
    icon: Icons.phone_android,
    lastActive: 'Active now',
    requests: 512,
    tokensIn: '1.8M',
    tokensOut: '7.4M',
    cost: 9.84,
    daily: [.3, .5, .4, .7, .6, .9, .8, 1, .7, .9, .6, .8, 1, .9],
    models: [
      ('claude-sonnet-4-6', 210, '3.1M', 5.60),
      ('gemini-2.5-flash', 196, '2.6M', 0.0),
      ('deepseek-chat', 84, '1.2M', 0.42),
      ('gpt-5.2', 22, '0.5M', 3.82),
    ],
  ),
  ClientUsage(
    name: 'OpenCode',
    kind: 'Desktop app',
    version: '1.4.2',
    icon: Icons.code,
    lastActive: '12 min ago',
    requests: 268,
    tokensIn: '2.1M',
    tokensOut: '5.9M',
    cost: 6.12,
    daily: [.6, .8, 1, .7, .9, .5, .4, .8, 1, .6, .7, .9, .5, .7],
    models: [
      ('claude-sonnet-4-6', 142, '2.6M', 4.36),
      ('deepseek-reasoner', 26, '0.9M', 0.78),
      ('deepseek-chat', 74, '1.6M', 0.33),
      ('gpt-5.2', 26, '0.8M', 0.65),
    ],
  ),
  ClientUsage(
    name: 'Claude Code CLI',
    kind: 'Terminal',
    version: '2.0.11',
    icon: Icons.terminal,
    lastActive: '2 h ago',
    requests: 196,
    tokensIn: '0.7M',
    tokensOut: '3.2M',
    cost: 3.58,
    daily: [.2, .4, .3, .9, 1, .8, .6, .5, .7, .4, .9, .6, .3, .8],
    models: [
      ('claude-sonnet-4-6', 60, '1.1M', 1.46),
      ('deepseek-chat', 122, '1.3M', 0.12),
      ('gemini-2.5-flash', 14, '0.8M', 0.0),
      ('gpt-5.2', 48, '0.6M', 2.58),
    ],
  ),
  ClientUsage(
    name: 'Z Code App',
    kind: 'Mobile · editor',
    version: '0.9.4',
    icon: Icons.bolt,
    lastActive: 'Yesterday',
    requests: 88,
    tokensIn: '0.2M',
    tokensOut: '0.9M',
    cost: 1.11,
    daily: [.1, .2, .1, .3, .4, .2, .6, .5, .3, .4, .7, .8, .6, .9],
    models: [
      ('deepseek-chat', 52, '0.6M', 0.09),
      ('gemini-2.5-flash', 36, '0.3M', 0.0),
      ('deepseek-reasoner', 18, '0.4M', 0.53),
      ('gpt-5.2', 0, '0', 0.0),
      ('claude-sonnet-4-6', 0, '0', 0.0),
    ],
  ),
];

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final total = _clients.fold<double>(0, (s, c) => s + c.cost);
    final reqs = _clients.fold<int>(0, (s, c) => s + c.requests);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('Usage')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // ---- Month summary ----
          Container(
            margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Row(children: [
              _stat('This month', '\$${total.toStringAsFixed(2)}', big: true),
              _stat('Requests', '$reqs'),
              _stat('Clients', '${_clients.length}'),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Text('BY CLIENT APP',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Aether.textFaint)),
          ),
          for (final c in _clients)
            ListTile(
              leading: CircleAvatar(
                radius: 17,
                backgroundColor: Aether.surface,
                child: Icon(c.icon, size: 17, color: Aether.accent),
              ),
              title: Text(c.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                  '${c.kind} · ${c.requests} requests · ${c.lastActive}',
                  style: const TextStyle(
                      fontSize: 11.5, color: Aether.textFaint)),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('\$${c.cost.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          fontFamily: Aether.mono,
                          color: Aether.text)),
                  const Icon(Icons.chevron_right,
                      size: 14, color: Aether.textFaint),
                ],
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ClientUsageScreen(client: c))),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 0),
            child: Text(
                'Usage is tracked from API keys used by each connected app. Demo data.',
                style: TextStyle(fontSize: 11, color: Aether.textFaint)),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, {bool big = false}) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(fontSize: 10.5, color: Aether.textFaint)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: big ? 22 : 16,
                fontWeight: FontWeight.w700,
                fontFamily: Aether.mono,
                color: big ? Aether.accent : Aether.text)),
      ]),
    );
  }
}

/// Detailed per-client usage screen.
class ClientUsageScreen extends StatelessWidget {
  final ClientUsage client;
  const ClientUsageScreen({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar:
          AppBar(leading: const BackButton(), title: Text(client.name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Aether.surface,
                child: Icon(client.icon, size: 22, color: Aether.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(client.name,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text('${client.kind} · v${client.version}',
                          style: const TextStyle(
                              fontSize: 12, color: Aether.textFaint)),
                      Text(client.lastActive,
                          style: const TextStyle(
                              fontSize: 11, color: Aether.textFaint)),
                    ]),
              ),
              Text('\$${client.cost.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      fontFamily: Aether.mono,
                      color: Aether.accent)),
            ]),
          ),

          // quick stats
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Row(children: [
              _cell('Requests', '${client.requests}'),
              _cell('Tokens in', client.tokensIn),
              _cell('Tokens out', client.tokensOut),
            ]),
          ),

          const _SectionLabel('LAST 14 DAYS'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(children: [
              SizedBox(
                height: 72,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in client.daily)
                      Expanded(
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 2.5),
                          child: FractionallySizedBox(
                            heightFactor: d,
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Aether.accent.withValues(
                                    alpha: 0.35 + d * 0.5),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('14 days ago',
                        style: TextStyle(
                            fontSize: 9.5, color: Aether.textFaint)),
                    Text('Today',
                        style: TextStyle(
                            fontSize: 9.5, color: Aether.textFaint)),
                  ]),
            ]),
          ),

          const _SectionLabel('PER MODEL'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(children: [
              const _Row(
                  h: true,
                  cells: ['MODEL', 'REQ', 'TOKENS', 'COST'],
                  flexes: [5, 2, 2, 2]),
              const Divider(height: 12),
              for (final m in client.models)
                _Row(cells: [
                  m.$1,
                  '${m.$2}',
                  m.$3,
                  m.$4 == 0 ? '—' : '\$${m.$4.toStringAsFixed(2)}',
                ], flexes: const [
                  5,
                  2,
                  2,
                  2
                ]),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _cell(String label, String value) {
    return Expanded(
      child: Column(children: [
        Text(value,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFamily: Aether.mono)),
        const SizedBox(height: 3),
        Text(label,
            style:
                const TextStyle(fontSize: 10.5, color: Aether.textFaint)),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Aether.textFaint)),
      );
}

class _Row extends StatelessWidget {
  final List<String> cells;
  final List<int> flexes;
  final bool h;
  const _Row({required this.cells, required this.flexes, this.h = false});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: flexes[i],
            child: Text(cells[i],
                overflow: TextOverflow.ellipsis,
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: TextStyle(
                  fontSize: h ? 9.5 : 11.5,
                  fontFamily: Aether.mono,
                  fontWeight: h ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: h ? 1.1 : 0,
                  color: h ? Aether.textFaint : Aether.text,
                )),
          ),
      ]),
    );
  }
}
