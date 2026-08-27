import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/agent_service.dart';

/// In-app browser (Manus-style) — used by AI agents to browse/login,
/// and by the user for web accounts. Live: renders whatever page the
/// agent last fetched via browser_open.
class BrowserScreen extends StatelessWidget {
  const BrowserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Browser'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: AnimatedBuilder(
              animation: AgentService.I,
              builder: (_, __) => Row(children: [
                Icon(AgentService.I.busy
                    ? Icons.smart_toy_outlined
                    : Icons.public_outlined,
                    size: 16, color: Aether.accent),
                const SizedBox(width: 6),
                Text(AgentService.I.busy
                        ? 'Agent viewing'
                        : 'Live',
                    style:
                        const TextStyle(fontSize: 12, color: Aether.accent)),
              ]),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const _OmniBar(),
            if (AgentService.I.busy) const _AgentBanner(),
            Expanded(child: _BrowserBody()),
          ],
        ),
      ),
    );
  }
}

class _OmniBar extends StatelessWidget {
  const _OmniBar();
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, __) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Row(children: [
          const Icon(Icons.arrow_back_ios, size: 15, color: Aether.textFaint),
          const SizedBox(width: 14),
          const Icon(Icons.arrow_forward_ios,
              size: 15, color: Aether.textFaint),
          const SizedBox(width: 14),
          const Icon(Icons.refresh, size: 17, color: Aether.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Aether.hairline),
              ),
              child: Row(children: [
                Icon(Icons.lock_outline,
                    size: 12,
                    color: AgentService.I.browserUrl == null
                        ? Aether.textFaint
                        : Aether.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      AgentService.I.browserUrl ?? 'about:blank',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: AgentService.I.browserUrl == null
                              ? Aether.textFaint
                              : Aether.text)),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.tab_outlined, size: 19, color: Aether.textMuted),
        ]),
      ),
    );
  }
}

class _AgentBanner extends StatelessWidget {
  const _AgentBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Aether.accentSoft,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: Aether.accent.withValues(alpha: 0.3)),
      ),
      child: const Row(children: [
        SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Aether.accent)),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Agent is logging you in to GitHub… (step 2/4)',
            style: TextStyle(fontSize: 12, color: Aether.text),
          ),
        ),
        Text('Take over',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Aether.accent)),
      ]),
    );
  }
}
class _BrowserBody extends StatelessWidget {
  const _BrowserBody();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, __) {
        final a = AgentService.I;
        if (a.browserPageText == null) {
          return Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.public_outlined,
                    size: 40, color: Aether.textFaint),
                SizedBox(height: 14),
                Text('No page open',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text(
                    'When the AI browses for you\nthe page appears here live.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: Aether.textMuted)),
              ]),
            ),
          );
        }
        // Render the fetched page text.
        return Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Aether.hairline),
          ),
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              SelectableText(a.browserPageText!,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.6, color: Aether.text)),
            ],
          ),
        );
      },
    );
  }
}
