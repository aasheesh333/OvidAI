import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// JVM + proot-Ubuntu toolchains: the agent must be able to run java, kotlin
/// and (inside proot Ubuntu) flutter on demand — "like proot ubuntu".
/// Installs are lazy/on-demand with pinned, verified artifacts; these tests
/// pin the pure surface (versions, URLs, hashes, triggers) without touching
/// the network or a real sandbox.
void main() {
  group('kotlin toolchain pins', () {
    test('pinned compiler version, URL and measured hash', () {
      expect(SandboxService.kotlinVersion, '2.4.20');
      expect(
        SandboxService.kotlinZipUrl,
        'https://github.com/JetBrains/kotlin/releases/download/'
        'v2.4.20/kotlin-compiler-2.4.20.zip',
      );
      // Measured 2026-09-20 from the official GitHub release asset
      // (89,729,132 bytes; single top-level kotlinc/ dir).
      expect(
        SandboxService.kotlinZipSha256,
        '59e9ca74c7904ef2c122b12114937673ccce68de820a663f0ed66ccf8799e0b7',
      );
      expect(SandboxService.kotlinZipBytes, 89729132);
    });
  });

  group('ubuntu rootfs pins', () {
    test('arch mapping follows the sandbox device arch', () {
      expect(SandboxService.ubuntuArchFor('arm64'), 'arm64');
      expect(SandboxService.ubuntuArchFor('arm'), 'armhf');
      expect(SandboxService.ubuntuArchFor('x86_64'), 'amd64');
    });

    test('file names and official SHA256SUMS hashes', () {
      expect(
        SandboxService.ubuntuRootfsFile('arm64'),
        'ubuntu-base-24.04.5-base-arm64.tar.gz',
      );
      expect(
        SandboxService.ubuntuRootfsFile('amd64'),
        'ubuntu-base-24.04.5-base-amd64.tar.gz',
      );
      expect(
        SandboxService.ubuntuRootfsFile('armhf'),
        'ubuntu-base-24.04.5-base-armhf.tar.gz',
      );
      // From https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/SHA256SUMS
      expect(
        SandboxService.ubuntuRootfsSha256('arm64'),
        'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2',
      );
      expect(
        SandboxService.ubuntuRootfsSha256('amd64'),
        'e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86',
      );
      expect(
        SandboxService.ubuntuRootfsSha256('armhf'),
        '4fcee4d278f1c5232e085a021a85e4c6cef3853557a88d98ff380b5e5d5841bb',
      );
    });
  });

  group('flutter sdk pins', () {
    test('stable release URL is pinned', () {
      expect(SandboxService.flutterVersion, '3.47.5');
      expect(
        SandboxService.flutterSdkUrl,
        'https://storage.googleapis.com/flutter_infra_release/releases/'
        'stable/linux/flutter_linux_3.47.5-stable.tar.xz',
      );
    });
  });

  group('JVM trigger heuristic', () {
    test('matches java/kotlin/gradle invocations, not lookalikes', () {
      for (final cmd in [
        'java -version',
        'javac Main.java',
        'kotlin Main.kt',
        'kotlinc Main.kt -include-runtime -d main.jar',
        'gradle build',
        './gradlew assembleDebug',
        'mvn package',
      ]) {
        expect(
          AgentService.looksLikeJvmCommandForTest(cmd),
          isTrue,
          reason: cmd,
        );
      }
      for (final cmd in [
        'make build',
        'node index.js',
        'echo java',
        'myjavascript',
      ]) {
        expect(
          AgentService.looksLikeJvmCommandForTest(cmd),
          isFalse,
          reason: cmd,
        );
      }
    });
  });

  group('wiring pins', () {
    test('sandbox exposes the toolchain ensures', () {
      final src = File(
        'lib/core/sandbox_service.dart',
      ).readAsStringSync();
      for (final name in [
        'Future<bool> ensureJdk',
        'Future<bool> ensureKotlin',
        'Future<bool> ensureProotUbuntu',
        'Future<String> execProot',
        'Future<bool> ensureFlutter',
      ]) {
        expect(src, contains(name), reason: name);
      }
    });

    test('run_shell triggers JVM provisioning like the compiler trigger', () {
      final src = File(
        'lib/core/agent_service.dart',
      ).readAsStringSync();
      final i = src.indexOf("case 'run_shell':");
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 20000);
      expect(body, contains('_looksLikeJvmCommand(cmd)'));
      expect(body, contains('SandboxService.I.ensureJdk('));
      expect(body, contains('SandboxService.I.ensureKotlin('));
    });
  });
}
