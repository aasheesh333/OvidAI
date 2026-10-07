import 'dart:convert';
import 'package:http/http.dart' as http;

class AccountException implements Exception {
  const AccountException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountDeletion {
  const AccountDeletion(this.state, this.deleteAfter, this.requestId);
  final String state;
  final DateTime? deleteAfter;
  final String? requestId;
  bool get isPending => state == 'pending';
  bool get allowsLogin => state == 'active' || state == 'cancelled';

  factory AccountDeletion.parse(Map<String, dynamic> data) {
    final state = data['state'];
    final deadline = data['delete_after'];
    final id = data['request_id'];
    if (![
          'active',
          'pending',
          'cancelled',
          'fenced',
          'deleting',
          'deleted',
        ].contains(state) ||
        (state != 'active' &&
            (deadline is! num || !deadline.isFinite || id is! String)) ||
        (deadline != null && (deadline is! num || !deadline.isFinite))) {
      throw const AccountException(
        'The account server returned an invalid response.',
      );
    }
    return AccountDeletion(
      state as String,
      deadline == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (deadline * 1000).round(),
              isUtc: true,
            ),
      id as String?,
    );
  }
}

/// No local deletion timer or local-success substitute. Disabled until the
/// server deployment, data manifest and scheduler have been activated.
class AccountService {
  AccountService({
    required this.idToken,
    required this.appCheck,
    this.currentUid,
    this.enabled = const bool.fromEnvironment('OVID_ACCOUNT_ENABLED'),
    this.client,
  });

  final bool enabled;
  final Future<String?> Function(bool forceRefresh) idToken;
  final Future<String?> Function() appCheck;
  final String? Function()? currentUid;
  final http.Client? client;
  static const _base = 'https://api.ovidsi.com/account';

  Future<AccountDeletion> status() => _call('/deletion', get: true);
  Future<AccountDeletion> requestDeletion(String requestId) =>
      _call('/deletion', body: {'request_id': requestId}, refresh: true);
  Future<AccountDeletion> acknowledgeLogin() async {
    final result = await _call('/login');
    if (!result.allowsLogin) {
      throw const AccountException(
        'Account deletion is pending. Sign in again during the 24-hour grace period to cancel.',
      );
    }
    return result;
  }

  Future<AccountDeletion> cancelDeletion() =>
      _call('/deletion/cancel', refresh: true);

  Future<AccountDeletion> _call(
    String path, {
    bool get = false,
    bool refresh = false,
    Map<String, String>? body,
  }) async {
    if (!enabled) {
      throw const AccountException(
        'Account deletion is not yet activated on the server. No request has been submitted.',
      );
    }
    final client = this.client ?? http.Client();
    try {
      final expectedUid = currentUid?.call();
      final token = await idToken(refresh);
      final attestation = await appCheck();
      void checkIdentity() {
        if (currentUid != null &&
            (expectedUid == null || currentUid!() != expectedUid)) {
          throw const AccountException(
            'Account changed. Please retry from your account settings.',
          );
        }
      }

      checkIdentity();
      if (token == null || token.isEmpty) {
        throw const AccountException(
          'Please sign in again to verify your account.',
        );
      }
      if (attestation == null || attestation.isEmpty) {
        throw const AccountException(
          'App verification is unavailable. Please retry on a configured build.',
        );
      }
      final headers = {
        'Authorization': 'Bearer $token',
        'X-Firebase-AppCheck': attestation,
        'Content-Type': 'application/json',
      };
      final response =
          await (get
                  ? client.get(Uri.parse('$_base$path'), headers: headers)
                  : client.post(
                      Uri.parse('$_base$path'),
                      headers: headers,
                      body: body == null ? null : jsonEncode(body),
                    ))
              .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw AccountException(switch (response.statusCode) {
          401 => 'Please sign in again to verify your identity.',
          403 => 'This account or app could not be verified.',
          409 =>
            'Deletion is pending or already in progress. Sign in again during the grace period to cancel.',
          _ =>
            'The account server is unavailable. Request status is unconfirmed; retry to check it.',
        });
      }
      checkIdentity();
      return AccountDeletion.parse(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } on AccountException {
      rethrow;
    } catch (_) {
      throw const AccountException(
        'Could not confirm account status with the server. Check your connection and retry.',
      );
    } finally {
      if (this.client == null) client.close();
    }
  }
}
