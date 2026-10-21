import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
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

/// Storage overview with a plan quota bar, a category breakdown, ways to free
/// up room and a per-item size list.
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

  double get _usedGb => _usedBytes / _bytesPerGb;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Storage'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 6));
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (data.isEmpty) {
      return OEmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Storage is empty',
        message:
            'Chats, artifacts, and memory will show up here as you use Ovid.',
        action: OButton(
          label: 'See plans',
          icon: Icons.arrow_forward_rounded,
          onPressed: data.onGoUpgrade,
        ),
      );
    }
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _storageBreakdown(context),
            _overview(context),
            _freeUpSpace(context),
            _largestItems(context),
            _upgrade(context),
            if (data.offlineLabel != null && data.offlineLabel!.isNotEmpty)
              _offlineNote(context),
          ],
        ),
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
          title: 'What uses space',
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

  Widget _overview(BuildContext context) {
    final c = OColors.of(context);
    final ratio = _totalGb <= 0
        ? 0.0
        : (_usedGb / _totalGb).clamp(0, 1).toDouble();
    final percent = (ratio * 100).round();
    final freeGb = (_totalGb - _usedGb).clamp(0, _totalGb).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Column(
          children: [
            Text(
              '${_gb(_usedGb)} GB of ${_gb(_totalGb)} GB cloud storage used · ${_gb(freeGb)} GB free',
              textAlign: TextAlign.center,
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            Container(
              key: const ValueKey('storage-plan-quota'),
              padding: const EdgeInsets.all(OSpace.m),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          data.planName.isEmpty ? 'Your plan' : data.planName,
                          style: OType.caption.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: OSpace.s),
                      Flexible(
                        child: Text(
                          data.quotaLabel.isEmpty
                              ? '$percent% used'
                              : data.quotaLabel,
                          textAlign: TextAlign.end,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: OSpace.s),
                  OProgressBar(
                    key: const ValueKey('storage-quota-bar'),
                    value: ratio,
                    height: 8,
                  ),
                  const SizedBox(height: OSpace.s),
                  Text(
                    '${_gb(freeGb)} GB free on this plan',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _freeUpSpace(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Free up space',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              'Recommendations',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _actionRow(
                  context,
                  icon: Icons.layers_clear_outlined,
                  title: 'Clear previews',
                  subtitle:
                      '${data.previewSizeLabel} · Temporary renders and screenshots',
                  action: OButton(
                    label: 'Clear',
                    variant: OButtonVariant.secondary,
                    onPressed: () => _clearPreviews(context),
                  ),
                ),
                if (data.showCache) ...[
                  Divider(color: c.hairline, height: 1),
                  OListRow(
                    key: const ValueKey('clear-cache-row'),
                    icon: Icons.cleaning_services_outlined,
                    title: 'Clear cache',
                    subtitle:
                        '${data.cacheSizeLabel} · Temporary files on this phone you can rebuild',
                    showChevron: false,
                    onTap: () => _clearCache(context),
                    trailing: _stacksActions(context)
                        ? null
                        : OPill(label: data.cacheSizeLabel),
                  ),
                ],
                Divider(color: c.hairline, height: 1),
                OListRow(
                  icon: Icons.forum_outlined,
                  title: 'Delete old chats',
                  subtitle: 'Archive or remove chats older than 60 days',
                  onTap: data.onDeleteOldChats,
                ),
                Divider(color: c.hairline, height: 1),
                _actionRow(
                  context,
                  icon: Icons.delete_sweep_outlined,
                  title:
                      'Trash · ${data.trashItems} ${data.trashItems == 1 ? 'item' : 'items'}',
                  subtitle:
                      '${data.trashSizeLabel} · Deleted in the last 30 days',
                  danger: true,
                  action: OButton(
                    label: 'Empty',
                    variant: OButtonVariant.danger,
                    onPressed: data.onEmptyTrash,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Clears the render cache. When the owner supplies a callback it owns the
  /// real work; otherwise the in-memory image cache is dropped here, which is
  /// the preview data this build actually keeps.
  void _clearPreviews(BuildContext context) {
    final callback = data.onClearPreviews;
    if (callback != null) {
      callback();
      return;
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          key: ValueKey('clear-previews-result'),
          content: Text('Previews cleared.'),
        ),
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

  /// A row whose action button sits beside the text normally and under it when
  /// the user's text size is large. Keeping the button in the trailing slot at
  /// 200 % squeezes the title to a few pixels wide.
  Widget _actionRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required OButton action,
    bool danger = false,
  }) {
    OListRow row({Widget? trailing}) => OListRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      danger: danger,
      showChevron: false,
      trailing: trailing,
    );
    if (!_stacksActions(context)) return row(trailing: action);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(),
        Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.m),
          child: SizedBox(width: double.infinity, child: action),
        ),
      ],
    );
  }

  Widget _largestItems(BuildContext context) {
    final c = OColors.of(context);
    final count = data.largestItems.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Items by size',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              '$count ${count == 1 ? 'item' : 'items'}',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (data.largestItems.isEmpty)
            OCard(
              child: Text(
                'Nothing large yet. Big chats and files will show up here.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < data.largestItems.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    OListRow(
                      key: ValueKey('storage-item-${data.largestItems[i].id}'),
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(ORadius.m),
                        ),
                        child: Icon(
                          data.largestItems[i].icon,
                          size: 19,
                          color: c.textMuted,
                        ),
                      ),
                      title: data.largestItems[i].name,
                      // At large text sizes the size label moves into the
                      // subtitle so the row cannot overflow or squeeze the
                      // name into a one-character column.
                      subtitle: _stacksActions(context)
                          ? '${data.largestItems[i].detail} · ${data.largestItems[i].sizeLabel}'
                          : data.largestItems[i].detail,
                      showChevron: false,
                      onTap: data.onLargestItemTap == null
                          ? null
                          : () =>
                                data.onLargestItemTap!(data.largestItems[i].id),
                      trailing: _stacksActions(context)
                          ? null
                          : Text(
                              data.largestItems[i].sizeLabel,
                              style: OType.bodyStrong.copyWith(color: c.text),
                            ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _upgrade(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        accent: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    Icons.cloud_upload_outlined,
                    size: 24,
                    color: c.onAccent,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: OSpace.s,
                        runSpacing: OSpace.xs,
                        children: [
                          Text(
                            'Need more room?',
                            style: OType.h2.copyWith(color: c.text),
                          ),
                          const OPill(label: 'Upgrade', tone: OPillTone.accent),
                        ],
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        'Upgrade for 5 GB with Ovid Go, 15 GB with Plus or 75 GB '
                        'with Pro.',
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'See plans',
              icon: Icons.arrow_forward_rounded,
              onPressed: data.onGoUpgrade,
            ),
          ],
        ),
      ),
    );
  }

  Widget _offlineNote(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_rounded, size: 18, color: c.textFaint),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              data.offlineLabel!,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ),
        ],
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
/// bytes actually freed. Visible so the clear-cache row can be tested without
/// a platform plugin.
@visibleForTesting
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

/// True when the text scale is large enough that a row's action must move to
/// its own line. 1.5× is the point where a trailing 48 dp button leaves less
/// than half the row for the label at 320 dp.
bool _stacksActions(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) >= 14 * 1.5;
