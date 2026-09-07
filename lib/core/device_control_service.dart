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

class DeviceControlService {
  DeviceControlService._();

  static final DeviceControlService I = DeviceControlService._();
  static const _nativeChannel = MethodChannel('ovid/native');
  static MethodChannel? _channelOverrideForTest;
  static ScreenshotCopy? _screenshotCopyOverrideForTest;

  MethodChannel get _channel => _channelOverrideForTest ?? _nativeChannel;

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

  Future<Map<String, dynamic>> readRaw({bool full = false}) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'deviceRead',
      {'mode': full ? 'full' : 'delta', 'full': full},
    );
    return result ??
        const {'status': 'error', 'message': 'No device read result.'};
  }

  Future<String> read({bool full = false}) async {
    return formatReadResultForTest(await readRaw(full: full));
  }

  Future<Object?> tap({int? node, num? x, num? y}) => _channel
      .invokeMethod<Object?>('deviceTap', {'node': ?node, 'x': ?x, 'y': ?y});

  Future<Object?> type({
    int? node,
    required String text,
    bool submit = false,
  }) => _channel.invokeMethod<Object?>('deviceType', {
    'node': ?node,
    'text': text,
    'submit': submit,
  });

  Future<Object?> swipe({
    required num fromX,
    required num fromY,
    required num toX,
    required num toY,
    int? durationMs,
  }) => _channel.invokeMethod<Object?>('deviceSwipe', {
    'from_x': fromX,
    'from_y': fromY,
    'to_x': toX,
    'to_y': toY,
    'duration_ms': ?durationMs,
  });

  Future<Object?> systemNav(String action) =>
      _channel.invokeMethod<Object?>('deviceSystemNav', {'action': action});

  Future<String> screenshot() async {
    return await _channel.invokeMethod<String>('deviceScreenshot') ?? '';
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
      out.writeln('${full ? '' : '+ '}${_formatNode(row)}');
    }
    for (final row in changed) {
      out.writeln('~ ${_formatNode(row)}');
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

  static String _formatNode(Map<String, dynamic> row) {
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
    return [
      '[$handle]',
      if (className.isNotEmpty) className,
      if (text.isNotEmpty) '"${text.replaceAll('"', r'\"')}"',
      if (description.isNotEmpty)
        'desc="${description.replaceAll('"', r'\"')}"',
      if (viewId.isNotEmpty) 'id=$viewId',
      if (bounds.isNotEmpty) 'bounds=($bounds)',
      ...flags,
    ].join(' ');
  }

  @visibleForTesting
  static bool isSensitiveTargetForTest({String? packageName, String? url}) {
    return isSensitiveTarget(packageName: packageName, url: url);
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
