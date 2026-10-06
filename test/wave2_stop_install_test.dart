import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = SandboxService.I;
  late Directory root;
  late Uint8List payload;
  var reads = 0;
  Completer<void>? payloadGate;
  Completer<void>? payloadEntered;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ovid-wave2-install-');
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes('bin/bash', await File('/bin/bash').readAsBytes()),
      )
      ..addFile(ArchiveFile.string('bin/coreutils', 'core fixture'))
      ..addFile(
        ArchiveFile.string('lib/libtermux-exec-direct-ld-preload.so', ''),
      )
      ..addFile(
        ArchiveFile.string(
          'etc/test.conf',
          '/data/data/com.termux/files/usr/bin',
        ),
      );
    payload = Uint8List.fromList(ZipEncoder().encode(archive));
    reads = 0;
    payloadGate = null;
    payloadEntered = null;
    sandbox.resetCheckExistingForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          switch (call.method) {
            case 'getProcessAbi':
              return 'x86_64';
            case 'getSdkInt':
              return 30;
            case 'readBootstrapPayload':
              reads++;
              if (payloadEntered != null && !payloadEntered!.isCompleted) {
                payloadEntered!.complete();
              }
              await payloadGate?.future;
              return {'bytes': payload, 'abi': 'x86_64'};
          }
          return null;
        });
  });
  tearDown(() async {
    SandboxService.execCheckedOverrideForTest = null;
    sandbox.killAllProcesses();
    sandbox.resetCheckExistingForTest();
    await root.delete(recursive: true);
  });

  test(
    'simultaneous core installs share extraction and publish final-path configs',
    () async {
      payloadGate = Completer<void>();
      payloadEntered = Completer<void>();
      final first = sandbox.install(
        onPhase: (_, _, _) {},
        includeRuntimes: false,
      );
      await payloadEntered!.future;
      final second = sandbox.install(
        onPhase: (_, _, _) {},
        includeRuntimes: false,
      );
      payloadGate!.complete();
      await Future.wait([first, second]);
      expect(reads, 1);
      expect(sandbox.isInstalled, isTrue);
      expect(
        File('${root.path}/sandbox/etc/test.conf').readAsStringSync(),
        '${root.path}/sandbox/bin',
      );
    },
  );

  test(
    'explicit install cancel during extraction leaves previous prefix and retry succeeds',
    () async {
      final old = Directory('${root.path}/sandbox')..createSync();
      File('${old.path}/old').writeAsStringSync('last good');
      var cancelled = false;
      final install = sandbox.install(
        includeRuntimes: false,
        onPhase: (phase, progress, _) {
          if (phase == 2 && progress == 0 && !cancelled) {
            cancelled = true;
            unawaited(sandbox.cancelInstall());
          }
        },
      );
      await expectLater(install, throwsA(isA<SandboxCancelledException>()));
      expect(File('${old.path}/old').readAsStringSync(), 'last good');
      expect(root.listSync().where((e) => e.path.contains('staging')), isEmpty);
      await sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {});
      expect(sandbox.isInstalled, isTrue);
      expect(File('${old.path}/old').existsSync(), isFalse);
    },
  );

  test(
    'invalid executable fails before publication and retains last good prefix',
    () async {
      final old = Directory('${root.path}/sandbox')..createSync();
      File('${old.path}/old').writeAsStringSync('last good');
      final archive = Archive()
        ..addFile(ArchiveFile.string('bin/bash', 'not an executable'))
        ..addFile(ArchiveFile.string('bin/coreutils', 'core fixture'))
        ..addFile(
          ArchiveFile.string('lib/libtermux-exec-direct-ld-preload.so', ''),
        );
      payload = Uint8List.fromList(ZipEncoder().encode(archive));
      await expectLater(
        sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {}),
        throwsException,
      );
      expect(File('${old.path}/old').existsSync(), isTrue);
      expect(sandbox.isInstalled, isFalse);
      expect(root.listSync().where((e) => e.path.contains('staging')), isEmpty);
    },
  );

  test(
    'failed runtime verification cannot publish full setup success',
    () async {
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        if (args.length > 2 && args[2].contains('command -v node')) {
          return (1, 'node missing');
        }
        return (0, 'fixture');
      };
      await expectLater(
        sandbox.install(includeRuntimes: true, onPhase: (_, _, _) {}),
        throwsA(isA<StateError>()),
      );
      expect(
        sandbox.isInstalled,
        isTrue,
        reason: 'core is committed but full runtime is partial',
      );
    },
  );

  test('runtime request joins core install and upgrades required phase', () async {
    payloadGate = Completer<void>();
    payloadEntered = Completer<void>();
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.length > 2 && args[2].contains('command -v node')) return (1, 'missing');
      return (0, 'fixture');
    };
    final install = sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {});
    final failure = expectLater(install, throwsA(isA<StateError>()));
    await payloadEntered!.future;
    final runtime = sandbox.ensureRuntime('node');
    final runtimeFailure = expectLater(runtime, throwsA(isA<StateError>()));
    payloadGate!.complete();
    await failure;
    await runtimeFailure;
    expect(reads, 1);
  });

  test('restart restores committed prefix and removes owned staging', () async {
    final old = Directory('${root.path}/sandbox-previous')..createSync();
    File('${old.path}/bin/bash').createSync(recursive: true);
    File('${old.path}/bin/coreutils').createSync(recursive: true);
    File('${old.path}/lib/libtermux-exec-direct-ld-preload.so')
        .createSync(recursive: true);
    final candidate = Directory('${root.path}/sandbox')..createSync();
    File('${candidate.path}/.ovid-installing').writeAsStringSync('42');
    final stage = Directory('${root.path}/sandbox-staging-42')..createSync();
    File('${stage.path}/.ovid-staging-owner').writeAsStringSync('42');
    expect(await sandbox.checkExisting(), isTrue);
    expect(File('${root.path}/sandbox/bin/bash').existsSync(), isTrue);
    expect(stage.existsSync(), isFalse);
  });

  test('global agent stop does not cancel an independently approved install', () async {
    payloadGate = Completer<void>();
    payloadEntered = Completer<void>();
    final install = sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {});
    await payloadEntered!.future;
    sandbox.killAllProcesses();
    payloadGate!.complete();
    await install;
    expect(sandbox.isInstalled, isTrue);
  });

  test('cancelled installer retains single flight until extract worker settles', () async {
    payloadGate = Completer<void>();
    payloadEntered = Completer<void>();
    final first = sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {});
    final failed = expectLater(first, throwsA(isA<SandboxCancelledException>()));
    await payloadEntered!.future;
    final cancel = sandbox.cancelInstall();
    final second = sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {});
    expect(identical(first, second), isTrue);
    expect(reads, 1);
    payloadGate!.complete();
    await failed;
    await cancel;
    await sandbox.install(includeRuntimes: false, onPhase: (_, _, _) {});
    expect(reads, 2);
  });

  test('native bootstrap rejection retains prior prefix without publishing', () async {
    final old = Directory('${root.path}/sandbox')..createSync();
    File('${old.path}/keep').writeAsStringSync('unchanged');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (call) async {
      if (call.method == 'getProcessAbi') return 'x86_64';
      if (call.method == 'getSdkInt') return 30;
      if (call.method == 'readBootstrapPayload') return null;
      return null;
    });
    await expectLater(sandbox.install(includeRuntimes: false,
        onPhase: (_, _, _) {}), throwsException);
    expect(File('${old.path}/keep').readAsStringSync(), 'unchanged');
    expect(root.listSync().where((e) => e.path.contains('staging')), isEmpty);
  });
}
