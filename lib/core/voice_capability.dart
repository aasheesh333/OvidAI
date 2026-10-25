import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Real audio remains gated until the Task 13 device acceptance is recorded.
const bool kOvidVoiceEnabled = false;
const String kOvidVoiceUnavailableMessage =
    'On-device voice is not available in this release.';

@immutable
class VoiceLocaleSupport {
  const VoiceLocaleSupport({required this.stt, required this.tts});

  final bool stt;
  final bool tts;
}

@immutable
class VoiceAvailability {
  VoiceAvailability({
    required this.enabled,
    required this.stt,
    required this.tts,
    Map<String, VoiceLocaleSupport> locales = const {},
    this.reason,
  }) : locales = UnmodifiableMapView(locales);

  /// Whether at least one voice capability is enabled for this release.
  final bool enabled;
  final bool stt;
  final bool tts;
  final Map<String, VoiceLocaleSupport> locales;
  final String? reason;

  bool supportsStt(String localeId) => _locale(localeId)?.stt ?? false;

  bool supportsTts(String localeId) => _locale(localeId)?.tts ?? false;

  VoiceLocaleSupport? _locale(String localeId) {
    final wanted = localeId.trim().replaceAll('_', '-').toLowerCase();
    for (final entry in locales.entries) {
      if (entry.key.replaceAll('_', '-').toLowerCase() == wanted) {
        return entry.value;
      }
    }
    return null;
  }
}

/// One native event stream shared by STT and TTS, kept off `ovid/native` so
/// installing voice callbacks cannot replace the app's route-call handler.
abstract final class VoiceNativeEvents {
  static final Stream<Map<String, Object?>> shared =
      const EventChannel('ovid/voice_events')
          .receiveBroadcastStream()
          .where((event) => event is Map)
          .map((event) => Map<String, Object?>.from(event as Map))
          .asBroadcastStream();
}

class VoiceCapability {
  VoiceCapability({
    MethodChannel? channel,
    this.releaseEnabled = kOvidVoiceEnabled,
  }) : _channel = channel ?? const MethodChannel('ovid/native');

  static const requestedLocales = <String>['en-IN', 'hi-IN', 'pa-IN', 'ta-IN'];

  final MethodChannel _channel;
  final bool releaseEnabled;

  /// Reports actual on-device support. STT locales are downloaded on-device
  /// locales only; TTS locales have an installed voice that needs no network.
  Future<VoiceAvailability> probe() async {
    Map<Object?, Object?> raw;
    try {
      final answer = await _channel.invokeMethod<Map<Object?, Object?>>(
        'voiceCapability',
        <String, Object?>{'locales': requestedLocales},
      );
      raw = answer ?? const {};
    } catch (_) {
      raw = const {};
    }

    final stt = raw['stt'] == true;
    final tts = raw['tts'] == true;
    final locales = <String, VoiceLocaleSupport>{};
    final rawLocales = raw['locales'];
    if (rawLocales is Map) {
      for (final entry in rawLocales.entries) {
        final id = entry.key;
        final support = entry.value;
        if (id is! String || support is! Map) continue;
        locales[id] = VoiceLocaleSupport(
          stt: support['stt'] == true,
          tts: support['tts'] == true,
        );
      }
    }

    final nativeReason = raw['reason'];
    return VoiceAvailability(
      enabled: releaseEnabled && (stt || tts),
      stt: stt,
      tts: tts,
      locales: locales,
      reason: !releaseEnabled
          ? kOvidVoiceUnavailableMessage
          : !stt && !tts
          ? nativeReason is String && nativeReason.trim().isNotEmpty
                ? nativeReason.trim()
                : kOvidVoiceUnavailableMessage
          : null,
    );
  }
}
