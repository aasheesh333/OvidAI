import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';
import 'storage_breakdown.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

const int _bytesPerGb = 1024 * 1024 * 1024;

/// Cloud storage included with each plan, in GB. The single source the screen
/// uses, so Free/Go/Plus/Pro can never drift from 3 / 5 / 15 / 75 GB.
const Map<String, double> v2PlanStorageGb = <String, double>{
  'free': 3,
  'go': 5,
  'plus': 15,
  'pro': 75,
  // Server tier ids used by the plan catalogue.
  '3x': 5,
  '7x': 15,
  '15x': 75,
};

/// Quota for a plan name or tier id, or null when the caller's plan is not one
/// of the four known plans.
double? v2PlanStorageQuotaGb(String plan) {
  final key = plan.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (key.isEmpty) return null;
  for (final entry in v2PlanStorageGb.entries) {
    if (key == entry.key || key.startsWith(entry.key)) return entry.value;
  }
  return null;
}

/// One coloured part of the storage donut and its legend row.
@immutable
class V2StorageSlice {
  const V2StorageSlice({
    required this.label,
    required this.sizeLabel,
    required this.valueGb,
  });

  final String label;
  final String sizeLabel;
  final double valueGb;
}

/// One large file or chat shown in the "Items by size" list.
@immutable
class V2StorageItem {
  const V2StorageItem({
    required this.id,
    required this.name,
    required this.detail,
    required this.sizeLabel,
    this.icon = Icons.insert_drive_file_outlined,
  });

  final String id;
  final String name;
  final String detail;
  final String sizeLabel;
  final IconData icon;
}

/// Injected state for the Storage screen.
///
/// Every number and size string is supplied by the caller: the defaults are
/// deliberately empty so an un-wired screen shows the empty state instead of
/// made-up usage figures.
@immutable
class V2StoragePageData {
  const V2StoragePageData({
    this.usedGb = 0,
    this.totalGb = 0,
    this.planName = '',
    this.quotaLabel = '',
    this.slices = const <V2StorageSlice>[],
    this.artifactsGb = 0,
    this.artifactsSizeLabel = '',
    this.sessionsGb = 0,
    this.sessionsSizeLabel = '',
    this.cacheGb = 0,
    this.cacheSizeLabel = '0 MB',
    this.showCache = true,
    this.previewSizeLabel = '0 MB',
    this.trashItems = 0,
    this.trashSizeLabel = '0 MB',
    this.largestItems = const <V2StorageItem>[],
    this.offlineLabel,
    this.loading = false,
    this.errorMessage,
    this.onClearPreviews,
    this.onClearCache,
    this.onClearCacheAndReport,
    this.onDeleteOldChats,
    this.onEmptyTrash,
    this.onLargestItemTap,
    this.onGoUpgrade,
    this.onRetry,
  });

  final double usedGb;
  final double totalGb;

  /// Plan shown beside the quota bar, for example "Free plan".
  final String planName;

  /// Optional plan quota note, for example "3 GB included".
  final String quotaLabel;
  final List<V2StorageSlice> slices;

  /// Breakdown by the three categories the spec names. When a value is left
  /// empty the screen falls back to a matching slice, so existing callers keep
  /// working without duplicating numbers.
  final double artifactsGb;
  final String artifactsSizeLabel;
  final double sessionsGb;
  final String sessionsSizeLabel;
  final double cacheGb;
  final String cacheSizeLabel;

  /// Cache lives on the phone. The row is hidden when this is false.
  final bool showCache;
  final String previewSizeLabel;
  final int trashItems;
  final String trashSizeLabel;
  final List<V2StorageItem> largestItems;

  /// Sync note shown under the page. Hidden when null.
  final String? offlineLabel;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onClearPreviews;
  final VoidCallback? onClearCache;

  /// Clears the on-device cache and returns the bytes actually freed. When
  /// null the page measures and clears the temporary directory itself, so the
  /// row still works on a screen whose owner only supplied display data.
  final Future<int> Function()? onClearCacheAndReport;
  final VoidCallback? onDeleteOldChats;
  final VoidCallback? onEmptyTrash;
  final ValueChanged<String>? onLargestItemTap;
  final VoidCallback? onGoUpgrade;
  final VoidCallback? onRetry;

  bool get isEmpty =>
      usedGb <= 0 &&
      totalGb <= 0 &&
      slices.isEmpty &&
      artifactsGb + sessionsGb + cacheGb <= 0;
}

/// Storage overview: one bar, its legend (the breakdown) and one clean-up
/// row.
class StoragePage extends StatelessWidget {
  const StoragePage({super.key, required this.data});

  final V2StoragePageData data;

  /// The plan's canonical quota. A recognised plan name always wins over a
  /// caller-supplied total so Free/Go/Plus/Pro show 3/5/15/75 GB even when a
  /// stale screen state carries an older number.
  double get _totalGb => v2PlanStorageQuotaGb(data.planName) ?? data.totalGb;

  /// Used space as one number for the whole page. When the category detail
  /// accounts for more than the caller's total, the detail wins: the heading
  /// and the breakdown must never disagree about the same bytes.
  int get _entryBytes =>
      _breakdownEntries().fold<int>(0, (sum, entry) => sum + entry.safeBytes);

  int get _usedBytes =>
      _entryBytes > _toBytes(data.usedGb) ? _entryBytes : _toBytes(data.usedGb);

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Storage',
      subtitle: data.planName.isEmpty ? null : data.planName,
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) return const OSkeletonList(rows: 6);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (data.isEmpty) {
      return OEmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Storage is empty',
        message: 'Chats, artifacts and memory appear here.',
        action: data.onGoUpgrade == null
            ? null
            : OButton(
                label: 'See plans',
                icon: Icons.arrow_forward_rounded,
                onPressed: data.onGoUpgrade,
              ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _storageBreakdown(context),
          const SizedBox(height: OSpace.l),
          _cleanUpRow(context),
        ],
      ),
    );
  }

  Widget _storageBreakdown(BuildContext context) {
    final reconciled = reconcileStorageBreakdown(
      _breakdownEntries(),
      _usedBytes,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: StorageBreakdown(
        key: const ValueKey('storage-breakdown'),
        data: V2StorageBreakdownData(
          usedBytes: reconciled.usedBytes,
          totalBytes: _toBytes(_totalGb),
          totalLabel: _totalGb > 0 ? '${_gb(_totalGb)} GB' : '',
          entries: reconciled.entries,
          onRetry: data.onRetry,
        ),
      ),
    );
  }

  /// Maps the page's slices and the three spec categories onto the shared
  /// breakdown buckets. A slice keeps its exact size label so a value the
  /// server formatted ("410 MB") is never re-rounded from GB.
  List<V2StorageCategoryBytes> _breakdownEntries() {
    final byCategory = <V2StorageCategory, V2StorageCategoryBytes>{};
    for (final slice in data.slices) {
      final category = _categoryForLabel(slice.label);
      byCategory[category] = V2StorageCategoryBytes(
        category: category,
        bytes: _toBytes(slice.valueGb),
        sizeLabel: slice.sizeLabel,
      );
    }

    void addIfMissing(V2StorageCategory category, _CategorySize size) {
      if (byCategory.containsKey(category)) return;
      if (size.gb <= 0 && (size.label.isEmpty || size.label == '0 MB')) return;
      byCategory[category] = V2StorageCategoryBytes(
        category: category,
        bytes: _toBytes(size.gb),
        sizeLabel: size.label,
      );
    }

    addIfMissing(
      V2StorageCategory.artifacts,
      _category(
        'artifacts',
        explicitLabel: data.artifactsSizeLabel,
        explicitGb: data.artifactsGb,
      ),
    );
    addIfMissing(
      V2StorageCategory.chats,
      _category(
        'sessions',
        explicitLabel: data.sessionsSizeLabel,
        explicitGb: data.sessionsGb,
      ),
    );
    addIfMissing(
      V2StorageCategory.cache,
      _category(
        'cache',
        explicitLabel: data.cacheSizeLabel,
        explicitGb: data.cacheGb,
      ),
    );

    const order = <V2StorageCategory>[
      V2StorageCategory.artifacts,
      V2StorageCategory.chats,
      V2StorageCategory.memory,
      V2StorageCategory.uploads,
      V2StorageCategory.previews,
      V2StorageCategory.cache,
    ];
    return [
      for (final category in order)
        if (byCategory[category] != null) byCategory[category]!,
    ];
  }

  V2StorageCategory _categoryForLabel(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('artifact')) return V2StorageCategory.artifacts;
    if (lower.contains('memory')) return V2StorageCategory.memory;
    if (lower.contains('upload')) return V2StorageCategory.uploads;
    if (lower.contains('preview')) return V2StorageCategory.previews;
    if (lower.contains('cache')) return V2StorageCategory.cache;
    // Sessions and chats are the same bucket in the shared breakdown.
    return V2StorageCategory.chats;
  }

  /// One bar plus the legend live in [StorageBreakdown]; this is the page's
  /// only clean-up row. It always works: a host callback wins, otherwise the
  /// page clears the app's own temporary directory and reports the real bytes.
  Widget _cleanUpRow(BuildContext context) {
    return V2SettingsRowList(
      rows: [
        V2SettingsRow(
          key: const ValueKey<String>('storage-clear-cache-row'),
          icon: Icons.cleaning_services_outlined,
          title: 'Clear cache',
          value: data.showCache ? data.cacheSizeLabel : null,
          showChevron: false,
          onTap: () => _clearCache(context),
        ),
      ],
    );
  }

  /// Clears the on-device cache and reports the bytes that were actually
  /// freed. The page measures the temporary directory before and after, so the
  /// confirmation is a real number rather than the size label the caller
  /// supplied earlier.
  Future<void> _clearCache(BuildContext context) async {
    final reporter = data.onClearCacheAndReport;
    if (reporter != null) {
      final freed = await reporter();
      if (!context.mounted) return;
      _snackFreed(context, freed);
      return;
    }
    if (data.onClearCache != null) {
      data.onClearCache!();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            key: ValueKey('clear-cache-result'),
            content: Text('Cache cleared.'),
          ),
        );
      return;
    }
    try {
      final freed = await clearTemporaryCache();
      if (!context.mounted) return;
      _snackFreed(context, freed);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Could not clear the cache. Try again.'),
          ),
        );
    }
  }

  void _snackFreed(BuildContext context, int freed) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('clear-cache-result'),
          content: Text(
            freed > 0
                ? 'Freed ${formatStorageBytes(freed)} of cache.'
                : 'Cache is already empty.',
          ),
        ),
      );
  }

  _CategorySize _category(
    String key, {
    required String explicitLabel,
    required double explicitGb,
  }) {
    final slice = _slice(key);
    return _CategorySize(
      label: explicitLabel.isNotEmpty
          ? explicitLabel
          : slice?.sizeLabel ?? '0 MB',
      gb: explicitGb > 0 ? explicitGb : slice?.valueGb ?? 0,
    );
  }

  V2StorageSlice? _slice(String key) {
    for (final slice in data.slices) {
      final label = slice.label.toLowerCase();
      final matches = key == 'sessions'
          ? label.contains('session') || label.contains('chat')
          : label.contains(key);
      if (matches) return slice;
    }
    return null;
  }
}

class _CategorySize {
  const _CategorySize({required this.label, required this.gb});

  final String label;
  final double gb;
}

String _gb(double value) => value.toStringAsFixed(1);

int _toBytes(double gb) => (gb <= 0 ? 0 : gb * _bytesPerGb).round();

/// Deletes everything inside the app's temporary directory and returns the
/// bytes actually freed. Shared by the Storage and Data control clean-up
/// rows, and visible so a test can drive the row without a platform plugin.
Future<int> clearTemporaryCache() async {
  final dir = await getTemporaryDirectory();
  if (!await dir.exists()) return 0;
  final before = await _dirBytes(dir);
  await for (final entity in dir.list(followLinks: false)) {
    try {
      await entity.delete(recursive: true);
    } catch (_) {
      // A file in use is skipped; the byte difference reports what went.
    }
  }
  final after = await _dirBytes(dir);
  return (before - after).clamp(0, before);
}

Future<int> _dirBytes(Directory dir) async {
  var bytes = 0;
  final stack = <Directory>[dir];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    try {
      await for (final entity in current.list(followLinks: false)) {
        if (entity is File) {
          try {
            bytes += await entity.length();
          } catch (_) {
            // Skip unreadable entries; they are not part of the report.
          }
        } else if (entity is Directory) {
          stack.add(entity);
        }
      }
    } catch (_) {
      // Skip unreadable directories.
    }
  }
  return bytes;
}
