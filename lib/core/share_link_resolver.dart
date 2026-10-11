import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

class ShareLink {
  const ShareLink(this.token, {this.invite});
  final String token;

  /// Present for Collab links (`/s/<sessionToken>/<inviteCode>`).
  final String? invite;

  bool get isCollab => invite != null;

  /// Opaque key for de-duplicating opens; never logged.
  String get key => invite == null ? token : '$token/$invite';

  @override
  bool operator ==(Object other) =>
      other is ShareLink && other.token == token && other.invite == invite;

  @override
  int get hashCode => Object.hash(token, invite);
}

sealed class ShareRoute {
  const ShareRoute();
}

class ShareViewerRoute extends ShareRoute {
  const ShareViewerRoute(this.token);
  final String token;

  @override
  String toString() => 'ShareViewerRoute(<redacted>)';
}

class CollabJoinRoute extends ShareRoute {
  const CollabJoinRoute(this.token, this.invite);
  final String token;
  final String invite;

  @override
  String toString() => 'CollabJoinRoute(<redacted>)';
}

abstract interface class DeferredShareStore {
  Future<void> write(String token);
  Future<String?> take();
}

class SharedPreferencesDeferredShareStore implements DeferredShareStore {
  const SharedPreferencesDeferredShareStore();
  static const key = 'ovid_deferred_share_token';

  @override
  Future<void> write(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, token);
  }

  @override
  Future<String?> take() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(key);
    if (token != null) {
      await prefs.remove(key);
    }
    return token;
  }
}

class MemoryDeferredShareStore implements DeferredShareStore {
  String? _value;
  String? get lastStoredValue => _value;

  @override
  Future<void> write(String token) async => _value = token;

  @override
  Future<String?> take() async {
    final value = _value;
    _value = null;
    return value;
  }
}

class ShareLinkResolver {
  ShareLinkResolver({DeferredShareStore? store})
    : store = store ?? const SharedPreferencesDeferredShareStore();

  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static const canonicalOrigin = String.fromEnvironment(
    'OVID_PUBLIC_SHARE_ORIGIN',
    defaultValue: 'https://ovidsi.com',
  );
  final DeferredShareStore store;
  static const _native = MethodChannel('ovid/native');

  /// `/s/<token>` (read only) or `/s/<sessionToken>/<inviteCode>` (Collab)
  /// on the configured public origin only.
  static ShareLink? parse(Uri uri) {
    final origin = Uri.tryParse(canonicalOrigin);
    final segments = uri.pathSegments;
    if (origin == null || uri.scheme != origin.scheme || uri.host != origin.host ||
        uri.port != origin.port ||
        uri.userInfo.isNotEmpty || uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty || segments.length < 2 || segments.length > 3 ||
        segments.first != 's') {
      return null;
    }
    if (!segments.skip(1).every(_token.hasMatch)) return null;
    return ShareLink(
      segments[1],
      invite: segments.length == 3 ? segments[2] : null,
    );
  }

  static ShareRoute? route(Uri uri) => routeFor(parse(uri));

  static ShareRoute? routeFor(ShareLink? share) => share == null
      ? null
      : share.invite == null
      ? ShareViewerRoute(share.token)
      : CollabJoinRoute(share.token, share.invite!);

  static Uri uriFor(ShareLink share) =>
      Uri.parse('$canonicalOrigin/s/${share.key}');

  Future<void> saveDeferred(ShareLink share) => store.write(share.key);

  Future<void> saveInstallReferrer(String? referrer) async {
    if (referrer == null || referrer.isEmpty) return;
    try {
      final values = Uri.splitQueryString(referrer);
      final token = values['share_token'];
      final invite = values['invite'];
      if (token != null && _token.hasMatch(token)) {
        if (invite == null) {
          await store.write(token);
        } else if (_token.hasMatch(invite)) {
          await store.write('$token/$invite');
        }
      }
    } on FormatException {
      // Ignore malformed Play payloads; never persist unvalidated input.
    }
  }

  Future<void> readInstallReferrer() async {
    try {
      await saveInstallReferrer(await _native.invokeMethod<String>('getInstallReferrer'));
    } on MissingPluginException {
      // Web, desktop, and builds without Play services have no referrer API.
    } on PlatformException {
      // Referrer retrieval is best effort; the web fallback remains usable.
    }
  }

  Future<ShareLink?> restoreDeferred() async {
    final value = await store.take();
    if (value == null) return null;
    final parts = value.split('/');
    if (parts.isEmpty || parts.length > 2 || !parts.every(_token.hasMatch)) {
      return null;
    }
    return ShareLink(parts.first, invite: parts.length == 2 ? parts[1] : null);
  }

  static const androidApplicationId = 'com.dhanuk.ovidai';

  static Uri playStoreUri(ShareLink share) => Uri.https(
    'play.google.com',
    '/store/apps/details',
    <String, String>{
      'id': androidApplicationId,
      'referrer': Uri(queryParameters: {
        'share_token': share.token,
        if (share.invite != null) 'invite': share.invite!,
      }).query,
    },
  );
}
