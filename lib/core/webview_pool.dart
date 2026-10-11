/// Bounds how many browser tabs keep a live native WebView.
///
/// Every WebView holds a renderer, page DOM and JS heap. Keeping one per tab
/// for every session ever browsed got the app OOM-killed on 3-4 GB devices
/// (taking any running agent with it). The pool tracks tabs in recency order
/// and, past [maxLive], calls [release] on the least recently used tab that is
/// not pinned. A released tab keeps its URL and title; its WebView is created
/// again (and the page reloaded) the next time it is shown or driven.
class LruWebViewPool<T extends Object> {
  LruWebViewPool({this.maxLive = 3, required this.release})
    : assert(maxLive > 0);

  final int maxLive;
  final void Function(T item) release;

  /// Least recently used first.
  final List<T> _live = <T>[];

  /// Tabs holding a live WebView, least recently used first.
  List<T> get live => List<T>.unmodifiable(_live);

  /// Marks [item] as just used. Evicts the oldest unpinned tabs beyond
  /// [maxLive]; [item] itself is never evicted by its own touch.
  void touch(T item, {Set<T> pinned = const {}}) {
    if (_live.isNotEmpty && identical(_live.last, item)) return;
    _live.remove(item);
    _live.add(item);
    var i = 0;
    while (_live.length > maxLive && i < _live.length - 1) {
      final candidate = _live[i];
      if (pinned.contains(candidate)) {
        i++;
        continue;
      }
      _live.removeAt(i);
      release(candidate);
    }
  }

  /// Stops tracking [item] without releasing it (closed or deleted tab).
  void forget(T item) => _live.remove(item);

  /// Memory pressure: release every tracked tab except [keep].
  void releaseAllExcept(Set<T> keep) {
    for (final item in List<T>.of(_live)) {
      if (keep.contains(item)) continue;
      _live.remove(item);
      release(item);
    }
  }
}
