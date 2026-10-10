/// In-memory cache for derived private-sync projections.
///
/// This cache is deliberately disposable: it contains presentation projections
/// only and can be rebuilt from the account's durable records. It has no
/// persistence, Flutter, executor, or runtime-state dependencies.
library;

/// Stores account-scoped projections keyed by their source record.
class PrivateSyncCache<K, V> {
  final Map<_CacheKey<K>, V> _entries = <_CacheKey<K>, V>{};

  /// Stores [value] as the current projection for [recordId].
  void put(K accountId, K recordId, V value) {
    _entries[_CacheKey(accountId, recordId)] = value;
  }

  /// Returns the cached projection, or `null` when it is absent.
  V? get(K accountId, K recordId) =>
      _entries[_CacheKey(accountId, recordId)];

  /// Removes one cached projection.
  void remove(K accountId, K recordId) {
    _entries.remove(_CacheKey(accountId, recordId));
  }

  /// Invalidates projections derived from a changed record.
  void invalidateRecord(K accountId, K recordId) {
    remove(accountId, recordId);
  }

  /// Invalidates projections derived from a record deleted by a tombstone.
  void invalidateTombstone(K accountId, K recordId) {
    remove(accountId, recordId);
  }

  /// Invalidates every projection belonging to [accountId].
  void clearAccount(K accountId) {
    _entries.removeWhere((key, value) => key.accountId == accountId);
  }

  /// Disposes all cached projections while leaving the cache reusable.
  void clear() {
    _entries.clear();
  }
}

class _CacheKey<K> {
  const _CacheKey(this.accountId, this.recordId);

  final K accountId;
  final K recordId;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey<K> &&
      other.accountId == accountId &&
      other.recordId == recordId;

  @override
  int get hashCode => Object.hash(accountId, recordId);
}
