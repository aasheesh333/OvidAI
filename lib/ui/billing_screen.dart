import 'package:flutter/material.dart';

import '../core/cloud_usage_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'money_screen.dart';

/// Plans & Billing route — the Money surface's plans view with the shared
/// plan hero on top.
///
/// The plan tiles (Free, Plus ₹499, Pro ₹899, Max ₹1699 — INR only), the
/// hero, and the checkout sheet all live in `money_screen.dart`; plan names,
/// multipliers, and prices come from [PlanIdentity]. "Pay now" routes through
/// `OvidCloudService.upgrade` (server-gated by the test-upgrade env).
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
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
        toolbarHeight: MediaQuery.textScalerOf(context).scale(20) > 30 ? 88 : 56,
        title: const Text('Plans & Billing'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          MoneyPlanHero(store: _store),
          MoneyPlansView(store: _store),
        ],
      ),
    );
  }
}
