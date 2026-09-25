import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic, filesystem/provider-safe browser profile names.
///
/// A profile is named after its chat session id, so the SAME session always
/// resolves to the SAME cookie jar — which is exactly what makes per-session
/// isolation survive an app restart without any extra bookkeeping.
class BrowserProfileId {
  BrowserProfileId._();

  static const String prefix = 'ovid_s_';
  static const int maxLength = 48;

  /// Profile name for [sessionId]; never empty.
  static String forSession(String sessionId) {
    final cleaned = sanitize(sessionId);
    return cleaned.isEmpty ? '${prefix}default' : '$prefix$cleaned';
  }

  /// `[A-Za-z0-9]` only, runs of other characters collapsed to a single `_`.
  /// The AndroidX ProfileStore requires a provider-safe name, and session ids
  /// can contain `/`, `:` and spaces.
  static String sanitize(String raw) {
    final buffer = StringBuffer();
    var lastWasSeparator = true; // suppresses a leading `_`
    for (final code in raw.codeUnits) {
      final isDigit = code >= 48 && code <= 57;
      final isUpper = code >= 65 && code <= 90;
      final isLower = code >= 97 && code <= 122;
      if (isDigit || isUpper || isLower) {
        buffer.writeCharCode(code);
        lastWasSeparator = false;
      } else if (!lastWasSeparator) {
        buffer.write('_');
        lastWasSeparator = true;
      }
      if (buffer.length >= maxLength) break;
    }
    var out = buffer.toString();
    while (out.endsWith('_')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}

/// Pure cookie-header arithmetic used by the restart-sharing pass.
///
/// `CookieManager.setCookie` takes ONE cookie per call and the platform offers
/// no way to enumerate a jar, so the merge has to work from the headers the
/// caller can read for known origins.
class CookieMerge {
  CookieMerge._();

  /// Split a `Cookie` header into individual `name=value` pairs.
  static List<String> pairs(String? header) {
    if (header == null || header.trim().isEmpty) return const [];
    final out = <String>[];
    for (final raw in header.split(';')) {
      final pair = raw.trim();
      if (pair.isEmpty || !pair.contains('=')) continue;
      out.add(pair);
    }
    return out;
  }

  /// Merge [headers] into one header. Earlier sources win for a duplicate
  /// cookie name, so the caller decides precedence by ordering.
  static String merge(Iterable<String?> headers) {
    final seen = <String>{};
    final out = <String>[];
    for (final header in headers) {
      for (final pair in pairs(header)) {
        final eq = pair.indexOf('=');
        final name = pair.substring(0, eq).trim();
        if (name.isEmpty || !seen.add(name)) continue;
        out.add(pair);
      }
    }
    return out.join('; ');
  }

  /// `scheme://host[:port]/` for a browsed [url], or null when it is not a web
  /// origin. Only scheme+host(+port) is kept — never a path or query, which
  /// could carry session-specific data. The port matters: `localhost:8080` and
  /// `localhost:3000` are different cookie scopes.
  static String? originOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port/';
  }
}

/// Outcome of a restart-sharing pass, surfaced in Settings and the startup log.
@immutable
class BrowserShareReport {
  const BrowserShareReport({
    required this.applied,
    required this.profiles,
    required this.urls,
    required this.copied,
    this.reason = '',
  });

  const BrowserShareReport.nothing(String why)
    : applied = false,
      profiles = 0,
      urls = 0,
      copied = 0,
      reason = why;

  final bool applied;
  final int profiles;
  final int urls;
  final int copied;
  final String reason;

  String get message {
    if (!applied) return reason.isEmpty ? 'Nothing to share.' : reason;
    return 'Shared logins across $profiles sessions '
        '($urls sites, $copied writes).';
  }
}

/// Per-session browser identity: one WebView profile per chat session.
///
/// Sessions are isolated while the app runs — a Google login in chat A is
/// invisible from chat B. Once per launch the caller may share the accumulated
/// logins across every session ("share on restart"), after which the sessions
/// diverge again as they are used.
///
/// Every method degrades to a no-op when the WebView provider has no
/// multi-profile support (needs WebView 125+), so tabs fall back to the
/// process-wide cookie jar instead of crashing.
class SessionBrowserProfiles extends ChangeNotifier {
  SessionBrowserProfiles._();

  static final SessionBrowserProfiles I = SessionBrowserProfiles._();

  static const MethodChannel _channel = MethodChannel('ovid/webview');

  /// Origins (scheme+host) each session has browsed, keyed BY SESSION.
  ///
  /// A cookie jar cannot be enumerated, so the restart merge has to know which
  /// origins to replay — that is the ONLY reason this is recorded. It is kept
  /// per session so no session can ever read another session's visit record;
  /// only [allRememberedOrigins] (used by the restart merge and "clear all
  /// cookies") unions them. It is never shown as history and never seeds
  /// another session's tabs.
  static const String _kOriginsPrefix = 'ovid_browser_cookie_origins_';
  static const String _kOriginsLegacy = 'ovid_browser_cookie_origins';
  static const int _maxOrigins = 300;

  /// Bucket used when no session id is known (legacy callers / tests).
  static const String _defaultOriginBucket = 'default';

  /// Profile names whose deletion was refused (live WebViews) and must be
  /// retried at the next launch — see [purgePendingDeletes].
  static const String _kPendingDeletes = 'ovid_browser_profile_deletes';
  static const int _maxPendingDeletes = 100;

  bool? _supported;
  String _reason = '';

  bool get supported => _supported ?? false;
  bool get probed => _supported != null;
  String get unsupportedReason => _reason;

  /// Probe (and cache) whether the installed WebView has the Profile API.
  Future<bool> probe({bool refresh = false}) async {
    if (_supported != null && !refresh) return _supported!;
    try {
      final ok =
          await _channel.invokeMethod<bool>('profilesSupported') ?? false;
      _supported = ok;
      _reason = ok
          ? ''
          : 'This WebView build has no per-app profile support '
                '(needs WebView 125+). Sessions share one cookie jar.';
    } on MissingPluginException {
      _supported = false;
      _reason = 'Per-session browser profiles are Android-only.';
    } catch (error) {
      _supported = false;
      _reason = 'Profile API unavailable: $error';
    }
    notifyListeners();
    return _supported!;
  }

  /// Bind the native WebView [webViewIdentifier] to [profileName].
  ///
  /// MUST happen before the WebView's first navigation — the platform throws
  /// otherwise — which is why every navigation entry point awaits this.
  Future<bool> bind({
    required String profileName,
    required int? webViewIdentifier,
  }) async {
    if (webViewIdentifier == null || profileName.isEmpty) return false;
    if (!await probe()) return false;
    try {
      final applied = await _channel.invokeMethod<bool>('bindProfile', {
        'webViewIdentifier': webViewIdentifier,
        'profileName': profileName,
      });
      return applied ?? false;
    } catch (error) {
      debugPrint('bindProfile($profileName) failed: $error');
      return false;
    }
  }

  /// Profile names the WebView provider currently holds.
  Future<List<String>> listProfiles() async {
    try {
      final names = await _channel.invokeMethod<List<Object?>>('listProfiles');
      return (names ?? const <Object?>[]).whereType<String>().toList();
    } catch (_) {
      return const <String>[];
    }
  }

  /// Delete a profile (its cookies and web storage).
  ///
  /// The platform refuses to delete a profile while a live WebView still holds
  /// it, which is the normal case right after a chat is deleted (its browser
  /// screen may still be mounted). A failed delete is therefore remembered and
  /// retried by [purgePendingDeletes] on the next launch, so a deleted chat can
  /// never leave a logged-in jar behind on disk.
  Future<bool> deleteProfile(String profileName) async {
    if (profileName.isEmpty) return false;
    var deleted = false;
    try {
      deleted =
          await _channel.invokeMethod<bool>('deleteProfile', {
            'profileName': profileName,
          }) ??
          false;
    } catch (_) {
      deleted = false;
    }
    if (deleted) {
      await _forgetPendingDelete(profileName);
    } else if (!await _profileGone(profileName)) {
      // The profile still exists (a live WebView holds it) — retry next launch.
      // A profile that simply never existed is NOT queued, so the list can't
      // grow with names that have nothing to delete.
      await _rememberPendingDelete(profileName);
    }
    return deleted;
  }

  /// Retry the deletes that were refused earlier (live WebViews). Runs at
  /// startup, before any tab is created, when nothing holds a profile.
  Future<int> purgePendingDeletes() async {
    final pending = await _pendingDeletes();
    if (pending.isEmpty) return 0;
    if (!await probe()) return 0;
    var purged = 0;
    for (final name in pending) {
      try {
        final ok =
            await _channel.invokeMethod<bool>('deleteProfile', {
              'profileName': name,
            }) ??
            false;
        if (ok) purged++;
      } catch (_) {}
    }
    // Keep only the names that are still held by a live WebView.
    final still = <String>[];
    for (final name in pending) {
      if (!await _profileGone(name)) still.add(name);
    }
    await _writePendingDeletes(still);
    return purged;
  }

  Future<bool> _profileGone(String name) async {
    final names = await listProfiles();
    return !names.contains(name);
  }

  Future<List<String>> _pendingDeletes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_kPendingDeletes) ?? <String>[];
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> _rememberPendingDelete(String name) async {
    try {
      final list = await _pendingDeletes();
      if (list.contains(name)) return;
      list.add(name);
      while (list.length > _maxPendingDeletes) {
        list.removeAt(0);
      }
      await _writePendingDeletes(list);
    } catch (_) {}
  }

  Future<void> _forgetPendingDelete(String name) async {
    try {
      final list = await _pendingDeletes();
      if (list.remove(name)) await _writePendingDeletes(list);
    } catch (_) {}
  }

  Future<void> _writePendingDeletes(List<String> names) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPendingDeletes, names);
    } catch (_) {}
  }

  /// Copy the cookies of every profile in [profiles] into every other one.
  /// Returns the number of writes performed.
  Future<int> shareCookies({
    required List<String> profiles,
    required List<String> urls,
  }) async {
    if (profiles.length < 2 || urls.isEmpty) return 0;
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'shareProfileCookies',
        {'profiles': profiles, 'urls': urls},
      );
      final copied = result?['copied'];
      return copied is int ? copied : 0;
    } catch (error) {
      debugPrint('shareProfileCookies failed: $error');
      return 0;
    }
  }

  /// Wipe the cookies of [profiles].
  ///
  /// With [urls] the wipe is scoped to those origins; with an EMPTY list the
  /// whole jar of every profile is removed (the honest "clear all cookies"
  /// behaviour — scoping it to recorded origins used to leave anything the
  /// record didn't cover still logged in).
  Future<int> clearCookies({
    required List<String> profiles,
    required List<String> urls,
  }) async {
    if (profiles.isEmpty) return 0;
    try {
      final cleared = await _channel.invokeMethod<int>('clearProfileCookies', {
        'profiles': profiles,
        'urls': urls,
      });
      return cleared ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ── Origin bookkeeping (per session) ──────────────────────────────────

  String _originKey(String sessionId) =>
      '$_kOriginsPrefix${sessionId.isEmpty ? _defaultOriginBucket : sessionId}';

  /// Origins THIS session has browsed. Other sessions' visits are invisible.
  Future<List<String>> rememberedOrigins({String? sessionId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_originKey(sessionId ?? '')) ??
          const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Union of every session's browsed origins.
  ///
  /// Used ONLY by the restart login merge and "clear all cookies" — a cookie
  /// jar cannot be enumerated, so these are the origins whose cookies get
  /// replayed. It is deliberately not tied to any one session, and the result
  /// is never handed to a session as history.
  Future<List<String>> allRememberedOrigins() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final out = <String>[];
      final seen = <String>{};
      for (final key in prefs.getKeys()) {
        if (key != _kOriginsLegacy && !key.startsWith(_kOriginsPrefix)) continue;
        for (final origin in prefs.getStringList(key) ?? const <String>[]) {
          if (origin.isNotEmpty && seen.add(origin)) out.add(origin);
        }
      }
      return out;
    } catch (_) {
      return const <String>[];
    }
  }

  /// Record the origin of a browsed [url] so a later restart can find this
  /// session's cookies again.
  /// Serializes origin writes per bucket.
  ///
  /// RACE FIX (2026-09-24): [rememberOrigin] is fired `unawaited` from both
  /// `onPageFinished` and `navigateTab`, and several tabs can navigate at once.
  /// Two interleaved calls each read the old list, and the last write silently
  /// dropped the other's origin — so after a restart the cookie merge missed a
  /// site and the user found themselves logged out of something they had logged
  /// into during that session.
  final Map<String, Future<void>> _originWrites = {};

  Future<void> rememberOrigin(String url, {String sessionId = ''}) {
    final origin = CookieMerge.originOf(url);
    if (origin == null) return Future.value();
    final key = _originKey(sessionId);
    final previous = _originWrites[key] ?? Future<void>.value();
    final next = previous
        .then((_) => _writeOrigin(key, origin))
        .catchError((Object _) {});
    _originWrites[key] = next;
    return next;
  }

  Future<void> _writeOrigin(String key, String origin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(key) ?? <String>[];
      if (list.contains(origin)) return;
      list.add(origin);
      while (list.length > _maxOrigins) {
        list.removeAt(0);
      }
      await prefs.setStringList(key, list);
    } catch (_) {}
  }

  /// Forget one session's visit record (or every session's, with no id).
  Future<void> forgetOrigins({String? sessionId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (sessionId != null) {
        await prefs.remove(_originKey(sessionId));
        return;
      }
      for (final key in prefs.getKeys().toList()) {
        if (key == _kOriginsLegacy || key.startsWith(_kOriginsPrefix)) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  // ── Restart sharing ───────────────────────────────────────────────────

  /// Share the logins of the previous launch across every current session.
  ///
  /// Called once per launch. Each session profile keeps its own jar during the
  /// launch, so anything the user logs into now stays in that session until the
  /// next restart re-shares.
  Future<BrowserShareReport> shareOnRestart({
    required List<String> sessionIds,
  }) async {
    // Decide "is there anything to share at all" before touching the platform:
    // a one-session install should report the real reason (nothing to share),
    // not "profiles unsupported".
    final ids = sessionIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.length < 2) {
      return const BrowserShareReport.nothing(
        'Only one session exists — nothing to share yet.',
      );
    }
    if (!await probe()) {
      return BrowserShareReport.nothing(_reason);
    }
    final urls = await allRememberedOrigins();
    if (urls.isEmpty) {
      return const BrowserShareReport.nothing(
        'No browsed sites recorded yet.',
      );
    }
    final profiles = ids.map(BrowserProfileId.forSession).toList();
    final copied = await shareCookies(profiles: profiles, urls: urls);
    return BrowserShareReport(
      applied: true,
      profiles: profiles.length,
      urls: urls.length,
      copied: copied,
    );
  }
}
