import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

class ShareLink {
  const ShareLink(this.token);
  final String token;

  @override
  bool operator ==(Object other) => other is ShareLink && other.token == token;

  @override
  int get hashCode => token.hashCode;
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

  static ShareLink? parse(Uri uri) {
    final origin = Uri.tryParse(canonicalOrigin);
    if (origin == null || uri.scheme != origin.scheme || uri.host != origin.host ||
        uri.port != origin.port ||
        uri.userInfo.isNotEmpty || uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty || uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 's') {
      return null;
    }
    final token = uri.pathSegments.last;
    return _token.hasMatch(token) ? ShareLink(token) : null;
  }

  static ShareRoute? route(Uri uri) {
    final share = parse(uri);
    return share == null ? null : ShareViewerRoute(share.token);
  }

  Future<void> saveDeferred(ShareLink share) => store.write(share.token);

  Future<void> saveInstallReferrer(String? referrer) async {
    if (referrer == null || referrer.isEmpty) return;
    try {
      final token = Uri.splitQueryString(referrer)['share_token'];
      if (token != null && _token.hasMatch(token)) {
        await store.write(token);
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
    final token = await store.take();
    return token != null && _token.hasMatch(token) ? ShareLink(token) : null;
  }

  static Uri playStoreUri(ShareLink share) => Uri.https(
    'play.google.com',
    '/store/apps/details',
    <String, String>{
      'id': 'com.dhanuk.ovidai',
      'referrer': 'share_token=${Uri.encodeComponent(share.token)}',
    },
  );
}
