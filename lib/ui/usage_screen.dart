import 'package:flutter/material.dart';

import '../core/cloud_usage_store.dart';
import '../core/image_studio.dart';
import '../core/ovid_cloud_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'image_receipt_panel.dart';
import 'money_screen.dart';

export 'money_screen.dart' show ProviderUsage, ProviderUsageScreen;

/// Usage route — the shared plan hero plus [MoneyUsageView] (per-model
/// remaining allowance and device-measured BYOK usage), with account-scoped
/// image receipts behind the app-bar menu.
///
/// The implementation lives in `money_screen.dart` so the Money surface and
/// this route render the same widgets; remaining allowance stays
/// server-authoritative via [CloudUsageStore] and costs are never rendered.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late final CloudUsageStore _store;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
  }

  @override
  void dispose() {
    _store.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Usage'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More actions',
            icon: Icon(Icons.more_vert, color: Aether.textMuted),
            onSelected: (value) {
              if (value == 'image-receipts') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ImageReceiptsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'image-receipts',
                child: Text('Image receipts'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // Usage presents the persisted local plan while the server is
          // unreachable; the billing surfaces never do.
          MoneyPlanHero(store: _store, trustPersistedTier: true),
          MoneyUsageView(store: _store, includeReceipts: false),
        ],
      ),
    );
  }
}

/// Route hosting the account-scoped [ImageReceiptPanel], reachable from the
/// Usage app bar menu. The panel is read-only: status checks are GET
/// recoveries against the saved request identity and never submit new paid
/// image work. Bound to the singleton studio and the current cloud key.
class ImageReceiptsScreen extends StatelessWidget {
  const ImageReceiptsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Image receipts'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: [
          ImageReceiptPanel(
            studio: ImageStudio.I,
            headers: OvidCloudService.I.imageHeaders,
          ),
        ],
      ),
    );
  }
}
