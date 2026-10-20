import 'dart:async';

import 'package:flutter/foundation.dart';

import '../session_artifacts.dart';
import 'cloud_rest.dart';
import 'models.dart';

/// The account Artifact Vault (FE-004/005/022): one inventory over every
/// file the account owns — Ovid-generated artifacts and user uploads —
/// served by the gateway's `/cloud/v1/artifacts` surface.
///
/// The inventory DTO ([VaultArtifact]) is AUTHORITATIVE cloud identity: `id`
/// is the gateway row id (never a local transcript id), and it carries no
/// saved URL or storage key. Rows are intent — availability stays
/// "unverified" until a mint. The source (`origin`) is derived from which
/// canonical table the server read, never guessed from a URL.

/// One inventory row as the gateway serves it (GET /artifacts items[]).
@immutable
class VaultArtifact {
  const VaultArtifact({
    required this.id,
    required this.sessionId,
    required this.name,
    required this.origin,
    required this.category,
    required this.contentType,
    required this.sizeBytes,
    required this.createdAt,
    this.sessionTitle,
    this.availability = 'unverified',
  });

  factory VaultArtifact.fromJson(Map<String, dynamic> j) => VaultArtifact(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String,
        sessionTitle: j['sessionTitle'] as String?,
        name: j['name'] as String,
        origin: j['origin'] as String? ?? 'generated',
        category: j['category'] as String? ?? 'other',
        contentType: j['contentType'] as String? ?? 'application/octet-stream',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        availability: j['availability'] as String? ?? 'unverified',
      );

  /// The gateway row id — the mint route's :id input.
  final String id;

  /// 'generated' (Ovid-produced) or 'uploaded' (user attachment) — the
  /// canonical source table the row came from, per the server.
  final String origin;

  final String sessionId;
  final String? sessionTitle;
  final String name;
  final String category;
  final String contentType;
  final int sizeBytes;
  final DateTime createdAt;
  final String availability;

  /// Adapts the authoritative cloud row onto the preview widgets' artifact
  /// shape. [accountId] is fenced into [SessionArtifact.cloudAccountId] so a
  /// later mint can prove the artifact still belongs to the current account.
  /// `url`/`path` stay null: preview, download and share mint fresh URLs.
  SessionArtifact toSessionArtifact(String? accountId) => SessionArtifact(
        id: id,
        name: name,
        sessionId: sessionId,
        sessionTitle: sessionTitle ?? '',
        time: createdAt,
        origin: origin == 'uploaded'
            ? ArtifactOrigin.uploaded
            : ArtifactOrigin.generated,
        kind: switch (category) {
          'image' => ArtifactKind.image,
          'html' => ArtifactKind.html,
          'code' => ArtifactKind.code,
          'document' => ArtifactKind.document,
          _ => ArtifactKind.other,
        },
        size: sizeBytes,
        cloudArtifactId: id,
        cloudAccountId: accountId,
      );
}

/// One page of the inventory (GET /artifacts answer shape).
@immutable
class VaultPage {
  const VaultPage({required this.items, this.nextCursor});

  factory VaultPage.fromJson(Map<String, dynamic> j) => VaultPage(
        items: [
          for (final item in (j['items'] as List? ?? <dynamic>[]))
            if (item is Map<String, dynamic>) VaultArtifact.fromJson(item),
        ],
        nextCursor: j['nextCursor'] as String?,
      );

  final List<VaultArtifact> items;
  final String? nextCursor;

  static const VaultPage empty = VaultPage(items: []);
}

/// Client for the account Artifact Vault surface. All requests go through
/// the shared [CloudRestClient] (auth headers, 401 retry, typed errors).
///
/// [accountId] resolves the CURRENT account (`firebase:<uid>`, or null when
/// signed out / guest). A guest never sends a vault request: the inventory
/// is account-scoped, and the local "On this device" path is a separate
/// guest-only view that must never mix with the cloud corpus.
class ArtifactVaultClient {
  ArtifactVaultClient({this.accountId, CloudRestClient? rest})
      : _rest = rest ?? CloudRestClient.I;

  /// The current account id, or null when signed out.
  final String? Function()? accountId;
  final CloudRestClient _rest;

  /// Set after a typed `cdn_not_configured`/`storage_not_configured` answer so
  /// every later mint in this client goes straight to the canonical route
  /// instead of paying a doomed CDN round trip. A new client (e.g. after a
  /// settings change/restart) probes the CDN again.
  bool _cdnUnavailable = false;

  /// The current account id, or null when signed out.
  String? currentAccountId() => accountId?.call();

  /// GET /artifacts — bounded, filtered in SQL server-side. Signed-out
  /// callers get an empty page and send NO request.
  Future<VaultPage> list({
    String? source,
    String? category,
    String? search,
    String? sessionId,
    String? cursor,
    int limit = 30,
  }) async {
    if (currentAccountId() == null) return VaultPage.empty;
    final json = await _rest.getJson('/artifacts', query: <String, String>{
      if (source != null && source.isNotEmpty) 'source': source,
      if (category != null && category.isNotEmpty) 'type': category,
      if (search != null && search.isNotEmpty) 'q': search,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      'limit': '$limit',
    });
    return VaultPage.fromJson(json);
  }

  /// GET /artifacts/:id/url?source=… — a FRESH presigned capability for
  /// [artifact]. Called only on explicit preview / download / share actions,
  /// never for list rows.
  ///
  /// Owner fencing happens BEFORE dispatch: an artifact bound to another
  /// account (or a signed-out caller) throws `(409, account_changed)` and no
  /// request leaves the device — a slow account switch can never leak one
  /// account's capability into another's UI.
  Future<MintedArtifactUrl> mintUrl(SessionArtifact artifact) async {
    final current = currentAccountId();
    if (current == null || artifact.cloudAccountId != current) {
      throw CloudApiException(
        status: 409,
        code: 'account_changed',
        message: 'The account changed. Sign in again to use this file.',
      );
    }
    final id = artifact.cloudArtifactId;
    if (id == null || id.isEmpty) {
      throw CloudApiException(
        status: 400,
        code: 'bad_request',
        message: 'This file has no cloud identity.',
      );
    }
    return MintedArtifactUrl.fromJson(await _rest.getJson(
      '/artifacts/$id/url',
      query: <String, String>{
        'source': artifact.origin == ArtifactOrigin.uploaded
            ? 'uploaded'
            : 'generated',
      },
    ));
  }

  /// W12: prefer the signed CDN capability, falling back to the canonical
  /// presign mint on any CDN-specific failure.
  ///
  /// Called only on explicit preview / download / share actions — never for
  /// list rows. The returned URL is a short-lived bearer capability (15 min
  /// by default) and is never persisted. [download] signs an
  /// `attachment` disposition (share / open-with); previews stay inline.
  ///
  /// Fallback rules:
  ///  - `cdn_not_configured` / `storage_not_configured` (503) → canonical
  ///    `mintUrl`, so a deployment without the CDN behaves exactly as before;
  ///  - typed object verdicts (`artifact_unavailable`, `artifact_incomplete`,
  ///    `artifact_storage_unavailable`) are rethrown: the canonical mint would
  ///    report the same verdict, and the UI's precise message must survive.
  Future<MintedArtifactUrl> mintCdnUrl(
    SessionArtifact artifact, {
    bool download = false,
  }) async {
    final current = currentAccountId();
    if (current == null || artifact.cloudAccountId != current) {
      throw CloudApiException(
        status: 409,
        code: 'account_changed',
        message: 'The account changed. Sign in again to use this file.',
      );
    }
    final id = artifact.cloudArtifactId;
    if (id == null || id.isEmpty) {
      throw CloudApiException(
        status: 400,
        code: 'bad_request',
        message: 'This file has no cloud identity.',
      );
    }
    final source = artifact.origin == ArtifactOrigin.uploaded
        ? 'uploaded'
        : 'generated';
    if (_cdnUnavailable) return mintUrl(artifact);
    try {
      return MintedArtifactUrl.fromJson(await _rest.getJson(
        '/artifacts/$id/cdn-url',
        query: <String, String>{
          'source': source,
          if (download) 'download': '1',
        },
      ));
    } on CloudApiException catch (e) {
      final cdnDisabled = e.code == 'cdn_not_configured' ||
          e.code == 'storage_not_configured';
      if (cdnDisabled) {
        _cdnUnavailable = true;
        return mintUrl(artifact);
      }
      rethrow;
    }
  }

  /// The preferred mint for preview/download/share: CDN when configured,
  /// canonical presign otherwise. Kept as a named seam so call sites express
  /// intent ("fresh capability") without knowing the acceleration layer.
  Future<MintedArtifactUrl> mintPreferredUrl(
    SessionArtifact artifact, {
    bool download = false,
  }) =>
      mintCdnUrl(artifact, download: download);
}

/// Change-notifier driving the Vault screen: fixed pages with an explicit
/// load-more, tab/search/type/session filters, and account/offline fencing.
///
/// Every in-flight page is stamped with an epoch; a filter change, account
/// change or reload supersedes it, so a slow answer for an old tab or an old
/// owner can never repopulate the list. Rows are deduped by the
/// authoritative cloud id, so a retry or an overlapping page never shows a
/// file twice.
class ArtifactVaultController extends ChangeNotifier {
  ArtifactVaultController({
    required this.client,
    ValueListenable<String?>? accountChanges,
    ValueListenable<bool>? online,
  })  : _accountChanges = accountChanges,
        _online = online {
    _account = accountChanges?.value;
    if (accountChanges != null) accountChanges.addListener(_onAccountChanged);
    if (online != null) online.addListener(_onOnlineChanged);
  }

  final ArtifactVaultClient client;
  final ValueListenable<String?>? _accountChanges;
  final ValueListenable<bool>? _online;

  int _epoch = 0;
  String _source = 'generated';
  String? _category;
  String? _search;
  String? _sessionId;
  List<SessionArtifact> _items = const [];
  String? _nextCursor;
  String? _pageError;
  bool _loading = false;
  bool _loadingMore = false;
  bool _offline = false;
  String? _account;

  /// The current tab's canonical source: 'generated' or 'uploaded'.
  String get source => _source;
  List<SessionArtifact> get items => _items;
  String? get nextCursor => _nextCursor;

  /// The last page failure's message, preserved across retries of loadMore
  /// (rows stay; the error clears only when a page succeeds).
  String? get pageError => _pageError;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get offline => _offline;
  String? get accountId => _account;

  @override
  void dispose() {
    _accountChanges?.removeListener(_onAccountChanged);
    _online?.removeListener(_onOnlineChanged);
    super.dispose();
  }

  /// First page for the current filters. Clears rows immediately; a failure
  /// leaves the error state (never a local-corpus fallback).
  Future<void> reload() => _load(reset: true);

  /// Changes any subset of the filters and reloads the first page. The
  /// previous page's in-flight request is invalidated at once and its
  /// results discarded when it lands.
  Future<void> setFilters({
    String? source,
    String? category,
    String? search,
    String? sessionId,
  }) {
    if (source != null) _source = source;
    _category = category;
    _search = search;
    _sessionId = sessionId;
    return _load(reset: true);
  }

  /// Next page for the current filters. A failure preserves the rows and
  /// the cursor so an explicit retry continues where it stopped.
  Future<void> loadMore() async {
    if (_nextCursor == null || _loading || _loadingMore) return;
    final epoch = _epoch;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await _page(cursor: _nextCursor);
      if (epoch != _epoch) return;
      _append(page);
      _nextCursor = page.nextCursor;
      _pageError = null;
    } on CloudApiException catch (e) {
      if (epoch != _epoch) return;
      _pageError = e.message;
    } finally {
      _loadingMore = false;
      if (epoch == _epoch) notifyListeners();
    }
  }

  Future<VaultPage> _page({String? cursor}) {
    return client.list(
      source: _source,
      category: _category,
      search: _search,
      sessionId: _sessionId,
      cursor: cursor,
    );
  }

  Future<void> _load({required bool reset}) async {
    final epoch = ++_epoch;
    if (reset) {
      _items = const [];
      _nextCursor = null;
      _pageError = null;
      _loading = true;
      _offline = (_online?.value ?? true) ? false : true;
      notifyListeners();
    }
    if (_offline) {
      if (reset) _loading = false;
      notifyListeners();
      return;
    }
    if (client.currentAccountId() == null) {
      // Guest: no vault request, no local fallback — the cloud corpus is
      // simply not shown for signed-out accounts.
      if (reset) _loading = false;
      notifyListeners();
      return;
    }
    try {
      final page = await _page(cursor: reset ? null : _nextCursor);
      if (epoch != _epoch) return;
      if (reset) {
        _items = [for (final a in page.items) a.toSessionArtifact(_account)];
      } else {
        _append(page);
      }
      _nextCursor = page.nextCursor;
      _pageError = null;
    } on CloudApiException catch (e) {
      if (epoch != _epoch) return;
      if (reset) _items = const [];
      _pageError = e.message;
    } finally {
      if (epoch == _epoch) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void _append(VaultPage page) {
    final seen = {for (final a in _items) a.id};
    _items = [
      ..._items,
      for (final a in page.items)
        if (!seen.contains(a.id)) a.toSessionArtifact(_account),
    ];
  }

  void _onAccountChanged() {
    final next = _accountChanges!.value;
    if (next == _account) return;
    // Clear private rows/URL state at once, then fence whatever was in
    // flight for the old owner.
    _account = next;
    _epoch++;
    _items = const [];
    _nextCursor = null;
    _pageError = null;
    _loading = false;
    _loadingMore = false;
    notifyListeners();
    if (next != null) {
      unawaited(reload());
    }
  }

  void _onOnlineChanged() {
    final online = _online!.value;
    if (online) {
      if (!_offline) return;
      _offline = false;
      notifyListeners();
      // Retry the page that could not even be sent while offline.
      if (!_loading && _items.isEmpty && _pageError == null) {
        unawaited(reload());
      }
    } else {
      _offline = true;
      notifyListeners();
    }
  }
}
