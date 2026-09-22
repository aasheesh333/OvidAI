/// Hierarchical permission grants for the strict permission model.
///
/// General (`auto`) and Studio (`studio`) modes confine the agent to the
/// session workspace. Any file/shell path OUTSIDE the workspace root, or any
/// network host outside the allowlist, triggers an Allow / Deny / Always
/// allow prompt. "Always allow" records a [PermissionGrant] here.
///
/// Grants are HIERARCHICAL:
/// * a folder grant covers the folder itself and every path beneath it
///   (children), but never siblings or parents;
/// * a host grant covers the host itself, its child domains
///   (`example.com` covers `api.example.com`) and every port/path on it —
///   so granting `127.0.0.1` covers everything served from loopback.
///
/// A Deny is never recorded: deny simply grants nothing, so there is nothing
/// to persist and nothing to revoke.
///
/// Scopes:
/// * session grants live on the [ChatSession] (`grants` JSON field) and apply
///   to that session only;
/// * global grants live in app settings (`permissionGrants`) and apply to
///   every session; the user can revoke them from Settings.
///
/// This file is pure Dart (no Flutter imports) so the matching logic is
/// unit-testable in `test/grant_store_test.dart`.
library;

/// A single "always allow" grant.
class PermissionGrant {
  static const kindPath = 'path';
  static const kindHost = 'host';

  static const scopeSession = 'session';
  static const scopeGlobal = 'global';

  /// 'path' or 'host'.
  final String kind;

  /// Normalized absolute path (kind == 'path') or normalized host
  /// (kind == 'host', lower-cased, no port, no brackets).
  final String value;

  /// 'session' or 'global'.
  final String scope;

  /// Owning session for session-scoped grants; null for global grants.
  final String? sessionId;

  final DateTime grantedAt;

  const PermissionGrant({
    required this.kind,
    required this.value,
    required this.scope,
    this.sessionId,
    required this.grantedAt,
  });

  /// Creates a path grant; [rawPath] is normalized to an absolute path.
  factory PermissionGrant.path(
    String rawPath, {
    String? sessionId,
    bool global = false,
    DateTime? at,
  }) => PermissionGrant(
    kind: kindPath,
    value: normalizeGrantPath(rawPath),
    scope: global ? scopeGlobal : scopeSession,
    sessionId: global ? null : sessionId,
    grantedAt: at ?? DateTime.now(),
  );

  /// Creates a host grant; [rawHost] is normalized (lower-case, port
  /// stripped, IPv6 brackets stripped).
  factory PermissionGrant.host(
    String rawHost, {
    String? sessionId,
    bool global = false,
    DateTime? at,
  }) => PermissionGrant(
    kind: kindHost,
    value: normalizeGrantHost(rawHost),
    scope: global ? scopeGlobal : scopeSession,
    sessionId: global ? null : sessionId,
    grantedAt: at ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'value': value,
    'scope': scope,
    if (sessionId != null) 'sessionId': sessionId,
    'grantedAt': grantedAt.toIso8601String(),
  };

  factory PermissionGrant.fromJson(Map<String, dynamic> j) => PermissionGrant(
    kind: j['kind'] as String? ?? kindPath,
    value: j['value'] as String? ?? '',
    scope: j['scope'] as String? ?? scopeSession,
    sessionId: j['sessionId'] as String?,
    grantedAt:
        DateTime.tryParse(j['grantedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  /// Parses a JSON list into grants; null/malformed entries are skipped so
  /// old or hand-edited session JSON never crashes the load path.
  static List<PermissionGrant> listFromJson(List? json) {
    if (json == null) return [];
    final out = <PermissionGrant>[];
    for (final e in json) {
      try {
        if (e is Map) {
          final g = PermissionGrant.fromJson(Map<String, dynamic>.from(e));
          if (g.value.isNotEmpty) out.add(g);
        }
      } catch (_) {
        // Skip malformed entries — backward compatibility.
      }
    }
    return out;
  }

  @override
  String toString() => 'PermissionGrant($kind:$value scope=$scope)';
}

/// Normalizes a raw path to an absolute POSIX-style path: `~` expanded,
/// `.`/`..` collapsed lexically, duplicate/trailing slashes removed.
/// Relative paths resolve against [base] (defaults to `/`).
String normalizeGrantPath(String raw, {String base = '/'}) {
  var p = raw.trim().replaceAll('\\', '/');
  if (p.startsWith('~/') || p == '~') {
    p = '/home/user${p.length > 1 ? p.substring(1) : ''}';
  }
  if (!p.startsWith('/')) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    p = '$b/$p';
  }
  final parts = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return '/${parts.join('/')}';
}

/// Normalizes a host: lower-cased, port stripped, IPv6 brackets stripped,
/// trailing dot stripped. Returns '' for empty input.
String normalizeGrantHost(String raw) {
  var h = raw.trim().toLowerCase();
  if (h.startsWith('[')) {
    final end = h.indexOf(']');
    if (end > 0) h = h.substring(1, end);
  } else {
    // Strip port, but leave bare IPv6 literals (multiple colons) alone.
    final colon = h.lastIndexOf(':');
    if (colon > 0 && h.indexOf(':') == colon) {
      h = h.substring(0, colon);
    }
  }
  if (h.endsWith('.') && h.length > 1) h = h.substring(0, h.length - 1);
  return h;
}

/// True when [candidate] is inside (or equal to) [grantPath]: a strict
/// segment-boundary check, so `/a/b` covers `/a/b/c` but NOT `/a/bc`.
bool pathCoveredBy(String grantPath, String candidate) {
  final g = normalizeGrantPath(grantPath);
  final c = normalizeGrantPath(candidate);
  if (c == g) return true;
  return c.startsWith('$g/');
}

/// True when [candidateHost] is covered by [grantHost]: exact match or a
/// child domain (`example.com` covers `api.example.com`). IP literals only
/// match themselves exactly — but since matching is host-level, a grant
/// covers every port and path on that host.
bool hostCoveredBy(String grantHost, String candidateHost) {
  final g = normalizeGrantHost(grantHost);
  final c = normalizeGrantHost(candidateHost);
  if (g.isEmpty || c.isEmpty) return false;
  if (c == g) return true;
  return c.endsWith('.$g');
}

/// In-memory grant evaluation. Persistence lives with the owners:
/// session grants on the ChatSession JSON (`grants` field), global grants
/// in app settings (`permissionGrants`).
class GrantStore {
  /// sessionId → session-scoped grants.
  final Map<String, List<PermissionGrant>> sessionGrants;

  /// Global grants — apply to every session, user-revokable in Settings.
  final List<PermissionGrant> globalGrants;

  GrantStore({
    Map<String, List<PermissionGrant>>? sessionGrants,
    List<PermissionGrant>? globalGrants,
  }) : sessionGrants = sessionGrants ?? {},
       globalGrants = globalGrants ?? [];

  /// All grants visible to [sessionId]: its session grants + global grants.
  List<PermissionGrant> grantsFor(String? sessionId) {
    final out = <PermissionGrant>[];
    if (sessionId != null && sessionId.isNotEmpty) {
      out.addAll(sessionGrants[sessionId] ?? const []);
    }
    out.addAll(globalGrants);
    return out;
  }

  bool _coversPath(String? sessionId, String normalizedPath) {
    for (final g in grantsFor(sessionId)) {
      if (g.kind != PermissionGrant.kindPath) continue;
      if (pathCoveredBy(g.value, normalizedPath)) return true;
    }
    return false;
  }

  /// True when [rawPath] may be touched: some visible grant covers it
  /// (hierarchically). Deny is not a stored state — "not granted" is the
  /// deny, so there is nothing to persist for a denial.
  bool isPathGranted(String? sessionId, String rawPath) =>
      _coversPath(sessionId, normalizeGrantPath(rawPath));

  /// True when [rawHost] may be contacted: some visible grant covers it —
  /// exact host or child domain; a host grant covers all ports/paths.
  bool isHostGranted(String? sessionId, String rawHost) {
    final c = normalizeGrantHost(rawHost);
    if (c.isEmpty) return false;
    for (final g in grantsFor(sessionId)) {
      if (g.kind != PermissionGrant.kindHost) continue;
      if (hostCoveredBy(g.value, c)) return true;
    }
    return false;
  }

  /// Records an "always allow" for a path. Exactly the granted path (and
  /// its children) is covered — parents and siblings are not.
  void addPathGrant(String? sessionId, String rawPath, {bool global = false}) {
    final g = PermissionGrant.path(
      rawPath,
      sessionId: sessionId,
      global: global,
    );
    if (g.value.isEmpty) return;
    if (global) {
      if (!_contains(globalGrants, g)) globalGrants.add(g);
    } else {
      final sid = sessionId ?? '';
      final list = sessionGrants.putIfAbsent(sid, () => []);
      if (!_contains(list, g)) list.add(g);
    }
  }

  /// Records an "always allow" for a host (covers child domains too).
  void addHostGrant(String? sessionId, String rawHost, {bool global = false}) {
    final g = PermissionGrant.host(
      rawHost,
      sessionId: sessionId,
      global: global,
    );
    if (g.value.isEmpty) return;
    if (global) {
      if (!_contains(globalGrants, g)) globalGrants.add(g);
    } else {
      final sid = sessionId ?? '';
      final list = sessionGrants.putIfAbsent(sid, () => []);
      if (!_contains(list, g)) list.add(g);
    }
  }

  /// Revokes a matching grant. Returns true when something was removed.
  bool revokePathGrant(
    String? sessionId,
    String rawPath, {
    bool global = false,
  }) => _revoke(
    sessionId,
    PermissionGrant.kindPath,
    normalizeGrantPath(rawPath),
    global: global,
  );

  bool revokeHostGrant(
    String? sessionId,
    String rawHost, {
    bool global = false,
  }) => _revoke(
    sessionId,
    PermissionGrant.kindHost,
    normalizeGrantHost(rawHost),
    global: global,
  );

  bool _revoke(
    String? sessionId,
    String kind,
    String value, {
    bool global = false,
  }) {
    final list = global ? globalGrants : sessionGrants[sessionId ?? ''];
    if (list == null) return false;
    final before = list.length;
    list.removeWhere((g) => g.kind == kind && g.value == value);
    return list.length < before;
  }

  /// Removes every grant for [sessionId] (session teardown).
  void clearSession(String? sessionId) {
    sessionGrants.remove(sessionId ?? '');
  }

  bool _contains(List<PermissionGrant> list, PermissionGrant g) =>
      list.any((e) => e.kind == g.kind && e.value == g.value);

  /// Serializes one session's grants for the ChatSession JSON `grants`
  /// field.
  List<Map<String, dynamic>> sessionGrantsJson(String? sessionId) =>
      (sessionGrants[sessionId ?? ''] ?? const [])
          .map((g) => g.toJson())
          .toList();

  /// Serializes the global grants for the settings `permissionGrants` list.
  List<Map<String, dynamic>> globalGrantsJson() =>
      globalGrants.map((g) => g.toJson()).toList();
}

/// Hosts that never trigger a permission prompt (loopback). Everything else
/// goes through the grant check + prompt in General/Studio modes.
const defaultAllowedHosts = <String>{'localhost', '127.0.0.1', '::1'};

/// Resolves the filesystem root the strict permission model enforces for a
/// session: General mode pins the session workspace. Studio mode's bound
/// repo folder is resolved by the CALLER (AgentService._resolveGrantedPath)
/// via GlobalRepoRegistry — an async lookup that cannot live in this
/// pure-Dart helper — falling back to the session workspace when unbound,
/// which is exactly what this function returns.
String permissionWorkspaceRoot({
  required String modeName,
  required String sessionWorkDir,
  String? sessionId,
}) {
  return sessionWorkDir;
}
