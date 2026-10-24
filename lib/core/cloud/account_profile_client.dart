import 'dart:async';

import 'cloud_rest.dart';

/// Account-owned profile fields and the projections that display them.
class AccountProfileClient {
  AccountProfileClient({CloudRestClient? rest, this.refreshCollabProjection})
    : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;
  final FutureOr<void> Function()? refreshCollabProjection;

  /// Saves the verified account name, then asks live collaboration to re-read
  /// its participant projection. A rejected write never refreshes stale data.
  Future<void> rename(String displayName) async {
    final clean = displayName.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'Must not be empty',
      );
    }
    final response = await _rest.patchJson(
      '/account/profile',
      body: {'displayName': clean},
    );
    final confirmed = response['displayName'];
    if (confirmed is! String || confirmed.trim() != clean) {
      throw StateError('The server did not confirm the display name');
    }
    await refreshCollabProjection?.call();
  }
}
