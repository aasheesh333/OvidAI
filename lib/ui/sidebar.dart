import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'settings_screen.dart';

/// Sessions sidebar — DeepSeek-style harness: auto-named sessions,
/// search, new session, swipe to delete, long-press rename.
class SessionsSidebar extends StatelessWidget {
  const SessionsSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Container(
      width: 288,
      color: Aether.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Brand
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Aether.accent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Center(
                      child: Text('O',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text('Ovid',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ),

            // New session button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  app.newSession();
                  Navigator.maybePop(context);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Aether.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Aether.accent.withValues(alpha: 0.35)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, size: 16, color: Aether.accent),
                      SizedBox(width: 6),
                      Text('New session',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Aether.accent)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Search (visual)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                style: TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search sessions',
                  prefixIcon: Icon(Icons.search,
                      size: 16, color: Aether.textFaint),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('SESSIONS',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                      color: Aether.textFaint)),
            ),
            const SizedBox(height: 6),

            // Sessions list
            Expanded(
              child: AnimatedBuilder(
                animation: app,
                builder: (_, _) => ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: app.sessions.length,
                  itemBuilder: (_, i) {
                    final s = app.sessions[i];
                    final active = s.id == app.activeSessionId;
                    return _SessionTile(session: s, active: active);
                  },
                ),
              ),
            ),

            const Divider(),
            // Settings at the very bottom — DeepSeek style.
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SettingsScreen())),
              child: Container(
                margin: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: Aether.surfaceRaised,
                    child: Icon(Icons.person_outline,
                        size: 15, color: Aether.textMuted),
                  ),
                  SizedBox(width: 12),
                  Text('Settings',
                      style: TextStyle(
                          fontSize: 13, color: Aether.textMuted)),
                  Spacer(),
                  Icon(Icons.chevron_right,
                      size: 16, color: Aether.textFaint),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ChatSession session;
  final bool active;
  const _SessionTile({required this.session, required this.active});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => app.deleteSession(session.id),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Aether.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.delete_outline,
            color: Aether.danger, size: 18),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          app.selectSession(session.id);
          Navigator.maybePop(context);
        },
        onLongPress: () => _rename(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: active ? Aether.surfaceRaised : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                  session.messages.any((m) => m.kind == MsgKind.imageGen)
                      ? Icons.image_outlined
                      : Icons.chat_bubble_outline,
                  size: 14,
                  color: active ? Aether.accent : Aether.textFaint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
                            color:
                                active ? Aether.text : Aether.textMuted)),
                    const SizedBox(height: 2),
                    Text(session.model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10.5, color: Aether.textFaint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _rename(BuildContext context) {
    final c = TextEditingController(text: session.title);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename session',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: TextField(
            controller: c, autofocus: true,
            style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              AppState.I.renameSession(session.id, c.text.trim());
              Navigator.pop(context);
            },
            child: const Text('Save',
                style: TextStyle(color: Aether.accent)),
          ),
        ],
      ),
    );
  }
}
