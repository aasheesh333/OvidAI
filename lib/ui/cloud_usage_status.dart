import 'package:flutter/material.dart';

import '../core/cloud_usage_store.dart';

/// Shared freshness/error wording for both allowance surfaces.
class CloudUsageStatus extends StatelessWidget {
  const CloudUsageStatus({super.key, required this.store});
  final CloudUsageStore store;

  @override
  Widget build(BuildContext context) {
    if (!store.stale && store.error == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (store.usage != null)
          const Text(
            'Last known allowance · may be out of date',
            style: TextStyle(fontSize: 11),
          ),
        if (store.error != null)
          Text(store.error!, style: const TextStyle(fontSize: 11)),
        if (store.error != null)
          TextButton(onPressed: store.refresh, child: const Text('Retry')),
        if (store.loading)
          const Text('Refreshing allowance…', style: TextStyle(fontSize: 11)),
      ],
    );
  }
}
