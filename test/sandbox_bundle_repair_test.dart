import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = SandboxService.I;
  late Directory root;
  late String prefix;
  late Uint8List payload;
  var reads = 0;
  var failCandidate = false;
  var failPublished = false;
  var cancelCandidate = false;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Uint8List elf([int machine = 62, bool dependency = false]) {
    final bytes = Uint8List(dependency ? 320 : 64);
    bytes.setAll(0, [127, 69, 76, 70, 2, 1, 1]);
    final data = ByteData.sublistView(bytes);
    data.setUint16(18, machine, Endian.little);
    data.setUint16(52, 64, Endian.little);
    data.setUint16(54, 56, Endian.little);
    if (dependency) {
      data.setUint64(32, 64, Endian.little);
      data.setUint16(56, 2, Endian.little);
      data.setUint32(64, 1, Endian.little);
      data.setUint64(64 + 32, 320, Endian.little);
      data.setUint32(120, 2, Endian.little);
      data.setUint64(128, 176, Endian.little);
      data.setUint64(152, 64, Endian.little);
      data.setUint64(176, 5, Endian.little);
      data.setUint64(184, 256, Endian.little);
      data.setUint64(192, 10, Endian.little);
      data.setUint64(200, 32, Endian.little);
      data.setUint64(208, 1, Endian.little);
      data.setUint64(216, 1, Endian.little);
      bytes.setAll(257, utf8.encode('libfixture.so'));
    }
    return bytes;
  }

  Uint8List bundle({bool manifest = true, bool tamper = false, int machine = 62, bool dependency = false}) {
    final files = <String, List<int>>{
      'bin/gawk': elf(machine, dependency), 'bin/apt': elf(machine), 'bin/apt-get': elf(machine),
      if (dependency) 'lib/libfixture.so.1': elf(machine),
      'SYMLINKS.txt': utf8.encode('gawk←./bin/awk\nlibfixture.so.1←./lib/libfixture.so\n'),
      'home/precious': utf8.encode('MUST NOT EXTRACT'),
    };
    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile.bytes(e.key, e.value));
    }
    if (manifest) {
      archive.addFile(ArchiveFile.string('.ovid-bootstrap-manifest.json', jsonEncode({
        'schema': 1, 'androidAbi': 'x86_64',
        'entries': files.entries.map((e) => {
          'path': e.key, 'size': e.value.length, 'mode': e.key.startsWith('bin/') ? '0755' : '0644',
          'sha256': tamper && e.key == 'bin/gawk' ? '0' * 64 : sha256.convert(e.value).toString(),
        }).toList(),
      })));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  bool native(String path) {
    final f = File(path);
    return f.existsSync() && f.readAsBytesSync().firstOrNull == 127;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ovid-bundle-repair-');
    prefix = '${root.path}/sandbox';
    for (final name in ['bin/bash', 'bin/coreutils', 'lib/libtermux-exec-direct-ld-preload.so', 'home/precious']) {
      final f = File('$prefix/$name');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('preserve $name');
    }
    for (final bin in ['apt', 'apt-get']) {
      File('$prefix/bin/$bin').writeAsStringSync('#!$prefix/bin/sh\n# Ovid-wrapped $bin\nexec "$prefix/bin/ovid-pkg" "\$@"\n');
    }
    Link('$prefix/bin/awk').createSync('gawk');
    reads = 0; failCandidate = false; failPublished = false; cancelCandidate = false; payload = bundle();
    sandbox.resetCheckExistingForTest();
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    messenger.setMockMethodCallHandler(const MethodChannel('ovid/native'), (call) async {
      if (call.method == 'getProcessAbi') return 'x86_64';
      if (call.method == 'readBootstrapPayload') { reads++; return {'abi': 'x86_64', 'bytes': payload}; }
      return null;
    });
    expect(await sandbox.checkExisting(), isTrue);
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.first.contains('.ovid-prerequisite-')) {
        expect(env['PREFIX'], prefix);
        expect(env['LD_LIBRARY_PATH'], contains('$prefix/lib'));
        if (cancelCandidate) throw SandboxCancelledException();
        return failCandidate ? (1, 'CANNOT LINK EXECUTABLE: incompatible library') : (0, 'fixture version');
      }
      final command = args.last;
      if (command.startsWith('awk ')) return native('$prefix/bin/gawk') && !failPublished ? (0, '') : (127, 'gawk missing');
      if (command == 'gawk --version 2>&1') return native('$prefix/bin/gawk') ? (0, '') : (127, 'gawk missing');
      if (command == 'apt --version 2>&1' || command == 'apt-get --version 2>&1') {
        return native('$prefix/bin/${command.split(' ').first}') ? (0, 'apt 3') : (2, 'usage: ovid-pkg');
      }
      // Stop immediately after prerequisite repair, before any network install.
      if (command.startsWith('apt-get update')) throw SandboxCancelledException();
      return (1, 'runtime absent');
    };
  });

  tearDown(() {
    SandboxService.execCheckedOverrideForTest = null;
    sandbox.resetCheckExistingForTest();
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    messenger.setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
    root.deleteSync(recursive: true);
  });

  Future<void> repair() async {
    await expectLater(sandbox.installCoreRuntimes((_, _, _) {}), throwsA(isA<SandboxCancelledException>()));
  }

  test('verified bundle repairs legacy apt wrappers and missing gawk without resetting data', () async {
    final before = File('$prefix/home/precious').readAsStringSync();
    await repair();
    expect(reads, 1);
    for (final bin in ['gawk', 'apt', 'apt-get']) {
      expect(File('$prefix/bin/$bin').readAsBytesSync(), elf());
      expect(File('$prefix/bin/$bin').statSync().mode & 0x49, isNot(0));
    }
    expect(Link('$prefix/bin/awk').targetSync(), 'gawk');
    expect(File('$prefix/home/precious').readAsStringSync(), before);
    expect(Directory(prefix).listSync().where((f) => f.path.contains('.ovid-prerequisite-')), isEmpty);
  });

  test('working upgraded native apt is preserved while gawk is restored', () async {
    final upgraded = [...elf(), 42];
    File('$prefix/bin/apt').writeAsBytesSync(upgraded);
    await repair();
    expect(File('$prefix/bin/apt').readAsBytesSync(), upgraded);
    expect(native('$prefix/bin/gawk'), isTrue);
  });

  test('restores missing ABI matched transitive library and its relative alias', () async {
    payload = bundle(dependency: true);
    await repair();
    expect(File('$prefix/lib/libfixture.so.1').readAsBytesSync(), elf());
    expect(Link('$prefix/lib/libfixture.so').targetSync(), 'libfixture.so.1');
  });

  test('existing upgraded dependency is not overwritten', () async {
    payload = bundle(dependency: true);
    final upgraded = [...elf(), 99];
    File('$prefix/lib/libfixture.so').writeAsBytesSync(upgraded);
    await repair();
    expect(File('$prefix/lib/libfixture.so').readAsBytesSync(), upgraded);
    expect(File('$prefix/lib/libfixture.so.1').existsSync(), isFalse);
  });

  test('missing library alias retains its existing upgraded target', () async {
    payload = bundle(dependency: true);
    final upgraded = [...elf(), 77];
    File('$prefix/lib/libfixture.so.1').writeAsBytesSync(upgraded);
    await repair();
    expect(File('$prefix/lib/libfixture.so.1').readAsBytesSync(), upgraded);
    expect(Link('$prefix/lib/libfixture.so').targetSync(), 'libfixture.so.1');
  });

  test('broken awk alias preserves a working upgraded gawk', () async {
    final upgraded = [...elf(), 99];
    File('$prefix/bin/gawk').writeAsBytesSync(upgraded);
    Link('$prefix/bin/awk').deleteSync();
    Link('$prefix/bin/awk').createSync('absent');
    final normal = SandboxService.execCheckedOverrideForTest!;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.last.startsWith('awk ') && Link('$prefix/bin/awk').targetSync() == 'absent') return (127, 'broken alias');
      return normal(args, env);
    };
    await repair();
    expect(File('$prefix/bin/gawk').readAsBytesSync(), upgraded);
    expect(Link('$prefix/bin/awk').targetSync(), 'gawk');
  });

  test('failure after publication rolls back original wrapper and dangling alias', () async {
    failPublished = true;
    final old = File('$prefix/bin/apt').readAsStringSync();
    await repair();
    expect(native('$prefix/bin/gawk'), isFalse);
    expect(File('$prefix/bin/apt').readAsStringSync(), old);
    expect(Link('$prefix/bin/awk').targetSync(), 'gawk');
  });

  test('cancellation during candidate execution preserves old files and allows retry', () async {
    cancelCandidate = true;
    final old = File('$prefix/bin/apt').readAsStringSync();
    await repair();
    expect(File('$prefix/bin/apt').readAsStringSync(), old);
    expect(native('$prefix/bin/gawk'), isFalse);
    cancelCandidate = false;
    await repair();
    expect(native('$prefix/bin/gawk'), isTrue);
  });

  test('healthy prerequisites avoid reading the bundle entirely', () async {
    for (final bin in ['gawk', 'apt', 'apt-get']) {
      File('$prefix/bin/$bin').writeAsBytesSync([...elf(), 55]);
    }
    await repair();
    expect(reads, 0);
    expect(File('$prefix/bin/apt').readAsBytesSync().last, 55);
  });

  test('symlinked bin directory is refused without modifying its target', () async {
    Directory('$prefix/bin').renameSync('${root.path}/external-bin');
    Link('$prefix/bin').createSync('${root.path}/external-bin');
    final before = File('$prefix/bin/apt').readAsStringSync();
    await repair();
    expect(File('$prefix/bin/apt').readAsStringSync(), before);
    expect(File('${root.path}/external-bin/gawk').existsSync(), isFalse);
  });

  for (final failure in ['manifest', 'hash', 'abi', 'execution']) {
    test('$failure failure preserves every prerequisite and user data', () async {
      payload = bundle(manifest: failure != 'manifest', tamper: failure == 'hash', machine: failure == 'abi' ? 183 : 62);
      failCandidate = failure == 'execution';
      final old = File('$prefix/bin/apt').readAsStringSync();
      await repair();
      expect(native('$prefix/bin/gawk'), isFalse);
      expect(File('$prefix/bin/apt').readAsStringSync(), old);
      expect(File('$prefix/home/precious').readAsStringSync(), 'preserve home/precious');
    });
  }
}
