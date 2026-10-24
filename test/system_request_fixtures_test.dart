import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const fixtureName = 'system-requests-v1.json';
const requestKeys = <String>{
  'requestId',
  'userId',
  'sessionId',
  'runId',
  'kind',
  'safePayload',
  'sensitive',
  'status',
  'expiresAt',
  'response',
  'version',
};
const responseKeys = <String>{
  'requestId',
  'userId',
  'version',
  'response',
  'clientResponseId',
  'createdAt',
};
const attemptKeys = <String>{
  'requestId',
  'version',
  'response',
  'clientResponseId',
};

Map<String, dynamic> map(Object? value) =>
    (value! as Map).cast<String, dynamic>();

Map<String, dynamic> fixture() =>
    map(jsonDecode(File('test/fixtures/$fixtureName').readAsStringSync()));

void main() {
  test(
    'canonical, Flutter, and Web system request fixtures are byte-identical',
    () {
      final canonical = File(
        '../OvidBackend/cloud/packages/shared/contracts/fixtures/$fixtureName',
      ).readAsBytesSync();
      final flutter = File('test/fixtures/$fixtureName').readAsBytesSync();
      final web = File(
        '../OvidWeb/web/test/fixtures/$fixtureName',
      ).readAsBytesSync();
      expect(flutter, orderedEquals(canonical));
      expect(web, orderedEquals(canonical));
    },
  );

  test(
    'Flutter reader retains complete pending approval and sensitive elicitation DTOs',
    () {
      final value = fixture();
      expect(value['contractVersion'], 1);
      final requests = map(value['requests']);
      final approval = map(requests['pendingApproval']);
      final sensitive = map(requests['sensitiveElicitation']);
      for (final request in [approval, sensitive]) {
        expect(request.keys.toSet(), requestKeys);
        expect(request['userId'], 'user-fixture-system-requests');
        expect(request['status'], 'pending');
        expect(request['response'], isNull);
        expect(request['version'], isA<int>());
        expect(request['version'] as int, greaterThan(0));
      }
      expect(approval['kind'], 'approval');
      expect(approval['sensitive'], isFalse);
      expect(map(approval['safePayload']), {'tool': 'bash', 'preview': 'pwd'});
      expect(sensitive['kind'], 'elicitation');
      expect(sensitive['sensitive'], isTrue);
      final payload = map(sensitive['safePayload']);
      expect(payload['message'], 'Enter your password');
      final field = map((payload['fields'] as List).single);
      expect(field['name'], 'password');
      expect(field.containsKey('value'), isFalse);
      final raw = File('test/fixtures/$fixtureName').readAsStringSync();
      expect(
        RegExp(
          r'"(?:plaintext|plaintextSecret|secretValue|accessToken|refreshToken|apiKey)"\s*:',
          caseSensitive: false,
        ).hasMatch(raw),
        isFalse,
      );
    },
  );

  test(
    'Flutter reader retains receipt, identical replay, and version conflict semantics',
    () {
      final value = fixture();
      final receipt = map(value['responseReceipt']);
      final replayValue = map(value['identicalReplay']);
      final replayReceipt = map(replayValue['receipt']);
      final replay = map(replayValue['attempt']);
      final conflict = map(value['versionConflict']);
      final stale = map(conflict['attempt']);

      expect(receipt.keys.toSet(), responseKeys);
      expect(replayReceipt, receipt);
      expect(replay.keys.toSet(), attemptKeys);
      expect(replay['requestId'], receipt['requestId']);
      expect(replay['version'], receipt['version']);
      expect(replay['clientResponseId'], receipt['clientResponseId']);
      expect(map(replay['response']), map(receipt['response']));
      expect(receipt['version'], 3);
      expect(stale.keys.toSet(), attemptKeys);
      expect(stale['requestId'], receipt['requestId']);
      expect(stale['version'], 2);
      expect(conflict['currentVersion'], 3);
      expect(map(conflict['error']), {
        'code': 'version_conflict',
        'message': 'The system request version is stale.',
      });
      expect(conflict.containsKey('receipt'), isFalse);
      expect(value.containsKey('responseWaitSeconds'), isFalse);
    },
  );
}
