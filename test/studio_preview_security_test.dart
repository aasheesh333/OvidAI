import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/studio_preview_client.dart';
import 'package:ovid_ai/ui/v2/studio/preview_web_view.dart';

const String _base = 'https://cloud.test/cloud/v1';
const String _session = 'session-1';
const String _serverSession = '0199aaaa-0000-7000-8000-00000000e701';
const String _previewId = 'preview-1';
const String _patCanary = 'ghp_1234567890abcdefghijklmnopQRSTUVWXYZ';

Map<String, Object?> _previewJson({
  String status = 'running',
  String kind = 'dev_server',
}) => <String, Object?>{
  'id': _previewId,
  'kind': kind,
  'status': status,
  'generation': 3,
  'expiresAt': '2026-10-24T20:00:00.000Z',
  'lastAccessAt': null,
  'logAvailable': false,
};

Map<String, Object> _launchJson(String ticket) => <String, Object>{
  'launchUrl': 'https://preview.test/preview/exchange?ticket=$ticket',
  'ticketExpiresAt': '2026-10-24T19:01:00.000Z',
  'cookieExpiresAt': '2026-10-24T19:15:00.000Z',
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const <String, String>{'content-type': 'application/json'},
);

class _Gateway {
  _Gateway(this.handler);

  final Future<http.Response> Function(http.Request request) handler;
  final List<http.Request> requests = <http.Request>[];

  CloudRestClient get rest => CloudRestClient(
    httpClient: MockClient((request) {
      requests.add(request);
      return handler(request);
    }),
    headers: CloudHeaders.forTest(
      idToken: 'ovid-id-token',
      appCheck: 'ovid-app-check',
    ),
    restBase: _base,
  );
}

StudioPreviewClient _client(_Gateway gateway) => StudioPreviewClient(
  rest: gateway.rest,
  sessions: CloudSessionStore.forTest(
    idMap: const <String, String>{_session: _serverSession},
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StudioPreviewClient', () {
    test('script capability comes only from a valid server registration', () {
      final registration = StudioPreviewRegistration.tryParse(<String, Object>{
        'projectDir': 'app',
        'startScriptId': 'start',
      });

      expect(registration, isNotNull);
      expect(registration!.projectDir, 'app');
      expect(registration.startScriptId, 'start');
      expect(
        StudioPreviewRegistration.tryParse(<String, Object>{
          'projectDir': 'app',
        }),
        isNull,
      );
      expect(
        StudioPreviewRegistration.tryParse(<String, Object>{
          'projectDir': '../outside',
          'startScriptId': 'dev',
        }),
        isNull,
      );
      expect(StudioPreviewRegistration.tryParse(null), isNull);
    });

    test(
      'preview creation sends only approved project and script identity',
      () async {
        late Map<String, dynamic> sentBody;
        final gateway = _Gateway((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return _json(_previewJson(status: 'starting'), 201);
        });
        final previews = _client(gateway);

        final created = await previews.create(
          _session,
          projectDir: 'app',
          startScriptId: 'dev',
        );

        expect(created.id, _previewId);
        expect(created.kind, StudioPreviewKind.devServer);
        expect(created.status, StudioPreviewStatus.starting);
        expect(sentBody, <String, Object>{
          'projectDir': 'app',
          'startScriptId': 'dev',
        });
        expect(sentBody.keys, isNot(contains('port')));
        expect(sentBody.keys, isNot(contains('host')));
        expect(sentBody.keys, isNot(contains('upstream')));
        expect(sentBody.keys, isNot(contains('command')));
        expect(sentBody.keys, isNot(contains('url')));
        expect(sentBody.keys, isNot(contains('script')));
        expect(gateway.requests.single.method, 'POST');
        expect(
          gateway.requests.single.url.path,
          '/cloud/v1/studio/sessions/$_serverSession/previews',
        );
        expect(gateway.requests.single.headers, isNot(contains('cookie')));
        expect(gateway.requests.single.headers, isNot(contains('Cookie')));
        expect(requestsText(gateway.requests), isNot(contains(_patCanary)));
      },
    );

    test(
      'open refresh and stop use registered identity with fresh tickets',
      () async {
        var ticket = 0;
        final gateway = _Gateway((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/previews')) {
            return _json(_previewJson(), 201);
          }
          if (request.method == 'GET') return _json(_previewJson());
          if (request.method == 'POST' &&
              request.url.path.endsWith('/ticket')) {
            ticket++;
            return _json(_launchJson('single-use-$ticket'));
          }
          if (request.method == 'POST' && request.url.path.endsWith('/stop')) {
            expect(request.body, isEmpty);
            return _json(_previewJson(status: 'stopped'));
          }
          return _json(<String, Object>{
            'error': <String, Object>{'code': 'not_found', 'message': 'No.'},
          }, 404);
        });
        final previews = _client(gateway);
        await previews.create(
          _session,
          projectDir: 'app',
          startScriptId: 'dev',
        );

        final opened = await previews.open(_previewId);
        final refreshed = await previews.refresh(_previewId);

        expect(opened.launch?.launchUrl, contains('single-use-1'));
        expect(refreshed.launch?.launchUrl, contains('single-use-2'));
        expect(
          opened.launch?.cleanUrl(_previewId),
          'https://preview.test/preview/$_previewId/',
        );
        expect(
          refreshed.launch?.cleanUrl(_previewId),
          isNot(contains('ticket')),
        );
        final ticketRequests = gateway.requests.where(
          (request) => request.url.path.endsWith('/ticket'),
        );
        expect(ticketRequests, hasLength(2));
        for (final request in ticketRequests) {
          expect(request.body, isEmpty);
          expect(request.url.query, isEmpty);
          expect(request.headers, isNot(contains('cookie')));
          expect(request.headers, isNot(contains('Cookie')));
        }

        await previews.stop(_previewId);
        expect(gateway.requests.last.method, 'POST');
        expect(
          gateway.requests.last.url.path,
          '/cloud/v1/studio/sessions/$_serverSession/previews/$_previewId/stop',
        );
        expect(requestsText(gateway.requests), isNot(contains(_patCanary)));
      },
    );

    test(
      'unregistered cross tenant preview id is denied before any request',
      () async {
        final gateway = _Gateway((request) async => _json(_previewJson()));
        final previews = _client(gateway);

        await expectLater(
          previews.open('another-users-preview'),
          throwsA(
            isA<StudioPreviewException>().having(
              (error) => error.code,
              'code',
              'unknown_preview',
            ),
          ),
        );
        expect(gateway.requests, isEmpty);
      },
    );

    test(
      'denied responses and PAT canaries never become a launch or visible error',
      () async {
        final gateway = _Gateway((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/previews')) {
            return _json(_previewJson(), 201);
          }
          return _json(<String, Object>{
            'error': <String, Object>{
              'code': 'preview_denied',
              'message': 'denied $_patCanary',
            },
          }, 403);
        });
        final previews = _client(gateway);
        await previews.create(
          _session,
          projectDir: 'app',
          startScriptId: 'dev',
        );

        await expectLater(
          previews.open(_previewId),
          throwsA(
            isA<StudioPreviewException>()
                .having((error) => error.code, 'code', 'preview_denied')
                .having(
                  (error) => error.toString(),
                  'safe message',
                  isNot(contains(_patCanary)),
                ),
          ),
        );
        expect(requestsText(gateway.requests), isNot(contains(_patCanary)));
      },
    );

    test(
      'project deletion and hibernation stop only registered previews',
      () async {
        final gateway = _Gateway((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/previews')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return _json(
              _previewJson(status: 'running')
                ..['id'] = 'preview-${body['projectDir']}',
              201,
            );
          }
          if (request.method == 'POST' && request.url.path.endsWith('/stop')) {
            return _json(_previewJson(status: 'stopped'));
          }
          return _json(_previewJson());
        });
        final previews = _client(gateway);
        await previews.create(
          _session,
          projectDir: 'app',
          startScriptId: 'dev',
        );
        await previews.create(
          _session,
          projectDir: 'admin',
          startScriptId: 'dev',
        );

        await previews.stopProject('app');
        expect(
          gateway.requests.where(
            (request) => request.url.path.endsWith('/stop'),
          ),
          hasLength(1),
        );
        expect(
          gateway.requests.last.url.path,
          endsWith('/previews/preview-app/stop'),
        );
        await previews.stopProject('app');
        expect(
          gateway.requests.where(
            (request) => request.url.path.endsWith('/stop'),
          ),
          hasLength(1),
        );

        await previews.stopAll();
        expect(
          gateway.requests.where(
            (request) => request.url.path.endsWith('/stop'),
          ),
          hasLength(2),
        );
        expect(
          gateway.requests.last.url.path,
          endsWith('/previews/preview-admin/stop'),
        );
      },
    );

    test(
      'unsafe launch metadata is rejected instead of producing a WebView URL',
      () {
        for (final url in <String>[
          'http://preview.test/preview/exchange?ticket=abc',
          'https://user:pass@preview.test/preview/exchange?ticket=abc',
          'https://preview.test:8443/preview/exchange?ticket=abc',
          'https://preview.test/cloud/v1?ticket=abc',
          'https://preview.test/preview/exchange?ticket=abc&host=127.0.0.1',
          'https://preview.test/preview/exchange?ticket=abc#fragment',
        ]) {
          expect(
            () => StudioPreviewLaunch.fromJson(<String, Object>{
              'launchUrl': url,
              'ticketExpiresAt': '2026-10-24T19:01:00.000Z',
              'cookieExpiresAt': '2026-10-24T19:15:00.000Z',
            }),
            throwsA(isA<StudioPreviewException>()),
            reason: url,
          );
        }
      },
    );
  });

  group('StudioPreviewWebView', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channels = <int, MethodChannel>{};
    final nativeCalls = <String>[];

    setUp(() {
      StudioPreviewWebView.resetConsumedLaunchesForTest();
      nativeCalls.clear();
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        final args = call.arguments as Map;
        final id = args['id'] as int;
        if (call.method == 'create') {
          final channel = MethodChannel('ovid/studio-preview/$id');
          channels[id] = channel;
          messenger.setMockMethodCallHandler(channel, (call) async {
            nativeCalls.add('${call.method}:$id');
            return null;
          });
          return 1;
        }
        if (call.method == 'dispose') nativeCalls.add('platformDispose:$id');
        return null;
      });
    });

    tearDown(() {
      StudioPreviewWebView.resetConsumedLaunchesForTest();
      for (final channel in channels.values) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      channels.clear();
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });

    StudioPreviewLaunch launch([String ticket = 'one-use']) =>
        StudioPreviewLaunch.fromJson(_launchJson(ticket));

    Future<void> emit(int id, String method, [Object? arguments]) async {
      await messenger.handlePlatformMessage(
        channels[id]!.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );
    }

    testWidgets('creation carries no Ovid headers cookie host port or PAT', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioPreviewWebView(
              previewId: _previewId,
              launch: launch(),
              kind: StudioPreviewKind.devServer,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final view = tester.widget<AndroidView>(find.byType(AndroidView));
      expect(view.viewType, 'ovid/studio-preview');
      expect(view.creationParams, <String, Object>{
        'previewId': _previewId,
        'launchUrl': launch().launchUrl,
        'kind': 'dev_server',
      });
      final params = jsonEncode(view.creationParams);
      expect(params, isNot(contains('Authorization')));
      expect(params, isNot(contains('Cookie')));
      expect(params, isNot(contains('upstream')));
      expect(params, isNot(contains('port')));
      expect(params, isNot(contains(_patCanary)));
      expect(nativeCalls, contains('startPreview:0'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(nativeCalls, contains('disposePreview:0'));
    });

    testWidgets('a native remount cannot replay the same launch ticket', (
      tester,
    ) async {
      final errors = <String>[];
      final sharedLaunch = launch('never-reuse-this-ticket');
      Widget host(Key key) => MaterialApp(
        home: StudioPreviewWebView(
          key: key,
          previewId: _previewId,
          launch: sharedLaunch,
          kind: StudioPreviewKind.devServer,
          onError: errors.add,
        ),
      );
      await tester.pumpWidget(host(const ValueKey<String>('first')));
      await tester.pumpAndSettle();
      expect(
        nativeCalls.where((call) => call.startsWith('startPreview:')),
        hasLength(1),
      );

      await tester.pumpWidget(host(const ValueKey<String>('remounted')));
      await tester.pumpAndSettle();

      expect(
        nativeCalls.where((call) => call.startsWith('startPreview:')),
        hasLength(1),
      );
      expect(errors, <String>['ticket_replay']);
      expect(find.byType(AndroidView), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('static and dev identities are distinct for native policy', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StudioPreviewWebView(
            previewId: _previewId,
            launch: launch(),
            kind: StudioPreviewKind.staticSite,
          ),
        ),
      );
      await tester.pumpAndSettle();
      var view = tester.widget<AndroidView>(find.byType(AndroidView));
      expect(view.creationParams, containsPair('kind', 'static'));

      await tester.pumpWidget(
        MaterialApp(
          home: StudioPreviewWebView(
            previewId: _previewId,
            launch: launch('fresh-ticket'),
            kind: StudioPreviewKind.devServer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      view = tester.widget<AndroidView>(find.byType(AndroidView));
      expect(view.creationParams, containsPair('kind', 'dev_server'));
      expect(
        view.creationParams,
        containsPair('launchUrl', launch('fresh-ticket').launchUrl),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'replay cross tenant and denied path remove the frame with safe errors',
      (tester) async {
        for (final code in <String>[
          'ticket_replay',
          'cross_tenant',
          'preview_denied',
        ]) {
          final errors = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              home: StudioPreviewWebView(
                previewId: _previewId,
                launch: launch(code),
                kind: StudioPreviewKind.devServer,
                onError: errors.add,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final id = channels.keys.last;
          await emit(id, 'loadError', <String, Object>{
            'code': code,
            'message': 'native detail must not be shown $_patCanary',
          });
          await tester.pumpAndSettle();

          expect(errors, <String>[code]);
          expect(find.byType(AndroidView), findsNothing);
          expect(find.textContaining(_patCanary), findsNothing);
          expect(find.textContaining('native detail'), findsNothing);
          expect(nativeCalls, contains('disposePreview:$id'));
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      },
    );

    testWidgets('hibernate disposes the isolated view and notifies the host', (
      tester,
    ) async {
      var hibernated = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StudioPreviewWebView(
            previewId: _previewId,
            launch: launch(),
            kind: StudioPreviewKind.devServer,
            onHibernate: () => hibernated++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final id = channels.keys.single;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      expect(hibernated, 1);
      expect(nativeCalls, contains('disposePreview:$id'));
      // A paused engine need not paint. On resume the consumed ticket must not
      // be mounted again; only a host-minted fresh launch may create a view.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('MainActivity registers preview beside rich and voice channels', () {
    final source = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
    ).readAsStringSync();
    final html = source.indexOf('"ovid/html-artifact"');
    final preview = source.indexOf('"ovid/studio-preview"');

    expect(html, greaterThanOrEqualTo(0));
    expect(preview, greaterThan(html));
    expect(
      source,
      contains(
        'PreviewWebViewFactory(flutterEngine.dartExecutor.binaryMessenger)',
      ),
    );
    expect(source, contains('registerStaticRichContentRenderer'));
    expect(source, contains('"ovid/native"'));
    expect(source, contains('"ovid/voice_events"'));
  });

  test('native policy uses an isolated cookie profile and fails closed', () {
    final source = File(
      'android/app/src/main/kotlin/com/dhanuk/ovidai/PreviewWebViewFactory.kt',
    ).readAsStringSync();

    expect(source, contains('WebViewFeature.MULTI_PROFILE'));
    expect(source, contains('WebViewCompat.setProfile'));
    expect(source, contains('cookieManager'));
    expect(source, contains('setAcceptThirdPartyCookies(view, false)'));
    expect(source, contains('allowFileAccess = false'));
    expect(source, contains('allowContentAccess = false'));
    expect(source, contains('MIXED_CONTENT_NEVER_ALLOW'));
    expect(source, contains('javaScriptEnabled = false'));
    expect(source, contains('javaScriptEnabled = true'));
    expect(source, contains('shouldOverrideUrlLoading'));
    expect(source, contains('shouldInterceptRequest'));
    expect(source, contains('onPageStarted'));
    expect(source, contains('RTCPeerConnection'));
    expect(source, contains('WebTransport'));
    expect(source, contains('onCreateWindow'));
    expect(source, contains('handler.cancel()'));
    expect(source, contains('clearHistory()'));
    expect(source, contains('deleteProfile'));
    expect(source, contains('disposePreview'));
    expect(source, isNot(contains('addJavascriptInterface(')));
    expect(source, isNot(contains('proceed()')));
  });
}

String requestsText(List<http.Request> requests) => requests
    .map(
      (request) =>
          '${request.method} ${request.url} ${request.headers} ${request.body}',
    )
    .join('\n');
