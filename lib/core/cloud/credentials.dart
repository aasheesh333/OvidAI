import 'cloud_rest.dart';

/// Wave 6 W4 — the browser Credentials Vault API.
///
/// A credential is URL/site + username + password-or-token (+ optional
/// notes). The SERVER seals the secret with AES-256-GCM and never returns it:
/// [BrowserCredential] is metadata only. The agent can use an entry during an
/// automated login, but neither the app nor the model ever sees the plaintext.
class BrowserCredential {
  const BrowserCredential({
    required this.id,
    required this.label,
    required this.site,
    required this.username,
    required this.secretKind,
    required this.hasNotes,
  });

  factory BrowserCredential.fromJson(Map<String, dynamic> json) =>
      BrowserCredential(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        site: json['site'] as String? ?? '',
        username: json['username'] as String? ?? '',
        secretKind: json['secretKind'] as String? ?? 'password',
        hasNotes: json['hasNotes'] == true,
      );

  final String id;
  final String label;
  final String site;
  final String username;

  /// `password` or `token`.
  final String secretKind;
  final bool hasNotes;
}

/// Seam so the vault screen is testable without HTTP.
abstract class CredentialsApi {
  Future<List<BrowserCredential>> list();
  Future<BrowserCredential> create({
    required String label,
    required String site,
    required String username,
    required String secret,
    required String secretKind,
    String? notes,
  });
  Future<BrowserCredential> update(
    String id, {
    String? label,
    String? site,
    String? username,
    String? secret,
    String? secretKind,
    String? notes,
    bool clearNotes = false,
  });
  Future<void> remove(String id);
}

/// Production API over the authenticated gateway (`/cloud/v1/credentials`).
class CloudCredentialsApi implements CredentialsApi {
  CloudCredentialsApi({CloudRestClient? rest}) : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  @override
  Future<List<BrowserCredential>> list() async {
    final body = await _rest.getJson('/credentials');
    final items = body['items'];
    if (items is! List) return const <BrowserCredential>[];
    return items
        .whereType<Map>()
        .map((m) => BrowserCredential.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  @override
  Future<BrowserCredential> create({
    required String label,
    required String site,
    required String username,
    required String secret,
    required String secretKind,
    String? notes,
  }) async {
    final body = await _rest.postJson('/credentials', body: <String, Object?>{
      'label': label,
      'site': site,
      'username': username,
      'secret': secret,
      'secretKind': secretKind,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
    return BrowserCredential.fromJson(body);
  }

  @override
  Future<BrowserCredential> update(
    String id, {
    String? label,
    String? site,
    String? username,
    String? secret,
    String? secretKind,
    String? notes,
    bool clearNotes = false,
  }) async {
    final body = await _rest.patchJson('/credentials/$id', body: <String, Object?>{
      'label': ?label,
      'site': ?site,
      'username': ?username,
      if (secret != null && secret.isNotEmpty) 'secret': secret,
      'secretKind': ?secretKind,
      if (clearNotes) 'notes': null,
      if (!clearNotes && notes != null && notes.isNotEmpty) 'notes': notes,
    });
    return BrowserCredential.fromJson(body);
  }

  @override
  Future<void> remove(String id) => _rest.delete('/credentials/$id');
}
