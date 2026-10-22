import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'plan_billing_page.dart' show V2PlanLimits;
import 'settings_rows.dart';
import 'storage_breakdown.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

const int _bytesPerGb = 1024 * 1024 * 1024;

/// Cloud storage included with a plan, in GB, read from the authoritative plan
/// table ([V2PlanLimits]) so Free/Go/Plus/Pro can never drift from 3 / 5 / 15 /
/// 75 GB.
///
/// Accepts a plan id (`free`, `go`, `plus`, `pro`), a server tier id (`3x`,
/// `7x`, `15x`) or a display name (`Free plan`, `Ovid Plus`). Returns null for
/// a plan the table does not know, so the screen renders "—" instead of
/// inventing a quota.
double? v2PlanStorageQuotaGb(String plan) {
  final raw = plan.trim().toLowerCase();
  if (raw.isEmpty) return null;
  final limits =
      V2PlanLimits.forId(raw) ??
      V2PlanLimits.forId(raw.replaceAll(RegExp(r'\s+plan$'), ''));
  return limits?.storageGb.toDouble();
}

/// One coloured part of the storage bar and its legend row.
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
/// made-up usage figures. An empty size label means "not reported" and renders
/// "—", never 0.
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
    this.cacheSizeLabel = '',
    this.showCache = true,
    this.previewSizeLabel = '',
    this.trashItems = 0,
    this.trashSizeLabel = '',
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
      v2PlanStorageQuotaGb(planName) == null &&
      slices.isEmpty &&
      artifactsGb + sessionsGb + cacheGb <= 0;
}

/// Storage overview: one bar, its legend (the breakdown) and one clean-up
/// row.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.data});

  final V2StoragePageData data;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  /// Cache bytes after the last measured clear. Null until the row has run, so
  /// the caller's measurement stays authoritative.
  int? _cacheAfterClear;

  /// True while the clear is in flight: the row is disabled and shows a
  /// progress indicator instead of accepting a second tap.
  bool _clearing = false;

  V2StoragePageData get data => widget.data;

  @override
  void didUpdateWidget(StoragePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reload from the host is fresher than our post-clear figure.
    if (oldWidget.data.cacheGb != data.cacheGb ||
        oldWidget.data.cacheSizeLabel != data.cacheSizeLabel) {
      _cacheAfterClear = null;
    }
  }

  /// The plan's canonical quota. A recognised plan name always wins over a
  /// caller-supplied total so Free/Go/Plus/Pro show 3/5/15/75 GB even when a
  /// stale screen state carries an older number. Null when neither the plan
  /// table nor the caller knows the capacity.
  double? get _totalGb {
    final quota = v2PlanStorageQuotaGb(data.planName);
    if (quota != null) return quota;
    return data.totalGb > 0 ? data.totalGb : null;
  }

  /// Cache bytes the caller measured, taking the larger of the explicit field
  /// and a matching slice so the row and the legend never disagree.
  int get _dataCacheBytes {
    var bytes = _toBytes(data.cacheGb);
    final slice = _slice('cache');
    if (slice != null && _toBytes(slice.valueGb) > bytes) {
      bytes = _toBytes(slice.valueGb);
    }
    return bytes;
  }

  int get _cacheBytes => _cacheAfterClear ?? _dataCacheBytes;

  /// Bytes removed from the caller's used total by a measured clear, so a
  /// total that already counted the cache drops by exactly what was freed.
  int get _removedCacheBytes {
    final removed = _dataCacheBytes - _cacheBytes;
    return removed > 0 ? removed : 0;
  }

  /// Used space as one number for the whole page. When the category detail
  /// accounts for more than the caller's total, the detail wins: the heading
  /// and the breakdown must never disagree about the same bytes.
  int get _entryBytes =>
      _breakdownEntries().fold<int>(0, (sum, entry) => sum + entry.safeBytes);

  int get _usedBytes {
    final callerBytes = _toBytes(data.usedGb) - _removedCacheBytes;
    final caller = callerBytes > 0 ? callerBytes : 0;
    return _entryBytes > caller ? _entryBytes : caller;
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Storage',
      subtitle: data.planName.isEmpty ? null : data.planName,
      // One calm column: 640 dp is the widest this screen ever gets, so a
      // desktop window adds margin instead of a longer legend line.
      maxWidth: 640,
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
    final totalGb = _totalGb;
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
          totalBytes: totalGb == null ? 0 : _toBytes(totalGb),
          // An unknown capacity is a dash, never a made-up 0 GB.
          totalLabel: totalGb == null ? '—' : _gbLabel(totalGb),
          entries: reconciled.entries,
          onRetry: data.onRetry,
        ),
      ),
    );
  }

  /// Maps the page's slices and the three spec categories onto the shared
  /// breakdown buckets. A slice keeps its exact size label so a value the
  /// server formatted ("410 MB") is never re-rounded from GB. A category with
  /// no bytes is omitted rather than drawn as an empty segment.
  List<V2StorageCategoryBytes> _breakdownEntries() {
    final byCategory = <V2StorageCategory, V2StorageCategoryBytes>{};
    for (final slice in data.slices) {
      final bytes = _toBytes(slice.valueGb);
      if (bytes <= 0) continue;
      final category = _categoryForLabel(slice.label);
      byCategory[category] = V2StorageCategoryBytes(
        category: category,
        bytes: bytes,
        sizeLabel: slice.sizeLabel,
      );
    }

    void addIfMissing(V2StorageCategory category, _CategorySize size) {
      if (byCategory.containsKey(category)) return;
      final bytes = _toBytes(size.gb);
      if (bytes <= 0) return;
      byCategory[category] = V2StorageCategoryBytes(
        category: category,
        bytes: bytes,
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

    // A measured clear replaces the caller's cache figure. Zero means the
    // cache is gone, so its segment leaves the bar instead of shrinking to 0.
    if (_cacheAfterClear != null) {
      if (_cacheBytes <= 0) {
        byCategory.remove(V2StorageCategory.cache);
      } else {
        byCategory[V2StorageCategory.cache] = V2StorageCategoryBytes(
          category: V2StorageCategory.cache,
          bytes: _cacheBytes,
          sizeLabel: formatStorageBytes(_cacheBytes),
        );
      }
    }

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

  /// The cache size shown on the clean-up row. "—" when the caller reported no
  /// cache figure at all; a measured zero stays "0 MB".
  String? get _cacheValue {
    if (!data.showCache) return null;
    if (_cacheAfterClear != null) return _formatCacheBytes(_cacheAfterClear!);
    if (data.cacheSizeLabel.isNotEmpty) return data.cacheSizeLabel;
    if (_dataCacheBytes > 0) return formatStorageBytes(_dataCacheBytes);
    return '—';
  }

  /// One bar plus the legend live in [StorageBreakdown]; this is the page's
  /// only clean-up row. It always works: a host callback wins, otherwise the
  /// page clears the app's own temporary directory and reports the real bytes.
  Widget _cleanUpRow(BuildContext context) {
    return V2SettingsRowList(
      rows: [
        Semantics(
          button: true,
          enabled: !_clearing,
          label: _clearCacheLabel,
          onTap: _clearing ? null : () => _clearCache(context),
          child: ExcludeSemantics(
            child: V2SettingsRow(
              key: const ValueKey<String>('storage-clear-cache-row'),
              icon: Icons.cleaning_services_outlined,
              title: 'Clear cache',
              value: _clearing ? null : _cacheValue,
              trailing: _clearing
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: OSpace.s),
                      child: SizedBox(
                        key: ValueKey('storage-clear-cache-progress'),
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
              showChevron: false,
              enabled: !_clearing,
              onTap: _clearing ? null : () => _clearCache(context),
            ),
          ),
        ),
      ],
    );
  }

  /// The action announces what it will free, not just its name.
  String get _clearCacheLabel {
    if (_clearing) return 'Clearing cache';
    final value = _cacheValue;
    if (value == null || value == '—' || _cacheBytes <= 0) {
      return 'Clear cache';
    }
    return 'Clear cache, $value will be freed';
  }

  /// Clears the on-device cache and reports the bytes that were actually
  /// freed. The page measures the temporary directory before and after, so the
  /// confirmation is a real number rather than the size label the caller
  /// supplied earlier.
  Future<void> _clearCache(BuildContext context) async {
    if (_clearing) return;
    setState(() => _clearing = true);

    var freed = 0;
    var measured = true;
    Object? failure;
    try {
      final reporter = data.onClearCacheAndReport;
      if (reporter != null) {
        freed = await reporter();
      } else if (data.onClearCache != null) {
        data.onClearCache!();
        // A void callback reports no measurement; keep the last real figure
        // instead of pretending the cache is empty.
        measured = false;
      } else {
        freed = await clearTemporaryCache();
      }
    } catch (error) {
      failure = error;
    }

    if (!mounted) return;
    setState(() {
      _clearing = false;
      if (failure == null && measured) {
        final remaining = _cacheBytes - freed;
        _cacheAfterClear = remaining > 0 ? remaining : 0;
      }
    });

    if (!context.mounted) return;
    if (failure != null) {
      _snack(context, 'Could not clear the cache. Try again.');
    } else if (!measured) {
      _snack(context, 'Cache cleared.');
    } else {
      _snackFreed(context, freed);
    }
  }

  void _snackFreed(BuildContext context, int freed) {
    _snack(
      context,
      freed > 0
          ? 'Freed ${formatStorageBytes(freed)} of cache.'
          : 'Cache is already empty.',
    );
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('clear-cache-result'),
          content: Text(message),
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
      label: explicitLabel.isNotEmpty ? explicitLabel : slice?.sizeLabel ?? '',
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

/// "3 GB" for a whole quota, "1.5 GB" otherwise.
String _gbLabel(double gb) {
  final whole = gb == gb.roundToDouble();
  return '${whole ? gb.toStringAsFixed(0) : gb.toStringAsFixed(1)} GB';
}

/// A measured zero is "0 MB"; a real freed figure keeps its unit.
String _formatCacheBytes(int bytes) =>
    bytes <= 0 ? '0 MB' : formatStorageBytes(bytes);

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
