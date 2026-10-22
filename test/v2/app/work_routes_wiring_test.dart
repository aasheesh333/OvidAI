import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/session_artifacts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:ovid_ai/ui/v2/app/v2_work_routes.dart';
import 'package:ovid_ai/ui/v2/library/artifacts_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_flow.dart';

/// The wiring layer is the only place that maps service rows onto the
/// presentational screens, so these tests pin the fields the screens cannot
/// invent: schedule status, artifact source/session and the add action.
Map<String, dynamic> _scheduleJson({
  String id = 's1',
  String title = 'Morning briefing',
  String status = 'pending',
}) => <String, dynamic>{
  'id': id,
  'sessionId': 'chat-1',
  'title': title,
  'description': 'Summarise the news.',
  'trigger': const {'kind': 'daily_at', 'time': '09:00', 'tz': 'UTC'},
  'autonomy': 'safe',
  'status': status,
  'maxRetries': 0,
  'nextRunAt': '2026-10-23T09:00:00.000Z',
};

ScheduleClient _client(List<Map<String, dynamic>> rows) => ScheduleClient(
  CloudRestClient(
    httpClient: MockClient(
      (request) async => http.Response(
        jsonEncode({'items': rows, 'nextCursor': null}),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
    headers: CloudHeaders.forTest(),
    restBase: 'http://test',
  ),
);

SessionArtifact _artifact({
  ArtifactOrigin origin = ArtifactOrigin.generated,
  String sessionTitle = 'Landing page redesign',
  int? size = 14540,
}) => SessionArtifact(
  id: 'artifact-1',
  name: 'portfolio-index.html',
  sessionId: 'chat-1',
  sessionTitle: sessionTitle,
  time: DateTime(2026, 10, 21, 10),
  origin: origin,
  kind: ArtifactKind.html,
  size: size,
  cloudArtifactId: 'artifact-1',
  cloudAccountId: 'firebase:uid',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CloudUsageStore usage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    usage = CloudUsageStore.acquire(AppState.I);
  });

  tearDown(() {
    usage.release();
    ScheduleClient.installForTest(ScheduleClient(CloudRestClient.I));
    AppState.resetTestInstance();
  });

  group('artifact rows', () {
    test('carry the source, size and chat title the filters need', () {
      final item = V2WorkRoutes.artifactItemFor(_artifact());

      expect(item.id, 'artifact-1');
      expect(item.name, 'portfolio-index.html');
      expect(item.kind, V2ArtifactKind.document);
      expect(item.sizeBytes, 14540);
      expect(item.sizeLabel, '14.2 KB');
      expect(item.sessionTitle, 'Landing page redesign');
      expect(item.source, V2ArtifactSource.generated);
      // No list-row mint: a signed URL exists only after an explicit tap.
      expect(item.url, isNull);
    });

    test('an uploaded row keeps the uploaded source', () {
      final item = V2WorkRoutes.artifactItemFor(
        _artifact(origin: ArtifactOrigin.uploaded, sessionTitle: ''),
      );

      expect(item.source, V2ArtifactSource.uploaded);
      expect(item.sessionTitle, isEmpty);
    });
  });

  group('schedules route', () {
    testWidgets('opens the live flow with an add action and real statuses', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      ScheduleClient.installForTest(
        _client([
          _scheduleJson(),
          _scheduleJson(id: 's2', title: 'Nightly backup', status: 'paused'),
        ]),
      );
      final actions = V2SettingsActions(usage);

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const Scaffold(body: Center(child: Text('home'))),
        ),
      );
      final context = tester.element(find.text('home'));

      final opened = V2WorkRoutes.openSchedules(context, actions);
      await tester.pumpAndSettle();

      expect(find.byType(SchedulesScreen), findsOneWidget);
      // The working flow supplies the add action the old route never did.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is OIconButton && widget.semanticLabel == 'New schedule',
        ),
        findsOneWidget,
      );
      expect(find.text('Summarise the news.'), findsNWidgets(2));

      // A pending schedule is enabled; a paused one is not.
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.map((s) => s.value), [true, false]);

      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      await opened;
    });
  });
}
