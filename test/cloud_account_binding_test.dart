import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_account_binding.dart';

class _Auth extends ChangeNotifier {
  String? uid;
  bool ready = false;
  void set(String? u, {bool isReady = true}) {
    uid = u;
    ready = u != null && isReady;
    notifyListeners();
  }
}

void main() {
  late _Auth auth;
  late List<String> calls;
  late CloudAccountBinding binding;

  setUp(() {
    auth = _Auth();
    calls = [];
    binding = CloudAccountBinding(
      auth: auth,
      readyUid: () => auth.ready ? auth.uid : null,
      signedIn: () => auth.uid != null,
      onBind: (uid) async => calls.add('bind:$uid'),
      onUnbind: (uid) async => calls.add('unbind:$uid'),
    )..start();
  });

  tearDown(() => binding.stop());

  test('binds on every account, not once per process', () async {
    auth.set('a');
    await binding.idle;
    auth.set(null);
    await binding.idle;
    auth.set('b');
    await binding.idle;
    expect(calls, ['bind:a', 'unbind:a', 'bind:b']);
    expect(binding.boundUid, 'b');
  });

  test('a direct switch unbinds the previous account first', () async {
    auth.set('a');
    auth.set('b');
    await binding.idle;
    expect(calls, ['bind:a', 'unbind:a', 'bind:b']);
  });

  test('signed in but not ready yet keeps the current binding', () async {
    auth.set('a');
    await binding.idle;
    auth.set('a', isReady: false); // e.g. admission re-check
    await binding.idle;
    expect(calls, ['bind:a']);
  });

  test('repeated notifications for the same account bind once', () async {
    auth.set('a');
    auth.set('a');
    await binding.idle;
    expect(calls, ['bind:a']);
  });

  test('a failing hook never wedges later transitions', () async {
    final failing = CloudAccountBinding(
      auth: auth,
      readyUid: () => auth.ready ? auth.uid : null,
      signedIn: () => auth.uid != null,
      onBind: (uid) async {
        calls.add('bind:$uid');
        if (uid == 'x') throw StateError('boom');
      },
      onUnbind: (uid) async => calls.add('unbind:$uid'),
    );
    binding.stop();
    failing.start();
    auth.set('x');
    await failing.idle;
    auth.set('y');
    await failing.idle;
    expect(calls, ['bind:x', 'unbind:x', 'bind:y']);
    failing.stop();
  });
}
