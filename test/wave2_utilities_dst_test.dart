import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';

// The production device-local path resolves the *actual runtime* timezone
// through DateTime.toLocal(), and the DST expectations below are
// America/New_York wall times. To keep this suite deterministic on any host,
// main() pins the process C timezone (setenv/tzset via libc, which the Dart
// VM consults on every toLocal call, including in the bounded worker isolate
// that runs the cron scan) and restores the host timezone afterwards.
// Platform.environment is a VM-startup snapshot and cannot observe the pin,
// so readiness is guarded by an effective-zone probe instead. On hosts where
// the pin or the zoneinfo database is unavailable, the tests skip with a
// reason instead of failing.

typedef _SetenvNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32);
typedef _UnsetenvNative = Int32 Function(Pointer<Uint8>);
typedef _GetenvNative = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _TzsetNative = Void Function();

/// Minimal libc TZ control; avoids a package:ffi dependency for native
/// string marshalling.
class _LibcTz {
  _LibcTz._(DynamicLibrary lib)
    : _malloc = lib
          .lookupFunction<_MallocNative, Pointer<Uint8> Function(int)>(
            'malloc',
          ),
      _free = lib.lookupFunction<_FreeNative, void Function(Pointer<Uint8>)>(
        'free',
      ),
      _getenv = lib
          .lookupFunction<_GetenvNative, Pointer<Uint8> Function(Pointer<Uint8>)>(
            'getenv',
          ),
      _setenv = lib
          .lookupFunction<
            _SetenvNative,
            int Function(Pointer<Uint8>, Pointer<Uint8>, int)
          >('setenv'),
      _unsetenv = lib
          .lookupFunction<_UnsetenvNative, int Function(Pointer<Uint8>)>(
            'unsetenv',
          ),
      _tzset = lib.lookupFunction<_TzsetNative, void Function()>('tzset');

  static _LibcTz? tryOpen() {
    try {
      if (Platform.isLinux) {
        return _LibcTz._(DynamicLibrary.open('libc.so.6'));
      }
      if (Platform.isMacOS) {
        return _LibcTz._(DynamicLibrary.open('libSystem.B.dylib'));
      }
    } catch (_) {
      // Fall through: libc unavailable.
    }
    return null;
  }

  final Pointer<Uint8> Function(int) _malloc;
  final void Function(Pointer<Uint8>) _free;
  final Pointer<Uint8> Function(Pointer<Uint8>) _getenv;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int) _setenv;
  final int Function(Pointer<Uint8>) _unsetenv;
  final void Function() _tzset;

  Pointer<Uint8> _native(String value) {
    final bytes = utf8.encode(value);
    final ptr = _malloc(bytes.length + 1);
    if (ptr.address == 0) {
      throw StateError('libc malloc failed.');
    }
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return ptr;
  }

  String? read(String name) {
    final key = _native(name);
    try {
      final value = _getenv(key);
      if (value.address == 0) {
        return null;
      }
      var length = 0;
      while (value[length] != 0) {
        length++;
      }
      return utf8.decode(value.asTypedList(length));
    } finally {
      _free(key);
    }
  }

  /// setenv copies both strings, so the marshalled buffers are freed here.
  void write(String name, String? value) {
    final key = _native(name);
    Pointer<Uint8>? raw;
    try {
      if (value == null) {
        _unsetenv(key);
      } else {
        raw = _native(value);
        _setenv(key, raw, 1);
      }
    } finally {
      _free(key);
      if (raw != null) {
        _free(raw);
      }
    }
    _tzset();
  }
}

String? _previousTz;

String? _pinNewYork(_LibcTz tz) {
  try {
    _previousTz = tz.read('TZ');
    tz.write('TZ', 'America/New_York');
    // Probe an instant that lands on 03:30 local only in America/New_York
    // (spring-forward day, UTC-4); catches a missing zoneinfo database.
    final wall = DateTime.parse('2026-03-08T07:30:00Z').toLocal();
    if (wall.hour != 3 || wall.minute != 30) {
      tz.write('TZ', _previousTz);
      return 'America/New_York zoneinfo is unavailable on this host.';
    }
    return null;
  } catch (_) {
    return 'This host cannot pin TZ=America/New_York through libc.';
  }
}

void _restore(_LibcTz tz) {
  try {
    tz.write('TZ', _previousTz);
  } catch (_) {
    // Best effort; the test process exits with the suite.
  }
}

void main() {
  final tz = _LibcTz.tryOpen();
  final skipReason = tz == null
      ? 'device-local DST coverage requires libc TZ pinning (Linux/macOS).'
      : _pinNewYork(tz);
  if (tz != null && skipReason == null) {
    tearDownAll(() => _restore(tz));
  }

  test('device-local skips spring gap', () async {
    final result = jsonDecode(
      await CronDesignerCapability().callTool('next_runs', {
        'expression': '30 2 * * *',
        'start_time': '2026-03-08T00:00:00Z',
        'timezone': 'device-local',
        'count': 1,
        'horizon_days': 3,
      }),
    );
    expect(result['runs'], ['2026-03-09T06:30:00.000Z']);
  }, skip: skipReason);
  test('device-local repeats autumn fold as two distinct instants', () async {
    final result = jsonDecode(
      await CronDesignerCapability().callTool('next_runs', {
        'expression': '30 1 * * *',
        'start_time': '2026-11-01T00:00:00Z',
        'timezone': 'device-local',
        'count': 2,
        'horizon_days': 2,
      }),
    );
    expect(result['runs'], [
      '2026-11-01T05:30:00.000Z',
      '2026-11-01T06:30:00.000Z',
    ]);
  }, skip: skipReason);
}
