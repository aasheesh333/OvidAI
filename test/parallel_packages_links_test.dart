import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parallel_packages_graph_test.dart' show PackageFixture;

void main() {
  late PackageFixture f;
  setUp(() => f = PackageFixture());
  tearDown(() => f.dispose());

  void file(String path, [String text = 'payload']) {
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(text);
  }

  void link(String path, String target) {
    Link(path).parent.createSync(recursive: true);
    Link(path).createSync(target);
  }

  Future<void> installed() async {
    final result = await f.install(['app']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  void replaceData(String name, {String? symlink, String? hardlink}) {
    final data = '${f.root.path}/data.tar.xz';
    final generated = Process.runSync('python3', [
      '-c',
      r'''
import io, sys, tarfile
output, name, kind, target = sys.argv[1:]
with tarfile.open(output, 'w:xz', format=tarfile.GNU_FORMAT) as tar:
    entry = tarfile.TarInfo(name)
    if kind:
        entry.type = tarfile.SYMTYPE if kind == 'symlink' else tarfile.LNKTYPE
        entry.linkname = target
        tar.addfile(entry)
    else:
        entry.size = 7
        tar.addfile(entry, io.BytesIO(b'payload'))
''',
      data,
      name,
      symlink != null ? 'symlink' : (hardlink != null ? 'hardlink' : ''),
      symlink ?? hardlink ?? '',
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final archive = File('${f.root.path}/repo/pool/app_1.0_aarch64.deb');
    final replaced = Process.runSync('python3', [
      '-c',
      r'''
import pathlib, sys
archive, replacement = map(pathlib.Path, sys.argv[1:])
source = archive.read_bytes()
assert source[:8] == b'!<arch>\n'
result = bytearray(source[:8])
offset = 8
found = False
while offset < len(source):
    header = bytearray(source[offset:offset+60])
    size = int(header[48:58])
    body = source[offset+60:offset+60+size]
    if header[:16].decode().strip().rstrip('/').startswith('data.tar.'):
        body = replacement.read_bytes()
        header[:16] = b'data.tar.xz'.ljust(16)
        header[48:58] = str(len(body)).encode().ljust(10)
        found = True
    result.extend(header)
    result.extend(body)
    if len(body) % 2: result.extend(b'\n')
    offset += 60 + size + size % 2
assert found
archive.write_bytes(result)
''',
      archive.path,
      data,
    ]);
    expect(replaced.exitCode, 0, reason: '${replaced.stderr}');
    f.records[0] = f.records[0]
        .replaceFirst(RegExp(r'Size: [^\n]*'), 'Size: ${archive.lengthSync()}')
        .replaceFirst(
          RegExp(r'SHA256: [^\n]*'),
          'SHA256: ${sha256.convert(archive.readAsBytesSync())}',
        );
  }

  for (final termux in [false, true]) {
    test('reinstall repairs safe symlink leaf (Termux=$termux)', () async {
      f.add('app', symlink: 'app', termux: termux);
      await installed();
      File('${f.prefix}/share/app').writeAsStringSync('damaged');
      await installed();
      expect(Link('${f.prefix}/share/link').targetSync(), 'app');
      expect(File('${f.prefix}/share/link').readAsStringSync(), '1.0');
    });

    test(
      'contained parent-relative executable link (Termux=$termux)',
      () async {
        f.add(
          'app',
          termux: termux,
          layout: (p) {
            file('$p/lib/tool/entrypoint');
            link('$p/bin/tool', '../lib/tool/entrypoint');
          },
        );
        await installed();
        await installed();
        expect(
          Link('${f.prefix}/bin/tool').targetSync(),
          '../lib/tool/entrypoint',
        );
        expect(File('${f.prefix}/bin/tool').readAsStringSync(), 'payload');
      },
    );

    test(
      'contained directory alias receives repair (Termux=$termux)',
      () async {
        Directory('${f.prefix}/real-share').createSync();
        link('${f.prefix}/share', 'real-share');
        f.add('app', termux: termux);
        await installed();
        expect(Link('${f.prefix}/share').targetSync(), 'real-share');
        expect(File('${f.prefix}/real-share/app').readAsStringSync(), '1.0');
      },
    );
  }

  test(
    'regular file replaces contained existing symlink without changing target',
    () async {
      file('${f.prefix}/share/original', 'keep');
      link('${f.prefix}/share/app', 'original');
      f.add('app');
      await installed();
      expect(FileSystemEntity.isLinkSync('${f.prefix}/share/app'), isFalse);
      expect(File('${f.prefix}/share/original').readAsStringSync(), 'keep');
      expect(File('${f.prefix}/share/app').readAsStringSync(), '1.0');
    },
  );

  test('safe dangling leaf is repaired without following it', () async {
    link('${f.prefix}/share/link', 'missing');
    f.add('app', symlink: 'app');
    await installed();
    expect(File('${f.prefix}/share/link').readAsStringSync(), '1.0');
    expect(File('${f.prefix}/share/missing').existsSync(), isFalse);
  });

  test('versioned library symlink chain is preserved', () async {
    f.add(
      'app',
      layout: (p) {
        file('$p/lib/libfixture.so.1.2');
        link('$p/lib/libfixture.so.1', 'libfixture.so.1.2');
        link('$p/lib/libfixture.so', 'libfixture.so.1');
      },
    );
    await installed();
    await installed();
    expect(File('${f.prefix}/lib/libfixture.so').readAsStringSync(), 'payload');
  });

  test('hard linked regular package files preserve identity', () async {
    f.add(
      'app',
      layout: (p) {
        file('$p/share/original');
        expect(
          Process.runSync('/bin/ln', [
            '$p/share/original',
            '$p/share/alias',
          ]).exitCode,
          0,
        );
      },
    );
    await installed();
    expect(
      FileSystemEntity.identicalSync(
        '${f.prefix}/share/original',
        '${f.prefix}/share/alias',
      ),
      isTrue,
    );
  });

  test(
    'spaces brackets and punctuation in data names and link targets survive',
    () async {
      f.add(
        'app',
        layout: (p) {
          file('$p/share/docs/API reference [v1]@2.txt');
          link('$p/share/manual link', 'docs/API reference [v1]@2.txt');
        },
      );
      await installed();
      expect(
        File('${f.prefix}/share/manual link').readAsStringSync(),
        'payload',
      );
    },
  );

  for (final termux in [false, true]) {
    test('parent traversal symlink escape rejected (Termux=$termux)', () async {
      f.add(
        'app',
        termux: termux,
        layout: (p) {
          link('$p/bin/tool', '../../outside');
        },
      );
      f.expectRejected(
        await f.install(['app']),
        'archive',
        beforeDownload: false,
      );
    });
  }

  test(
    'archive link cannot escape through an existing external directory alias',
    () async {
      final outside = Directory('${f.root.path}/outside')..createSync();
      link('${f.prefix}/external', outside.path);
      f.add('app', layout: (p) => link('$p/bin/tool', '../external/tool'));
      f.expectRejected(
        await f.install(['app']),
        'symlink',
        beforeDownload: false,
      );
      expect(outside.listSync(), isEmpty);
    },
  );

  test('symlink cycle fails before prefix publication', () async {
    f.add(
      'app',
      layout: (p) {
        link('$p/share/one', 'two');
        link('$p/share/two', 'one');
      },
    );
    f.expectRejected(
      await f.install(['app']),
      'archive',
      beforeDownload: false,
    );
  });

  test(
    'parent segments cannot hide escape through another archive symlink',
    () async {
      f.add(
        'app',
        layout: (p) {
          link('$p/share/base', '.');
          link('$p/share/link', 'base/../../outside');
        },
      );
      f.expectRejected(
        await f.install(['app']),
        'archive',
        beforeDownload: false,
      );
    },
  );

  test(
    'existing absolute symlink inside prefix supports contained directory repair',
    () async {
      Directory('${f.prefix}/actual').createSync();
      link('${f.prefix}/share', '${f.prefix}/actual');
      f.add('app');
      await installed();
      expect(File('${f.prefix}/actual/app').readAsStringSync(), '1.0');
    },
  );

  test('nested contained directory alias survives Termux relocation', () async {
    Directory('${f.prefix}/actual').createSync();
    link('${f.prefix}/share/docs', '../actual');
    f.add('app', termux: true, layout: (p) => file('$p/share/docs/manual'));
    await installed();
    expect(Link('${f.prefix}/share/docs').targetSync(), '../actual');
    expect(File('${f.prefix}/actual/manual').readAsStringSync(), 'payload');
  });

  test(
    'parent segments cannot hide escape through existing directory alias',
    () async {
      link('${f.prefix}/base', '.');
      f.add('app', layout: (p) => link('$p/bin/tool', '../base/../outside'));
      f.expectRejected(
        await f.install(['app']),
        'symlink',
        beforeDownload: false,
      );
    },
  );

  test(
    'failed extraction leaves existing safe leaf and target untouched',
    () async {
      file('${f.prefix}/share/original', 'keep');
      link('${f.prefix}/share/link', 'original');
      f.add('app', symlink: 'app');
      f.stub('dpkg-deb', r'''
if [ "$1" = -x ]; then exit 7; fi
exec /usr/bin/dpkg-deb "$@"
''');
      final result = await f.install(['app']);
      expect(result.exitCode, 7);
      expect(Link('${f.prefix}/share/link').targetSync(), 'original');
      expect(File('${f.prefix}/share/original').readAsStringSync(), 'keep');
    },
  );

  for (final path in ['../outside', 'share/../../outside', '/outside']) {
    test('archive member traversal remains rejected: $path', () async {
      f.add('app');
      replaceData(path);
      f.expectRejected(
        await f.install(['app']),
        'archive',
        beforeDownload: false,
      );
    });
  }

  for (final target in ['../outside', '/outside', 'missing']) {
    test(
      'hard link cannot reference outside or absent data: $target',
      () async {
        f.add('app');
        replaceData('share/alias', hardlink: target);
        f.expectRejected(
          await f.install(['app']),
          'archive',
          beforeDownload: false,
        );
      },
    );
  }

  test('absolute archive symlink is rejected before publication', () async {
    f.add('app');
    replaceData('share/link', symlink: '/outside');
    f.expectRejected(
      await f.install(['app']),
      'archive',
      beforeDownload: false,
    );
  });

  for (final termux in [false, true]) {
    for (final split in [false, true]) {
      test(
        'mixed staged and existing links cannot escape (Termux=$termux, split=$split)',
        () async {
          link('${f.prefix}/base', '.');
          final outside = File('${f.root.path}/outside')
            ..writeAsStringSync('untouched');
          f.add(
            'app',
            termux: termux,
            depends: split ? 'other' : '',
            layout: (p) {
              link('$p/share/link', 'base/../outside');
              if (!split) link('$p/share/base', '../base');
            },
          );
          if (split) {
            f.add(
              'other',
              termux: termux,
              layout: (p) => link('$p/share/base', '../base'),
            );
          }
          f.expectRejected(
            await f.install(['app']),
            'symlink',
            beforeDownload: false,
          );
          expect(Link('${f.prefix}/base').targetSync(), '.');
          expect(outside.readAsStringSync(), 'untouched');
          expect(Directory('${f.prefix}/data').existsSync(), isFalse);
        },
      );

      test(
        'mixed staged and existing contained links remain valid (Termux=$termux, split=$split)',
        () async {
          Directory('${f.prefix}/actual').createSync();
          link('${f.prefix}/base', 'actual');
          file('${f.prefix}/outside', 'contained');
          f.add(
            'app',
            termux: termux,
            depends: split ? 'other' : '',
            layout: (p) {
              link('$p/share/link', 'base/../outside');
              if (!split) link('$p/share/base', '../base');
            },
          );
          if (split) {
            f.add(
              'other',
              termux: termux,
              layout: (p) => link('$p/share/base', '../base'),
            );
          }
          await installed();
          expect(
            File('${f.prefix}/share/link').readAsStringSync(),
            'contained',
          );
          expect(
            File('${f.prefix}/share/link').resolveSymbolicLinksSync(),
            '${f.prefix}/outside',
          );
        },
      );
    }
  }

  for (final target in ['actual\n/..', 'actual\n', 'actual\nsegment\n/..']) {
    test(
      'existing multiline target is rejected in combined graph: ${target.replaceAll('\n', r'\n')}',
      () async {
        // For the embedded/multiline escape case, realpath(base) is PREFIX,
        // whereas reading only its first line incorrectly models PREFIX/actual.
        final directory = target.endsWith('/..')
            ? target.substring(0, target.length - 3)
            : target;
        Directory('${f.prefix}/$directory').createSync(recursive: true);
        link('${f.prefix}/base', target);
        final sentinel = File('${f.root.path}/outside')
          ..writeAsStringSync('untouched');
        f.add(
          'app',
          layout: (p) {
            link('$p/share/base', '../base');
            link('$p/share/link', 'base/../outside');
          },
        );
        f.expectRejected(
          await f.install(['app']),
          'unsupported existing link target',
          beforeDownload: false,
        );
        expect(Link('${f.prefix}/base').targetSync(), target);
        expect(sentinel.readAsStringSync(), 'untouched');
      },
    );
  }

  for (final target in [
    'actual',
    'actual directory',
    "actual'quoted",
    'actual/segment/..',
  ]) {
    test(
      'complete ordinary existing target remains supported: $target',
      () async {
        Directory('${f.prefix}/$target').createSync(recursive: true);
        link('${f.prefix}/base', target);
        file('${f.prefix}/outside', 'contained');
        f.add(
          'app',
          layout: (p) {
            link('$p/share/base', '../base');
            link('$p/share/link', 'base/../outside');
          },
        );
        await installed();
        expect(File('${f.prefix}/share/link').readAsStringSync(), 'contained');
      },
    );
  }

  test('cross-package link parent is rejected before extraction', () async {
    f.add(
      'app',
      depends: 'other',
      layout: (p) => link('$p/share/alias', 'real'),
    );
    f.add('other', layout: (p) => file('$p/share/alias/file'));
    f.expectRejected(
      await f.install(['app']),
      'archive',
      beforeDownload: false,
    );
  });
}
