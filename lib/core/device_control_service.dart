import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'state.dart';

typedef ScreenshotCopy =
    Future<String> Function(
      String sourcePath,
      String directoryPath,
      String fileName,
    );

class ScreenshotCopyException implements Exception {
  final String code;
  final String message;

  const ScreenshotCopyException._(this.code, this.message);
  const ScreenshotCopyException.collision()
    : this._('DEST_EXISTS', 'Screenshot destination already exists.');
  const ScreenshotCopyException.write(String message)
    : this._('WRITE_FAILED', message);
  const ScreenshotCopyException.source(String message)
    : this._('SOURCE_FAILED', message);

  bool get isCollision => code == 'DEST_EXISTS';

  @override
  String toString() => message;
}

/// One-shot background-health snapshot from the native side.
class BackgroundHealth {
  final String manufacturer;
  final bool batteryExempt;

  const BackgroundHealth({
    required this.manufacturer,
    required this.batteryExempt,
  });

  /// Guidance is worthwhile only on killer-OEM ROMs lacking the exemption.
  bool get needsOemGuidance =>
      !batteryExempt &&
      DeviceControlService.isKillerOem(manufacturer);
}

class DeviceControlService {
  DeviceControlService._();

  static final DeviceControlService I = DeviceControlService._();
  static const _nativeChannel = MethodChannel('ovid/native');
  static MethodChannel? _channelOverrideForTest;
  static ScreenshotCopy? _screenshotCopyOverrideForTest;

  MethodChannel get _channel => _channelOverrideForTest ?? _nativeChannel;

  /// Cancellation contract (device-overlay spec §5.5): [DeviceControlService]
  /// carries a monotonic device generation. [beginDeviceGeneration] opens a
  /// fresh generation on every new run; [cancelDeviceActions] bumps it on
  /// every Stop (composer Stop, notification Stop, and — in Task 4 — the
  /// overlay X, which routes through the same Stop path). Every Dart
  /// `device_*` call captures the generation before the channel invoke and,
  /// when the native result lands on a stale generation, discards it and
  /// reports [cancelledSupersededMessage] instead.
  ///
  /// Android limit (documented, not worked around): an already-dispatched
  /// gesture runs to completion — cancellation covers Dart-awaited results
  /// and queued work, never recalls motion already handed to the system.
  static const String cancelledSupersededMessage =
      'cancelled: superseded by a newer run/stop';

  /// True when [result] is the superseded-generation marker (never a native
  /// payload — native results are maps/bools/paths).
  static bool isCancelledResult(Object? result) =>
      result == cancelledSupersededMessage;

  int _deviceGeneration = 0;

  /// Base of the capped exponential backoff between SERVICE_CONNECTING
  /// retries (transient accessibility re-bind window after app restart).
  /// Doubles each attempt up to [connectingRetryMaxDelayForTest]. Tests
  /// shorten these to run deterministically.
  @visibleForTesting
  static Duration connectingRetryBaseDelayForTest = const Duration(
    milliseconds: 500,
  );

  /// Ceiling for the exponential backoff above.
  @visibleForTesting
  static Duration connectingRetryMaxDelayForTest = const Duration(seconds: 5);

  /// Total time the SERVICE_CONNECTING retries may spend waiting before the
  /// call gives up. Generous on purpose: Android can take a while to rebind
  /// an enabled accessibility service after a process restart, and a manual
  /// toggle is exactly what this budget exists to avoid.
  @visibleForTesting
  static Duration connectingRetryBudgetForTest = const Duration(seconds: 90);

  @visibleForTesting
  int get deviceGenerationForTest => _deviceGeneration;

  /// Opens a fresh device generation for a newly starting run. In-flight
  /// `device_*` calls captured under the previous generation report
  /// cancellation when their native results land.
  void beginDeviceGeneration() {
    _deviceGeneration++;
  }

  /// Public Stop hook for Task 4's overlay X (and any future Stop path):
  /// invalidates every in-flight `device_*` call exactly like a composer
  /// Stop. See the [cancelledSupersededMessage] contract for the Android
  /// limit — dispatched gestures still run to completion.
  void cancelDeviceActions() {
    _deviceGeneration++;
  }

  /// Runs [invoke] under the current generation: a native result (or error)
  /// landing after a [beginDeviceGeneration]/[cancelDeviceActions] bump is
  /// replaced by [cancelledSupersededMessage]; anything else propagates
  /// untouched (errors rethrow so honest native failures still surface).
  ///
  /// One exception to immediate rethrow: [PlatformException] with code
  /// `SERVICE_CONNECTING` (accessibility service enabled in settings but
  /// not yet rebound after app restart) is retried with capped exponential
  /// backoff for up to [connectingRetryBudgetForTest] — the main thread stays
  /// free so the OS bind can actually land. A Stop/new-run generation bump
  /// during the wait still wins immediately. When the budget is exhausted the
  /// error distinguishes a still-connecting service (retry later) from one
  /// that is genuinely disabled (enable it in Settings).
  Future<Object?> _invokeGuarded(Future<Object?> Function() invoke) async {
    final generation = _deviceGeneration;
    var attempt = 0;
    var waited = Duration.zero;
    while (true) {
      try {
        final result = await invoke();
        if (generation != _deviceGeneration) return cancelledSupersededMessage;
        return result;
      } on PlatformException catch (e) {
        if (e.code == 'SERVICE_CONNECTING') {
          final delay = _connectingDelayForAttempt(attempt);
          if (waited + delay >= connectingRetryBudgetForTest) {
            final exhausted = await _connectingExhaustedError();
            if (generation != _deviceGeneration) {
              return cancelledSupersededMessage;
            }
            throw exhausted;
          }
          waited += delay;
          if (delay > Duration.zero) await Future.delayed(delay);
          attempt++;
          if (generation != _deviceGeneration) {
            return cancelledSupersededMessage;
          }
          continue;
        }
        if (generation != _deviceGeneration) return cancelledSupersededMessage;
        rethrow;
      } catch (_) {
        if (generation != _deviceGeneration) return cancelledSupersededMessage;
        rethrow;
      }
    }
  }

  Duration _connectingDelayForAttempt(int attempt) {
    final shift = attempt > 20 ? 20 : attempt;
    final baseMs = connectingRetryBaseDelayForTest.inMilliseconds;
    final maxMs = connectingRetryMaxDelayForTest.inMilliseconds;
    final scaled = baseMs * (1 << shift);
    return Duration(milliseconds: scaled > maxMs ? maxMs : scaled);
  }

  /// Budget-exhausted error. The state is re-read so a service that is
  /// genuinely disabled gets the Settings guidance while a slow rebind gets
  /// a wait/retry message — never a dead end that demands a manual toggle.
  Future<PlatformException> _connectingExhaustedError() async {
    if (await serviceState() == 'disabled') {
      return PlatformException(
        code: 'SERVICE_DISABLED',
        message:
            'Control mode needs the Ovid accessibility service. Enable it in Settings > Accessibility > Ovid.',
      );
    }
    return PlatformException(
      code: 'SERVICE_CONNECTING',
      message:
          'Ovid accessibility service is still reconnecting after the app restarted. Wait a moment and retry — it should bind on its own.',
    );
  }

  /// Three-state native accessibility status: `disabled` (off in Settings),
  /// `connecting` (enabled but not yet rebound), or `bound`. Fails closed to
  /// `disabled` when the channel is unreadable.
  Future<String> serviceState() async {
    try {
      final state = await _channel.invokeMethod<String>('deviceServiceState');
      if (state == 'bound' || state == 'connecting' || state == 'disabled') {
        return state!;
      }
    } catch (_) {}
    return 'disabled';
  }

  /// Absorbs an in-progress accessibility rebind. Intended for app-resume
  /// callers: when the state is `connecting`, waits with the same capped
  /// backoff until bound or the budget is exhausted. Non-throwing.
  Future<void> refreshServiceBinding() async {
    try {
      if (await serviceState() != 'connecting') return;
      final generation = _deviceGeneration;
      var attempt = 0;
      var waited = Duration.zero;
      while (true) {
        final delay = _connectingDelayForAttempt(attempt);
        if (waited + delay >= connectingRetryBudgetForTest) return;
        waited += delay;
        if (delay > Duration.zero) await Future.delayed(delay);
        if (generation != _deviceGeneration) return;
        if (await serviceState() != 'connecting') return;
        attempt++;
      }
    } catch (_) {}
  }

  @visibleForTesting
  static void setMethodChannelForTest(MethodChannel? channel) {
    _channelOverrideForTest = channel;
  }

  @visibleForTesting
  static void setScreenshotCopyForTest(ScreenshotCopy? copy) {
    _screenshotCopyOverrideForTest = copy;
  }

  Future<bool> isEnabled() async {
    return await _channel.invokeMethod<bool>('deviceServiceEnabled') ?? false;
  }

  Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod<bool>('deviceOpenAccessibilitySettings');
  }

  // device_read/deviceRead stays unguarded: reads are fast and the
  // pre-action verification read must reflect the live foreground app.
  Future<Map<String, dynamic>> readRaw({bool full = false}) async {
    // Routed through the guarded invoke so reads share the
    // SERVICE_CONNECTING retry behavior with every other device action.
    final result = await _invokeGuarded(
      () => _channel.invokeMapMethod<String, dynamic>(
        'deviceRead',
        {'mode': full ? 'full' : 'delta', 'full': full},
      ),
    );
    final map = result as Map<String, dynamic>?;
    return map ??
        const {'status': 'error', 'message': 'No device read result.'};
  }

  Future<String> read({bool full = false}) async {
    return formatReadResultForTest(await readRaw(full: full));
  }

  Future<Object?> tap({int? node, num? x, num? y}) => _invokeGuarded(
    () => _channel.invokeMethod<Object?>('deviceTap', {
      'node': ?node,
      'x': ?x,
      'y': ?y,
    }),
  );

  Future<Object?> type({
    int? node,
    required String text,
    bool submit = false,
  }) => _invokeGuarded(
    () => _channel.invokeMethod<Object?>('deviceType', {
      'node': ?node,
      'text': text,
      'submit': submit,
    }),
  );

  Future<Object?> swipe({
    required num fromX,
    required num fromY,
    required num toX,
    required num toY,
    int? durationMs,
  }) => _invokeGuarded(
    () => _channel.invokeMethod<Object?>('deviceSwipe', {
      'from_x': fromX,
      'from_y': fromY,
      'to_x': toX,
      'to_y': toY,
      'duration_ms': ?durationMs,
    }),
  );

  Future<Object?> systemNav(String action) => _invokeGuarded(
    () => _channel.invokeMethod<Object?>('deviceSystemNav', {'action': action}),
  );

  Future<Object?> openSettings() => _invokeGuarded(
    () => _channel.invokeMethod<Object?>('deviceOpenSettings'),
  );

  Future<Object?> openApp(String packageName, {String? sessionId}) {
    final Map<String, dynamic> args = {'package': packageName};
    if (sessionId != null) args['sessionId'] = sessionId;
    return _invokeGuarded(() => _channel.invokeMethod<Object?>('deviceOpenApp', args));
  }

  Future<Object?> key(String key) => _invokeGuarded(
    () => _channel.invokeMethod<Object?>('deviceKey', {'key': key}),
  );

  Future<Object?> longPress({int? node, num? x, num? y, int? durationMs}) {
    // Mirrors clampLongPressDuration natively (default 600, clamp 200-3000).
    final duration = (durationMs ?? 600).clamp(200, 3000);
    return _invokeGuarded(
      () => _channel.invokeMethod<Object?>('deviceLongPress', {
        'node': ?node,
        'x': ?x,
        'y': ?y,
        'duration_ms': duration,
      }),
    );
  }

  Future<Object?> scroll({int? node, required String direction}) =>
      _invokeGuarded(
        () => _channel.invokeMethod<Object?>('deviceScroll', {
          'node': ?node,
          'direction': direction,
        }),
      );

  Future<String> screenshot() async {
    // Screenshot is a mutating-cancellable action result like the rest.
    final result = await _invokeGuarded(
      () => _channel.invokeMethod<Object?>('deviceScreenshot'),
    );
    if (result is String) return result;
    return result?.toString() ?? '';
  }

  Future<String> copyScreenshotIntoWorkspace(
    String sourcePath,
    Directory workspace,
  ) async {
    await workspace.create(recursive: true);
    final canonicalWorkspace = await workspace.resolveSymbolicLinks();
    final captures = Directory('$canonicalWorkspace/device-screenshots');
    if (await FileSystemEntity.type(captures.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const ScreenshotCopyException.write(
        'unsafe workspace path: device-screenshots is a symlink.',
      );
    }
    await captures.create();
    final canonicalCaptures = await captures.resolveSymbolicLinks();
    if (!_isContained(canonicalWorkspace, canonicalCaptures)) {
      throw const ScreenshotCopyException.write(
        'unsafe workspace path: screenshot directory escapes the workspace.',
      );
    }

    final copy = _screenshotCopyOverrideForTest ?? _copyScreenshotNative;
    for (var attempt = 0; attempt < 4; attempt++) {
      final name =
          'screen-${DateTime.now().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}.png';
      final destination = File('$canonicalCaptures/$name');
      try {
        final copied = await copy(sourcePath, canonicalCaptures, name);
        final canonicalCopied = await File(copied).resolveSymbolicLinks();
        if (!_isContained(canonicalCaptures, canonicalCopied)) {
          throw const ScreenshotCopyException.write(
            'unsafe workspace path: copied screenshot escapes the workspace.',
          );
        }
        return canonicalCopied;
      } on ScreenshotCopyException catch (error) {
        if (error.isCollision) {
          if (attempt < 3) continue;
          rethrow;
        }
        if (error.code == 'WRITE_FAILED') await _deletePartial(destination);
        rethrow;
      } on PlatformException catch (error) {
        if (error.code == 'DEST_EXISTS') {
          if (attempt < 3) continue;
          throw ScreenshotCopyException._(
            error.code,
            error.message ?? 'Screenshot destination already exists.',
          );
        }
        throw ScreenshotCopyException._(
          error.code,
          error.message ?? 'Screenshot copy failed.',
        );
      } catch (_) {
        rethrow;
      }
    }
    throw const ScreenshotCopyException.collision();
  }

  Future<String> _copyScreenshotNative(
    String sourcePath,
    String directoryPath,
    String fileName,
  ) async {
    return await _channel.invokeMethod<String>('deviceCopyScreenshot', {
          'sourcePath': sourcePath,
          'directoryPath': directoryPath,
          'fileName': fileName,
        }) ??
        (throw const ScreenshotCopyException.write(
          'Native screenshot copy returned no path.',
        ));
  }

  static bool _isContained(String parent, String child) =>
      child == parent || child.startsWith('$parent/');

  static Future<void> _deletePartial(File file) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await file.delete();
      }
    } catch (_) {}
  }

  @visibleForTesting
  Future<String> copyScreenshotIntoWorkspaceForTest(
    String sourcePath,
    Directory workspace,
  ) => copyScreenshotIntoWorkspace(sourcePath, workspace);

  static String formatReadResultForTest(Map<String, dynamic> result) {
    final status = result['status']?.toString() ?? 'error';
    if (status == 'unchanged') return 'screen unchanged';
    if (status != 'ok') {
      final message = result['message']?.toString().trim() ?? '';
      return message.isEmpty
          ? 'device read $status'
          : 'device read $status: $message';
    }

    final full = result['full'] == true;
    final packageName = result['package']?.toString().trim() ?? '';
    final added = _rows(result['added']);
    final changed = _rows(result['changed']);
    final removed = (result['removed'] as List? ?? const [])
        .map((value) => (value as num?)?.toInt())
        .whereType<int>()
        .toList();
    final out = StringBuffer();
    if (packageName.isNotEmpty) out.writeln('package: $packageName');
    for (final row in added) {
      out.writeln(
        '${full ? '' : '+ '}${_formatNode(row, packageName: packageName)}',
      );
    }
    for (final row in changed) {
      out.writeln('~ ${_formatNode(row, packageName: packageName)}');
    }
    for (final handle in removed) {
      out.writeln('- [$handle]');
    }
    if (added.isEmpty && changed.isEmpty && removed.isEmpty) {
      out.writeln(
        'Screen exposes no readable structure. Use device_screenshot if the current model supports images.',
      );
    }
    return out.toString().trimRight();
  }

  static List<Map<String, dynamic>> _rows(Object? raw) => [
    for (final row in raw as List? ?? const [])
      if (row is Map) Map<String, dynamic>.from(row),
  ];

  static String _formatNode(Map<String, dynamic> row, {String packageName = ''}) {
    final handle = (row['handle'] as num?)?.toInt() ?? 0;
    final className = row['class']?.toString().trim() ?? '';
    final text = row['text']?.toString().trim() ?? '';
    final description = row['description']?.toString().trim() ?? '';
    final viewId = row['viewId']?.toString().trim() ?? '';
    final bounds = (row['bounds'] as List? ?? const [])
        .map((value) => value.toString())
        .join(',');
    final flags = <String>[
      for (final name in const [
        'clickable',
        'editable',
        'scrollable',
        'password',
        'checked',
        'focused',
      ])
        if (row[name] == true) name,
    ];
    final role = iconRoleForTest(
      packageName: packageName,
      className: className,
      text: text,
      description: description,
      viewId: viewId,
    );
    return [
      '[$handle]',
      if (className.isNotEmpty) className,
      if (text.isNotEmpty) '"${text.replaceAll('"', r'\"')}"',
      if (description.isNotEmpty)
        'desc="${description.replaceAll('"', r'\"')}"',
      if (viewId.isNotEmpty) 'id=$viewId',
      if (role != null) 'icon="$role"',
      if (bounds.isNotEmpty) 'bounds=($bounds)',
      ...flags,
    ].join(' ');
  }

  /// Icon role for a graphic widget, or null when nothing can be inferred.
  /// Only image widgets get roles (a TextView saying "Search results" is
  /// not a search icon). Package-scoped entries win over generic ones so
  /// the same keyword can mean different things in different apps. The
  /// table is data (extend without touching matching logic).
  @visibleForTesting
  static String? iconRoleForTest({
    required String packageName,
    required String className,
    required String text,
    required String description,
    required String viewId,
  }) {
    final cls = className.toLowerCase();
    if (!cls.contains('imagebutton') && !cls.contains('imageview')) {
      return null;
    }
    final haystack =
        '$cls ${text.toLowerCase()} ${description.toLowerCase()} ${viewId.toLowerCase()}';
    final pkg = packageName.trim().toLowerCase();
    for (final entry in _iconRoles) {
      if (entry.$1.isNotEmpty && entry.$1 != pkg) continue;
      if (haystack.contains(entry.$2)) return entry.$3;
    }
    return null;
  }

  /// (package scope, keyword, label). Package-scoped rows come first so
  /// they win over the generic fallbacks below.
  static const _iconRoles = [
    // Per-app refinements.
    ('com.instagram.android', 'direct', 'direct inbox'),
    ('com.instagram.android', 'reels', 'reels'),
    ('com.instagram.android', 'your_story', 'your story'),
    ('com.whatsapp', 'status', 'status tab'),
    ('com.whatsapp', 'chats', 'chats tab'),
    ('com.whatsapp', 'calls', 'calls tab'),
    ('com.google.android.youtube', 'shorts', 'shorts'),
    ('com.google.android.youtube', 'library', 'library'),
    ('com.android.chrome', 'tab_switcher', 'open tabs'),
    ('com.android.settings', 'wifi', 'wi-fi'),
    ('com.android.settings', 'bluetooth', 'bluetooth'),
    ('com.android.settings', 'apps', 'apps list'),
    // Generic fallbacks (any app).
    ('', 'navigate_up', 'back button'),
    ('', 'arrow_back', 'back button'),
    ('', 'more_vert', 'more options'),
    ('', 'morevert', 'more options'),
    ('', 'overflow', 'more options'),
    ('', 'paper_plane', 'send'),
    ('', 'bookmark', 'save'),
    ('', 'videocam', 'video'),
    ('', 'navigate', 'back button'),
    ('', 'share', 'share'),
    ('', 'search', 'search'),
    ('', 'settings', 'settings'),
    ('', 'gear', 'settings'),
    ('', 'send', 'send'),
    ('', 'back', 'back button'),
    ('', 'close', 'close'),
    ('', 'clear', 'close'),
    ('', 'play', 'play'),
    ('', 'pause', 'pause'),
    ('', 'mic', 'mic'),
    ('', 'camera', 'camera'),
    ('', 'phone', 'call'),
    ('', 'call', 'call'),
    ('', 'video', 'video'),
    ('', 'message', 'message'),
    ('', 'comment', 'comment'),
    ('', 'heart', 'like button'),
    ('', 'favorite', 'like button'),
    ('', 'like', 'like button'),
    ('', 'home', 'home'),
    ('', 'bell', 'notifications'),
    ('', 'notification', 'notifications'),
    ('', 'person', 'profile'),
    ('', 'profile', 'profile'),
    ('', 'account', 'profile'),
    ('', 'avatar', 'profile'),
    ('', 'pencil', 'edit'),
    ('', 'compose', 'edit'),
    ('', 'edit', 'edit'),
    ('', 'trash', 'delete'),
    ('', 'delete', 'delete'),
    ('', 'plus', 'add'),
    ('', 'add', 'add'),
    ('', 'check', 'done'),
    ('', 'done', 'done'),
    ('', 'tick', 'done'),
    ('', 'refresh', 'refresh'),
    ('', 'sync', 'refresh'),
    ('', 'download', 'download'),
    ('', 'upload', 'upload'),
    ('', 'star', 'save'),
    ('', 'save', 'save'),
    ('', 'location', 'location'),
    ('', 'pin', 'location'),
    ('', 'map', 'location'),
    ('', 'calendar', 'calendar'),
    ('', 'clock', 'clock'),
    ('', 'time', 'clock'),
    ('', 'schedule', 'clock'),
    ('', 'volume', 'volume'),
    ('', 'lock', 'lock'),
    ('', 'grid', 'app drawer'),
    ('', 'apps', 'app drawer'),
    ('', 'drawer', 'app drawer'),
    ('', 'list', 'list'),
    ('', 'filter', 'sort'),
    ('', 'sort', 'sort'),
    ('', 'info', 'help'),
    ('', 'help', 'help'),
    ('', 'logout', 'logout'),
    ('', 'exit', 'logout'),
    ('', 'story', 'story'),
    ('', 'reel', 'reels'),
    ('', 'fullscreen', 'fullscreen'),
    ('', 'expand', 'fullscreen'),
  ];

  @visibleForTesting
  static bool isSensitiveTargetForTest({String? packageName, String? url}) {
    return isSensitiveTarget(packageName: packageName, url: url);
  }

  @visibleForTesting
  static bool isKillerOemForTest(String manufacturer) =>
      isKillerOem(manufacturer);

  /// True for OEM ROMs known to force-kill background apps even with a
  /// foreground service (autostart whitelists, task killers). Used to show
  /// background-health guidance only where it matters — Pixel-class ROMs
  /// never see the nag.
  static bool isKillerOem(String manufacturer) {
    final m = manufacturer.trim().toLowerCase();
    if (m.isEmpty) return false;
    const killers = [
      'xiaomi',
      'redmi',
      'poco',
      'oppo',
      'realme',
      'oneplus',
      'vivo',
      'iqoo',
      'huawei',
      'honor',
      'samsung',
      'asus',
      'infinix',
      'tecno',
    ];
    return killers.any((k) => m == k || m.startsWith('$k ') || m.contains(' $k'));
  }

  /// One-shot background-health snapshot: device manufacturer plus whether
  /// the OS battery-optimization exemption is granted. Pure check — never
  /// opens system UI (that is `requestBatteryExemption`'s job).
  Future<BackgroundHealth> backgroundHealth() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'getBackgroundHealth',
      );
      return BackgroundHealth(
        manufacturer: m?['manufacturer']?.toString() ?? '',
        batteryExempt: m?['batteryExempt'] == true,
      );
    } catch (_) {
      // Fail closed toward silence: an unreadable state must not nag.
      return const BackgroundHealth(manufacturer: '', batteryExempt: true);
    }
  }

  static bool isSensitiveTarget({String? packageName, String? url}) {
    final package = packageName?.trim().toLowerCase() ?? '';
    if (kDeniedControlPackages.any(
      (denied) => package == denied || package.startsWith('$denied:'),
    )) {
      return true;
    }
    final host = Uri.tryParse(url?.trim() ?? '')?.host.toLowerCase() ?? '';
    return kDeniedControlDomains.any(
      (denied) => host == denied || host.endsWith('.$denied'),
    );
  }
}
