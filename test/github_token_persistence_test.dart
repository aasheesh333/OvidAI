// The Studio GitHub credential must survive an app restart.
//
// Before this, GitHubService kept the token in memory only, so every launch
// (and every background kill) signed the user out of Studio and asked them to
// redo the device flow. The PAT row in Settings wrote a SecureStore entry that
// nothing ever read.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/ui/v2/settings/credentials_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _keyContract();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('a saved token is restored by a fresh service instance', () async {
    final first = GitHubService.forTest();
    await first.saveToken('gho_persisted');

    final second = GitHubService.forTest();
    expect(second.isLoggedIn, isFalse);
    expect(await second.restore(), isTrue);
    expect(second.token, 'gho_persisted');
    expect(second.isLoggedIn, isTrue);
  });

  test('restore is false when nothing was ever saved', () async {
    final service = GitHubService.forTest();
    expect(await service.restore(), isFalse);
    expect(service.token, isNull);
  });

  test('signing out deletes the stored token', () async {
    final first = GitHubService.forTest();
    await first.saveToken('gho_to_delete');
    await first.signOut();

    final second = GitHubService.forTest();
    expect(await second.restore(), isFalse);
    expect(second.token, isNull);
  });

  test('an empty or blank token is never persisted', () async {
    final service = GitHubService.forTest();
    await service.saveToken('   ');
    expect(service.token, isNull);

    final second = GitHubService.forTest();
    expect(await second.restore(), isFalse);
  });
}

// One key, one truth: the Settings → Credentials row writes
// `ovid_credential_key_github`; Studio must read exactly that.
void _keyContract() {
  test('the stored key is the one the credentials page writes', () {
    expect(GitHubService.storageKey, '${V2SecureCredentialKeyStore.prefix}github');
  });
}
