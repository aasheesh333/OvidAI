import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SecurityService {
  SecurityService._();

  static final SecurityService I = SecurityService._();
  static const _nativeChannel = MethodChannel('ovid/native');
  static MethodChannel? _channelOverrideForTest;

  MethodChannel get _channel => _channelOverrideForTest ?? _nativeChannel;

  Map<String, dynamic> _status = const {};

  bool get isRooted => _status['isRooted'] == true;
  bool get isDebuggerAttached => _status['isDebuggerAttached'] == true;
  bool get isHookingFrameworkPresent =>
      _status['isHookingFrameworkPresent'] == true;

  @visibleForTesting
  static void setMethodChannelForTest(MethodChannel? channel) {
    _channelOverrideForTest = channel;
  }

  Future<Map<String, dynamic>> status() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getSecurityStatus',
      );
      return result ?? const {};
    } catch (_) {
      return const {};
    }
  }

  Future<Map<String, dynamic>> refresh() async {
    _status = await status();
    return _status;
  }

  Future<bool> setSecureScreen(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setSecureScreen', {'enabled': enabled});
      return true;
    } catch (_) {
      return false;
    }
  }
}
