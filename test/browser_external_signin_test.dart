// Navigation-level coverage lives in browser_live_location_test.dart. These
// origin helpers do not trigger UI or promise that external cookies transfer.
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

void main() {
  test('auth origin classification respects host boundaries', () {
    expect(
      externalSignInProvider('https://accounts.google.com/signin'),
      'Google',
    );
    expect(
      externalSignInProvider('https://accounts.google.com.evil.test/'),
      isNull,
    );
    expect(externalSignInProvider('https://x.com/user/status/123'), isNull);
    expect(externalSignInProvider('https://x.com/i/flow/login'), 'X');
  });
}
