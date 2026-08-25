import 'package:flutter/material.dart';
import '../core/theme.dart';

/// In-app browser (Manus-style) — used by AI agents to browse/login,
/// and by the user for web accounts. Demo UI with dummy content.
class BrowserScreen extends StatelessWidget {
  const BrowserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Browser'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 14),
            child: Row(children: [
              Icon(Icons.smart_toy_outlined, size: 16, color: Aether.accent),
              SizedBox(width: 6),
              Text('Agent viewing',
                  style: TextStyle(fontSize: 12, color: Aether.accent)),
            ]),
          ),
        ],
      ),
      body: const SafeArea(
        child: Column(
          children: [
            _OmniBar(),
            _AgentBanner(),
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
    return Padding(
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
            child: const Row(children: [
              Icon(Icons.lock_outline, size: 12, color: Aether.success),
              SizedBox(width: 6),
              Expanded(
                child: Text('github.com/login',
                    style: TextStyle(fontSize: 12.5, color: Aether.text)),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        const Icon(Icons.tab_outlined, size: 19, color: Aether.textMuted),
      ]),
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
    // Dummy rendered page
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hub_outlined,
              size: 40, color: Aether.textFaint),
          const SizedBox(height: 14),
          const Text('Sign in to GitHub',
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          _fakeField('Username or email'),
          const SizedBox(height: 10),
          _fakeField('Password', obscure: true),
          const SizedBox(height: 16),
          Container(
            width: 280,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: Aether.success.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
                child: Text('Sign in',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87))),
          ),
          const SizedBox(height: 18),
          const Text(
            'Sessions & cookies stay on this device only.',
            style: TextStyle(fontSize: 11, color: Aether.textFaint),
          ),
        ]),
      ),
    );
  }

  Widget _fakeField(String hint, {bool obscure = false}) {
    return Container(
      width: 280,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Aether.hairline),
      ),
      child: Text(obscure ? '••••••••••' : hint,
          style: TextStyle(
              fontSize: 13,
              color: obscure ? Aether.text : Aether.textFaint)),
    );
  }
}
