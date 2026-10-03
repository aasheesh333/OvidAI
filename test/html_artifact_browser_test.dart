// Real Chromium executes the production sandbox document. This verifies CSP
// and frame isolation, not Android WebSettings (covered by device tests).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/html_artifact.dart';

void main() {
  final chrome =
      Platform.environment['CHROME_EXECUTABLE'] ?? '/usr/bin/google-chrome';
  test(
    'real engine renders local JS/CSS while denying network, file and host access',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ovid-artifact-browser-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) {
        requests.add(request.uri.toString());
        request.response.statusCode = 200;
        request.response.write('external');
        request.response.close();
      });
      final endpoint = 'http://127.0.0.1:${server.port}/leak';
      final artifact = HtmlArtifact.create('owner', {
        'html':
            '<button id="count">0</button><img src="$endpoint?image">'
            '<iframe src="$endpoint?frame"></iframe>'
            '<script src="$endpoint?script"></script>'
            '<link rel="stylesheet" href="$endpoint?css">',
        'css':
            'button { color: rgb(255, 0, 0) } body { background: url("$endpoint?background") }',
        'javascript':
            '''
(async () => {
  const checks = {};
  const denied = async (name, fn) => {
    try { await fn(); checks[name] = false; } catch (_) { checks[name] = true; }
  };
  const button = document.getElementById('count');
  button.onclick = () => button.textContent = String(Number(button.textContent) + 1);
  button.click();
  checks.interactive = button.textContent === '1';
  checks.css = getComputedStyle(button).color === 'rgb(255, 0, 0)';
  await denied('parent', () => parent.document.body.innerHTML);
  await denied('cookie', () => document.cookie);
  await denied('storage', () => localStorage.getItem('auth'));
  await denied('fetch', () => fetch('$endpoint?fetch'));
  await denied('file', () => fetch('file:///etc/passwd'));
  await denied('content', () => fetch('content://settings/system'));
  await denied('websocket', () => new Promise((resolve, reject) => {
    const socket = new WebSocket('ws://127.0.0.1:${server.port}/socket');
    socket.onopen = resolve; socket.onerror = reject;
  }));
  await denied('worker', () => new Promise((resolve, reject) => {
    const worker = new Worker(URL.createObjectURL(new Blob(['postMessage(1)'])));
    worker.onmessage = resolve; worker.onerror = reject;
  }));
  checks.native = typeof Ovid === 'undefined' && typeof Android === 'undefined'
    && typeof searchBoxJavaBridge_ === 'undefined' && typeof flutter_inappwebview === 'undefined';
  checks.popup = window.open('$endpoint?popup') === null;
  parent.postMessage(checks, '*');
})();
''',
      });
      // Harness-only observer. Production has no postMessage/native handler.
      final document = artifact.sandboxDocument.replaceFirst('</head>', '''
<script>window.addEventListener('message', e => {
  const result = document.createElement('pre'); result.id = 'results';
  result.textContent = JSON.stringify(e.data); document.body.appendChild(result);
});</script></head>''');
      final file = await File(
        '${dir.path}/artifact.html',
      ).writeAsString(document);
      try {
        final result = await Process.run(chrome, [
          '--headless',
          '--no-sandbox',
          '--disable-gpu',
          '--disable-dev-shm-usage',
          '--disable-background-networking',
          '--no-first-run',
          '--user-data-dir=${dir.path}/profile',
          '--virtual-time-budget=2500',
          '--dump-dom',
          file.uri.toString(),
        ]).timeout(const Duration(seconds: 30));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final match = RegExp(
          r'<pre id="results">(.*?)</pre>',
        ).firstMatch(result.stdout as String);
        expect(match, isNotNull, reason: '${result.stdout}\n${result.stderr}');
        final checks = jsonDecode(match!.group(1)!) as Map;
        expect(checks, {
          'interactive': true,
          'css': true,
          'parent': true,
          'cookie': true,
          'storage': true,
          'fetch': true,
          'file': true,
          'content': true,
          'websocket': true,
          'worker': true,
          'native': true,
          'popup': true,
        });
        expect(requests, isEmpty, reason: 'No resource may reach the network.');
      } finally {
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
    skip: !File(chrome).existsSync()
        ? 'Set CHROME_EXECUTABLE to run real-engine security checks.'
        : false,
  );
}
