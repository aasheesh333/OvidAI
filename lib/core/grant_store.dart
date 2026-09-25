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

/// A single persisted permission decision.
///
/// STRICT MODEL (2026-09-24): an entry now carries the MODE it was made in and
/// the DECISION it records. Both were missing, which is why grants leaked across
/// modes: switching a session from Studio to General left its Studio grants fully
/// in force, because the store had no mode dimension at all. A grant made in one
/// mode is now invisible in every other mode.
///
/// Denials are persisted too. They never were ("a Deny is never recorded"), so a
/// user who denied a path was asked again on the very next attempt — and the
/// model had no durable signal to stop asking.
class PermissionGrant {
  static const kindPath = 'path';
  static const kindHost = 'host';

  static const scopeSession = 'session';
  static const scopeGlobal = 'global';

  /// Decisions. `allow` is one-time and never persisted; only `deny` and
  /// `always` are written to disk.
  static const decisionAlways = 'always';
  static const decisionDeny = 'deny';

  /// 'path' or 'host'.
  final String kind;

  /// Normalized absolute path (kind == 'path') or normalized host
  /// (kind == 'host', lower-cased, no port, no brackets).
  final String value;

  /// 'session' or 'global'.
  final String scope;

  /// Owning session for session-scoped grants; null for global grants.
  final String? sessionId;

  /// AgentMode name this decision was made in ('safe', 'auto', 'studio',
  /// 'control', 'drive'). A grant only applies when the session is STILL in
  /// this mode — that is what makes the modes unable to conflict.
  ///
  /// Empty means a legacy entry written before mode tagging existed; those are
  /// honoured in General mode only, the most conservative reading.
  final String mode;

  /// 'always' (persistent allow) or 'deny' (persistent refusal).
  final String decision;

  final DateTime grantedAt;

  const PermissionGrant({
    required this.kind,
    required this.value,
    required this.scope,
    this.sessionId,
    this.mode = '',
    this.decision = decisionAlways,
    required this.grantedAt,
  });

  /// True when this entry is a persistent refusal rather than a grant.
  bool get isDeny => decision == decisionDeny;

  /// Creates a path grant; [rawPath] is normalized to an absolute path.
  factory PermissionGrant.path(
    String rawPath, {
    String? sessionId,
    bool global = false,
    String mode = '',
    String decision = decisionAlways,
    DateTime? at,
  }) => PermissionGrant(
    kind: kindPath,
    value: normalizeGrantPath(rawPath),
    scope: global ? scopeGlobal : scopeSession,
    sessionId: global ? null : sessionId,
    mode: mode,
    decision: decision,
    grantedAt: at ?? DateTime.now(),
  );

  /// Creates a host grant; [rawHost] is normalized (lower-case, port
  /// stripped, IPv6 brackets stripped).
  factory PermissionGrant.host(
    String rawHost, {
    String? sessionId,
    bool global = false,
    String mode = '',
    String decision = decisionAlways,
    DateTime? at,
  }) => PermissionGrant(
    kind: kindHost,
    value: normalizeGrantHost(rawHost),
    scope: global ? scopeGlobal : scopeSession,
    sessionId: global ? null : sessionId,
    mode: mode,
    decision: decision,
    grantedAt: at ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'value': value,
    'scope': scope,
    if (sessionId != null) 'sessionId': sessionId,
    if (mode.isNotEmpty) 'mode': mode,
    if (decision != decisionAlways) 'decision': decision,
    'grantedAt': grantedAt.toIso8601String(),
  };

  /// Parses persisted JSON. Unknown [kind]/[scope] values and empty values
  /// are rejected (callers like [listFromJson] skip rejected entries) so
  /// hand-edited or corrupt persisted data can never smuggle in a grant
  /// with an unrecognized kind, and values are re-normalized by kind.
  factory PermissionGrant.fromJson(Map<String, dynamic> j) {
    final kind = j['kind'] as String?;
    final scope = j['scope'] as String?;
    final rawValue = j['value'] as String?;
    if (kind != kindPath && kind != kindHost) {
      throw FormatException('unknown grant kind: $kind');
    }
    if (scope != scopeSession && scope != scopeGlobal) {
      throw FormatException('unknown grant scope: $scope');
    }
    final validKind = kind as String;
    final validScope = scope as String;
    final value = validKind == kindPath
        ? normalizeGrantPath(rawValue ?? '')
        : normalizeGrantHost(rawValue ?? '');
    if (value.isEmpty) {
      throw const FormatException('grant value is empty');
    }
    final decision = j['decision'] as String? ?? decisionAlways;
    if (decision != decisionAlways && decision != decisionDeny) {
      throw FormatException('unknown grant decision: $decision');
    }
    return PermissionGrant(
      kind: validKind,
      value: value,
      scope: validScope,
      sessionId: j['sessionId'] as String?,
      mode: j['mode'] as String? ?? '',
      decision: decision,
      grantedAt:
          DateTime.tryParse(j['grantedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

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
/// A grant on the filesystem root `/` covers every absolute path.
bool pathCoveredBy(String grantPath, String candidate) {
  final g = normalizeGrantPath(grantPath);
  final c = normalizeGrantPath(candidate);
  if (c == g) return true;
  if (g == '/') return true;
  return c.startsWith('$g/');
}

/// True for an IP literal (IPv4 or IPv6) after [normalizeGrantHost].
bool _isIpLiteral(String host) {
  if (host.contains(':')) return true; // IPv6 (brackets already stripped).
  final v4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  if (!v4.hasMatch(host)) return false;
  return host.split('.').every((p) {
    final n = int.tryParse(p);
    return n != null && n >= 0 && n <= 255;
  });
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
  // IP literals match only themselves — a suffix match would let an
  // attacker-controlled name like `evil.127.0.0.1` ride on a loopback grant.
  if (_isIpLiteral(g)) return false;
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

  /// Entries written before mode tagging existed carry an empty [PermissionGrant.mode].
  /// They are honoured in General mode only — the most conservative reading of a
  /// decision whose mode is unknown.
  static const legacyModeFallback = 'auto';

  static bool _modeMatches(PermissionGrant g, String mode) =>
      g.mode.isEmpty ? mode == legacyModeFallback : g.mode == mode;

  /// All decisions visible to [sessionId] **in [mode]**: its own entries plus
  /// global ones, filtered to the mode.
  ///
  /// The mode filter is what makes the modes unable to conflict. Before it, a
  /// path granted while a session was in Studio stayed fully in force after the
  /// same session switched to General, because the store had no mode dimension.
  List<PermissionGrant> grantsFor(
    String? sessionId, {
    String mode = legacyModeFallback,
  }) {
    final out = <PermissionGrant>[];
    if (sessionId != null && sessionId.isNotEmpty) {
      out.addAll(
        (sessionGrants[sessionId] ?? const <PermissionGrant>[]).where(
          (g) => _modeMatches(g, mode),
        ),
      );
    }
    out.addAll(globalGrants.where((g) => _modeMatches(g, mode)));
    return out;
  }

  bool _coversPath(
    String? sessionId,
    String normalizedPath, {
    String mode = legacyModeFallback,
    bool deny = false,
  }) {
    for (final g in grantsFor(sessionId, mode: mode)) {
      if (g.kind != PermissionGrant.kindPath) continue;
      if (g.isDeny != deny) continue;
      if (pathCoveredBy(g.value, normalizedPath)) return true;
    }
    return false;
  }

  bool _coversHost(
    String? sessionId,
    String canonicalHost, {
    String mode = legacyModeFallback,
    bool deny = false,
  }) {
    for (final g in grantsFor(sessionId, mode: mode)) {
      if (g.kind != PermissionGrant.kindHost) continue;
      if (g.isDeny != deny) continue;
      if (hostCoveredBy(g.value, canonicalHost)) return true;
    }
    return false;
  }

  /// True when [rawPath] may be touched: some visible grant covers it
  /// (hierarchically) and no denial does. **A recorded deny always wins over a
  /// recorded allow** — otherwise a stale "always allow" would silently
  /// override the user's later, more specific refusal.
  bool isPathGranted(
    String? sessionId,
    String rawPath, {
    String mode = legacyModeFallback,
  }) {
    final c = normalizeGrantPath(rawPath);
    if (_coversPath(sessionId, c, mode: mode, deny: true)) return false;
    return _coversPath(sessionId, c, mode: mode);
  }

  /// True when the user has explicitly and persistently refused [rawPath].
  bool isPathDenied(
    String? sessionId,
    String rawPath, {
    String mode = legacyModeFallback,
  }) => _coversPath(sessionId, normalizeGrantPath(rawPath),
      mode: mode, deny: true);

  /// True when [rawHost] may be contacted: some visible grant covers it —
  /// exact host or child domain; a host grant covers all ports/paths — and no
  /// denial does.
  bool isHostGranted(
    String? sessionId,
    String rawHost, {
    String mode = legacyModeFallback,
  }) {
    final c = normalizeGrantHost(rawHost);
    if (c.isEmpty) return false;
    if (_coversHost(sessionId, c, mode: mode, deny: true)) return false;
    return _coversHost(sessionId, c, mode: mode);
  }

  /// True when the user has explicitly and persistently refused [rawHost].
  bool isHostDenied(
    String? sessionId,
    String rawHost, {
    String mode = legacyModeFallback,
  }) {
    final c = normalizeGrantHost(rawHost);
    if (c.isEmpty) return false;
    return _coversHost(sessionId, c, mode: mode, deny: true);
  }

  /// Records an "always allow" for a path. Exactly the granted path (and
  /// its children) is covered — parents and siblings are not.
  /// A non-global grant with a null/empty [sessionId] is refused: it would
  /// land in an unreachable bucket that [grantsFor] never reads, so the
  /// user would believe they allowed something that never applies.
  void addPathGrant(
    String? sessionId,
    String rawPath, {
    bool global = false,
    String mode = '',
    String decision = PermissionGrant.decisionAlways,
  }) {
    if (!global && (sessionId == null || sessionId.isEmpty)) return;
    final g = PermissionGrant.path(
      rawPath,
      sessionId: sessionId,
      global: global,
      mode: mode,
      decision: decision,
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
  /// A non-global grant with a null/empty [sessionId] is refused: it would
  /// land in an unreachable bucket that [grantsFor] never reads.
  void addHostGrant(
    String? sessionId,
    String rawHost, {
    bool global = false,
    String mode = '',
    String decision = PermissionGrant.decisionAlways,
  }) {
    if (!global && (sessionId == null || sessionId.isEmpty)) return;
    final g = PermissionGrant.host(
      rawHost,
      sessionId: sessionId,
      global: global,
      mode: mode,
      decision: decision,
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

  /// Identity of a stored decision. Mode and decision are part of it, so a
  /// persistent allow and a persistent deny on the SAME value can coexist (the
  /// deny wins at match time) and the same path granted in two modes is two
  /// separate entries rather than one that leaks across both.
  bool _contains(List<PermissionGrant> list, PermissionGrant g) => list.any(
    (e) =>
        e.kind == g.kind &&
        e.value == g.value &&
        e.mode == g.mode &&
        e.decision == g.decision,
  );

  /// Records a persistent DENY, replacing any allow on the same value+mode so
  /// the user's most recent, more specific decision is the one that stands.
  void addPathDeny(String? sessionId, String rawPath, {String mode = ''}) {
    _removeMatching(sessionId, rawPath, PermissionGrant.kindPath, mode);
    addPathGrant(
      sessionId,
      rawPath,
      mode: mode,
      decision: PermissionGrant.decisionDeny,
    );
  }

  /// Records a persistent DENY for a host.
  void addHostDeny(String? sessionId, String rawHost, {String mode = ''}) {
    _removeMatching(sessionId, rawHost, PermissionGrant.kindHost, mode);
    addHostGrant(
      sessionId,
      rawHost,
      mode: mode,
      decision: PermissionGrant.decisionDeny,
    );
  }

  void _removeMatching(
    String? sessionId,
    String rawValue,
    String kind,
    String mode,
  ) {
    final value = kind == PermissionGrant.kindPath
        ? normalizeGrantPath(rawValue)
        : normalizeGrantHost(rawValue);
    if (value.isEmpty) return;
    bool matches(PermissionGrant e) =>
        e.kind == kind && e.value == value && _modeMatches(e, mode);
    if (sessionId != null && sessionId.isNotEmpty) {
      sessionGrants[sessionId]?.removeWhere(matches);
    }
    globalGrants.removeWhere(matches);
  }

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
  // Full Access is unconfinable BY DESIGN: the user explicitly opted out of
  // prompts, so there is no root to enforce. Callers must treat an empty return
  // as "no jail" rather than as a jail rooted at "".
  if (modeName == 'drive') return '';
  // Every other mode — Read-Only, General, Studio AND Control — is jailed to
  // the session workspace. Studio's root is the bound repo clone, which the
  // CALLER resolves (an async registry lookup cannot live in this pure helper)
  // and passes in as [sessionWorkDir].
  //
  // Control used to be treated as full access by the agent-side gate, which is
  // why a Control session could read and write anywhere on the device with no
  // prompt. It is jailed like the rest.
  return sessionWorkDir;
}
