// The platform interface is a transitive dependency of firebase_core; the
// boot matrix swaps it for a fake so the real app boots deterministically.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/main.dart' as app;
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/app/v2_onboarding_gate.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';

/// Device shapes the app must boot on. The narrow phone is the one that
/// breaks layouts: 320 dp with 200 % text is the worst realistic case.
const List<_Shape> _shapes = <_Shape>[
  _Shape('small phone 320x568', Size(320, 568)),
  _Shape('phone 360x640', Size(360, 640)),
  _Shape('phone 412x915', Size(412, 915)),
  _Shape('tablet 600x960', Size(600, 960)),
  _Shape('tablet 800x1280', Size(800, 1280)),
  _Shape('landscape tablet 1024x768', Size(1024, 768)),
  _Shape('desktop 1280x800', Size(1280, 800)),
];

const List<double> _scales = <double>[1, 2];
const List<Brightness> _brightnesses = <Brightness>[
  Brightness.light,
  Brightness.dark,
];

class _Shape {
  const _Shape(this.name, this.size);

  final String name;
  final Size size;
}

/// One row of the matrix.
class _Case {
  const _Case(this.shape, this.scale, this.brightness);

  final _Shape shape;
  final double scale;
  final Brightness brightness;

  String get label => '${shape.name} · ${scale}x · ${brightness.name}';
}

Iterable<_Case> get _cases sync* {
  for (final shape in _shapes) {
    for (final scale in _scales) {
      for (final brightness in _brightnesses) {
        yield _Case(shape, scale, brightness);
      }
    }
  }
}

/// Firebase is not configured in widget tests; without a fake its platform
/// channel never answers, which is exactly the "app looks frozen" failure this
/// file exists to catch. The fake makes the platform fail fast so the real
/// [app.OvidApp] reaches its recoverable startup-error screen.
class _UnavailableFirebase extends FirebasePlatform {
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    throw FirebaseException(
      plugin: 'core',
      code: 'unavailable',
      message: 'Firebase is not configured in widget tests.',
    );
  }
}

class _OnboardingAuth extends ChangeNotifier implements V2OnboardingAuth {
  _OnboardingAuth({this.signedIn = false});

  bool signedIn;

  @override
  bool get isAvailable => true;

  @override
  bool get isSignedIn => signedIn;

  @override
  bool get accountReady => signedIn;

  @override
  String? get accountError => null;

  @override
  bool get accountTransitionFailed => false;

  @override
  String get accountLabel => 'Test account';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> retryAccountLogin() async {}

  @override
  Future<void> signOut() async {
    signedIn = false;
    notifyListeners();
  }

  @override
  Future<String?> authenticateSocial(
    String providerId,
    AuthIntent intent,
  ) async {
    signedIn = true;
    notifyListeners();
    return null;
  }

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) =>
      throw UnimplementedError('phone auth is not exercised here');
}

/// First run: the tour has not been completed yet.
class _FirstRunStore extends V2OnboardingStore {
  @override
  Future<V2OnboardingSnapshot> load({required String welcomeVersion}) async =>
      const V2OnboardingSnapshot(welcomeSeen: false);

  @override
  Future<void> markWelcomeSeen(String version) async {}
}

class _ShellRest extends CloudRestClient {
  _ShellRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async => const SendMessageResponse(
    runId: 'run-1',
    userMessageId: 'msg-1',
    status: 'queued',
  );
}

class _ShellFacade extends CloudAgentFacade {
  _ShellFacade({required super.rest, required super.ws}) : super(store: null);
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _defineRealAppBootMatrix();
  _defineOnboardingMatrix();
  _defineShellMatrix();
}

// ── 1. The real app boots and paints ────────────────────────────────────────

void _defineRealAppBootMatrix() {
  group('real OvidApp boots and paints', () {
    late FirebasePlatform previousPlatform;

    setUp(() {
      // Let the lock state resolve: a hung SharedPreferences read is covered by
      // the dedicated app_lock tests, not by every matrix row.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      previousPlatform = FirebasePlatform.instance;
      FirebasePlatform.instance = _UnavailableFirebase();
    });

    tearDown(() {
      FirebasePlatform.instance = previousPlatform;
    });

    for (final testCase in _cases) {
      testWidgets(testCase.label, (tester) async {
        _applyDevice(tester, testCase);
        await tester.pumpWidget(const app.OvidApp());
        await _expectFrames(tester, testCase.label);

        expect(
          AppLock.I.loaded,
          isTrue,
          reason: '${testCase.label}: the lock gate must stop blocking',
        );
        _expectPaintedSurface(tester, testCase.label);
        // With Firebase unavailable the app must reach a recoverable screen
        // with a real retry, never a frozen "Starting…" splash.
        expect(
          find.byKey(const Key('splash-retry')).hitTestable(),
          findsOneWidget,
          reason: '${testCase.label}: startup never became recoverable',
        );
        _expectBrightness(tester, testCase);
      });
    }
  });
}

// ── 2. Onboarding is interactive once the lock resolves ─────────────────────

void _defineOnboardingMatrix() {
  group('onboarding is interactive after boot', () {
    for (final testCase in _cases) {
      testWidgets(testCase.label, (tester) async {
        _applyDevice(tester, testCase);
        final auth = _OnboardingAuth();
        addTearDown(auth.dispose);

        await tester.pumpWidget(
          _host(
            testCase,
            V2OnboardingGate(
              auth: auth,
              store: _FirstRunStore(),
              child: const SizedBox.shrink(),
            ),
          ),
        );
        await _expectFrames(tester, testCase.label);
        _expectPaintedSurface(tester, testCase.label);

        // The primary action is pinned to the bottom edge: if it is off-screen
        // at 320 dp / 200 % text this fails instead of shipping a dead end.
        final cta = find.byKey(const Key('welcome-get-started'));
        expect(cta, findsOneWidget, reason: '${testCase.label}: no CTA');
        expect(
          cta.hitTestable(),
          findsOneWidget,
          reason: '${testCase.label}: "Get started" is not on screen',
        );

        await tester.tap(cta);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const Key('language-goal-continue')),
          findsOneWidget,
          reason: '${testCase.label}: onboarding did not advance',
        );
      });
    }
  });
}

// ── 3. The signed-in shell paints on every shape ────────────────────────────

void _defineShellMatrix() {
  group('signed-in shell paints', () {
    late AppState appState;
    late WsMultiplexer ws;
    late _ShellFacade facade;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AppState.resetTestInstance();
      appState = AppState.createForTest();
      ws = WsMultiplexer(
        mintTicket: () async => 'ticket',
        socketFactory: (_) async =>
            throw StateError('the device matrix opens no socket'),
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
        jitterMs: () => 0,
      );
      facade = _ShellFacade(rest: _ShellRest(), ws: ws);
      CloudAgentFacade.installForTest(facade);
      ProjectsController.installForTest(_SilentProjects());
      StudioBindingPort.installForTest(null);
      ChatPinsStore.I.clearForTest();
      ComposerDraftStore.I.resetForTest();
      LoginGate.disabledForTest = true;
      _seedSession(appState);
    });

    tearDown(() async {
      LoginGate.disabledForTest = false;
      await ws.disconnect();
      facade.dispose();
      CloudAgentFacade.resetForTest();
      ProjectsController.resetForTest();
      StudioBindingPort.installForTest(null);
      ChatPinsStore.I.clearForTest();
      ComposerDraftStore.I.resetForTest();
      AppState.resetTestInstance();
      v2SessionRefResolver = null;
    });

    for (final testCase in _cases) {
      testWidgets(testCase.label, (tester) async {
        _applyDevice(tester, testCase);
        final auth = _OnboardingAuth(signedIn: true);
        addTearDown(auth.dispose);

        await tester.pumpWidget(
          _host(
            testCase,
            V2OnboardingGate(
              auth: auth,
              store: _FirstRunStore(),
              child: const LoginGate(child: V2AppShell()),
            ),
          ),
        );
        await _expectFrames(tester, testCase.label);
        _expectPaintedSurface(tester, testCase.label);
        _expectTappable(tester, testCase.label);
      });
    }
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────────

void _seedSession(AppState state) {
  final session = ChatSession(
    id: 'device-matrix',
    title: 'Device matrix',
    model: 'auto',
    createdAt: DateTime(2026, 10, 22, 9),
  );
  session.messages.add(
    Message(
      role: 'user',
      content: 'Does the app paint on this screen?',
      time: DateTime(2026, 10, 22, 9),
    ),
  );
  state.sessions.add(session);
  state.activeSessionId = session.id;
}

Widget _host(_Case testCase, Widget home) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: OTheme.light(),
    darkTheme: OTheme.dark(),
    themeMode: testCase.brightness == Brightness.dark
        ? ThemeMode.dark
        : ThemeMode.light,
    home: home,
  );
}

void _applyDevice(WidgetTester tester, _Case testCase) {
  tester.view.physicalSize = testCase.shape.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = testCase.scale;
  tester.platformDispatcher.platformBrightnessTestValue = testCase.brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

/// 50 frames is long enough for the first route, the lock gate and the
/// startup state machine to settle, and short enough to keep the matrix fast.
Future<void> _expectFrames(WidgetTester tester, String label) async {
  for (var frame = 0; frame < 50; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.takeException(),
      isNull,
      reason: '$label: exception on frame $frame',
    );
  }
}

/// A blank surface is indistinguishable from a frozen app. Require a Scaffold
/// that actually paints a non-empty, non-zero-sized Text.
void _expectPaintedSurface(WidgetTester tester, String label) {
  final scaffolds = find.byType(Scaffold);
  expect(scaffolds, findsWidgets, reason: '$label: no Scaffold painted');

  final scaffold = scaffolds.first;
  final scaffoldSize = tester.getSize(scaffold);
  expect(
    scaffoldSize.width,
    greaterThan(0),
    reason: '$label: Scaffold has no width',
  );
  expect(
    scaffoldSize.height,
    greaterThan(0),
    reason: '$label: Scaffold has no height',
  );

  final texts = find.descendant(of: scaffold, matching: find.byType(Text));
  expect(texts, findsWidgets, reason: '$label: Scaffold painted no Text');

  final painted = texts.evaluate().where((element) {
    final render = element.renderObject;
    if (render is! RenderBox || !render.hasSize || render.size.isEmpty) {
      return false;
    }
    final data = (element.widget as Text).data;
    return data != null && data.trim().isNotEmpty;
  });
  expect(
    painted,
    isNotEmpty,
    reason: '$label: every Text was empty or zero-sized',
  );
}

Finder _tappables() => find
    .byWidgetPredicate(
      (widget) =>
          (widget is ButtonStyleButton && widget.enabled) ||
          (widget is IconButton && widget.onPressed != null) ||
          (widget is InkWell && widget.onTap != null),
    )
    .hitTestable();

void _expectTappable(WidgetTester tester, String label) {
  expect(
    _tappables(),
    findsWidgets,
    reason: '$label: nothing tappable is on screen',
  );
}

void _expectBrightness(WidgetTester tester, _Case testCase) {
  final context = tester.element(find.byType(Scaffold).first);
  expect(
    Theme.of(context).brightness,
    testCase.brightness,
    reason: '${testCase.label}: wrong theme brightness',
  );
}
