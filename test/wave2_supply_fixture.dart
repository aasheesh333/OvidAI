import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ephemeral offline signing authority. Never substitutes the runtime verifier.
class SignedRepositoryFixture {
  final String root;
  late final String home = '$root/signing';
  SignedRepositoryFixture(this.root) {
    Directory(home).createSync(recursive: true);
    run('chmod', ['700', home]);
    run('gpg', [
      '--homedir',
      home,
      '--batch',
      '--passphrase',
      '',
      '--quick-generate-key',
      'Offline fixture <fixture@example.test>',
      'ed25519',
      'sign',
      '0',
    ]);
  }

  void run(String command, List<String> args) {
    final r = Process.runSync(command, args);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  }

  void trust(String prefix) {
    final key = '$prefix/etc/apt/trusted.gpg.d/fixture.gpg';
    Directory(File(key).parent.path).createSync(recursive: true);
    run('gpg', [
      '--homedir',
      home,
      '--batch',
      '--yes',
      '--output',
      key,
      '--export',
    ]);
  }

  void seedCache(
    String prefix,
    String index, {
    String mirror = 'https://packages.termux.dev/apt/termux-main',
  }) {
    trust(prefix);
    publish(index);
    final cache = '$prefix/var/cache/ovid-pkg';
    final generation = '$cache/generation.fixture';
    Directory(generation).createSync(recursive: true);
    File('$root/repo/dists/stable/Release').copySync('$generation/Release');
    File(
      '$root/repo/dists/stable/Release.gpg',
    ).copySync('$generation/Release.gpg');
    File('$generation/Packages').writeAsStringSync(index);
    File('$generation/mirror').writeAsStringSync('$mirror\n');
    File('$cache/current').writeAsStringSync('generation.fixture\n');
  }

  void publish(
    String index, {
    DateTime? date,
    DateTime? expires,
    bool missingHash = false,
    bool inRelease = false,
    bool gzipIndex = false,
    String arch = 'aarch64',
  }) {
    final dir = '$root/repo/dists/stable';
    final path = 'main/binary-$arch/Packages';
    Directory('$dir/main/binary-$arch').createSync(recursive: true);
    File('$dir/$path').writeAsStringSync(index);
    final bytes = File('$dir/$path').readAsBytesSync();
    final compressed = gzip.encode(bytes);
    File('$dir/$path.gz').writeAsBytesSync(compressed);
    final now = DateTime.now().toUtc();
    final release =
        'Suite: stable\nCodename: stable\n'
        'Date: ${HttpDate.format(date ?? now.subtract(const Duration(minutes: 1)))}\n'
        'Valid-Until: ${HttpDate.format(expires ?? now.add(const Duration(days: 1)))}\n'
        'SHA256:\n'
        '${missingHash ? '' : ' ${sha256.convert(bytes)} ${bytes.length} $path\n'}'
        '${gzipIndex ? ' ${sha256.convert(compressed)} ${compressed.length} $path.gz\n' : ''}';
    File('$dir/Release').writeAsStringSync(release);
    run('gpg', [
      '--homedir',
      home,
      '--batch',
      '--yes',
      '--digest-algo',
      'SHA256',
      '--output',
      '$dir/Release.gpg',
      '--detach-sign',
      '$dir/Release',
    ]);
    final inline = File('$dir/InRelease');
    if (inline.existsSync()) inline.deleteSync();
    if (inRelease) {
      run('gpg', [
        '--homedir',
        home,
        '--batch',
        '--yes',
        '--digest-algo',
        'SHA256',
        '--output',
        inline.path,
        '--clearsign',
        '$dir/Release',
      ]);
    }
  }
}
