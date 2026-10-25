import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'diag.dart';
import 'voice_capability.dart';

@immutable
class VoiceUtteranceAcceptance {
  const VoiceUtteranceAcceptance({
    required this.utteranceId,
    required this.localeId,
  });

  final String utteranceId;
  final String localeId;
}

enum VoiceUtteranceEventType {
  started,
  progress,
  paused,
  completed,
  stopped,
  error,
}

@immutable
class VoiceUtteranceEvent {
  const VoiceUtteranceEvent._(
    this.utteranceId,
    this.type, {
    this.start = 0,
    this.end = 0,
  });

  const VoiceUtteranceEvent.start(String utteranceId)
    : this._(utteranceId, VoiceUtteranceEventType.started);
  const VoiceUtteranceEvent.progress(
    String utteranceId, {
    required int start,
    required int end,
  }) : this._(
         utteranceId,
         VoiceUtteranceEventType.progress,
         start: start,
         end: end,
       );
  const VoiceUtteranceEvent.paused(String utteranceId)
    : this._(utteranceId, VoiceUtteranceEventType.paused);
  const VoiceUtteranceEvent.done(String utteranceId)
    : this._(utteranceId, VoiceUtteranceEventType.completed);
  const VoiceUtteranceEvent.stopped(String utteranceId)
    : this._(utteranceId, VoiceUtteranceEventType.stopped);
  const VoiceUtteranceEvent.error(String utteranceId)
    : this._(utteranceId, VoiceUtteranceEventType.error);

  final String utteranceId;
  final VoiceUtteranceEventType type;
  final int start;
  final int end;
}

abstract class VoicePlaybackEngine {
  Stream<VoiceUtteranceEvent> get utteranceEvents;

  Future<VoiceUtteranceAcceptance?> startUtterance({
    required String utteranceId,
    required String text,
    String? localeId,
    int offset = 0,
  });

  Future<bool> pauseUtterance(String utteranceId);
  Future<bool> resumeUtterance(String utteranceId);
  Future<void> stop();
}

/// Android TextToSpeech with an explicitly installed, offline voice.
///
/// The release gate also covers legacy voice-first callers: their run-finished
/// notifications cannot autoplay audio while Task 13 acceptance is pending.
class VoiceReplyService implements VoicePlaybackEngine {
  VoiceReplyService({
    MethodChannel? channel,
    Stream<Map<String, Object?>>? nativeEvents,
    this.releaseEnabled = kOvidVoiceEnabled,
  }) : _constructedChannel = channel,
       _nativeEvents = nativeEvents ?? VoiceNativeEvents.shared;

  static final VoiceReplyService I = VoiceReplyService();
  static const _native = MethodChannel('ovid/native');

  final MethodChannel? _constructedChannel;
  final Stream<Map<String, Object?>> _nativeEvents;
  final bool releaseEnabled;

  @visibleForTesting
  MethodChannel? channelOverrideForTest;
  @visibleForTesting
  bool? availableOverrideForTest;
  @visibleForTesting
  Future<bool> Function(String text, String? localeId)? speakOverrideForTest;
  @visibleForTesting
  void Function()? stopOverrideForTest;

  MethodChannel get _channel =>
      channelOverrideForTest ?? _constructedChannel ?? _native;

  Future<bool> isAvailable() async {
    final override = availableOverrideForTest;
    if (override != null) return override;
    if (!releaseEnabled) return false;
    try {
      return await _channel.invokeMethod<bool>('ttsAvailable') == true;
    } catch (error) {
      Diag.swallow('voice_reply.available', error);
      return false;
    }
  }

  @override
  Stream<VoiceUtteranceEvent> get utteranceEvents => _nativeEvents
      .where((event) => event['source'] == 'tts')
      .map(_eventFromNative)
      .where((event) => event != null)
      .cast<VoiceUtteranceEvent>();

  static VoiceUtteranceEvent? _eventFromNative(Map<String, Object?> event) {
    final id = event['utteranceId'];
    if (id is! String || id.isEmpty) return null;
    return switch (event['type']) {
      'start' => VoiceUtteranceEvent.start(id),
      'progress' => VoiceUtteranceEvent.progress(
        id,
        start: event['start'] is num ? (event['start'] as num).toInt() : 0,
        end: event['end'] is num ? (event['end'] as num).toInt() : 0,
      ),
      'paused' => VoiceUtteranceEvent.paused(id),
      'done' => VoiceUtteranceEvent.done(id),
      'stopped' => VoiceUtteranceEvent.stopped(id),
      'error' => VoiceUtteranceEvent.error(id),
      _ => null,
    };
  }

  /// Starts the exact supplied text at a UTF-16 [offset]. No markdown cleanup,
  /// summary generation or duration estimate is performed here.
  @override
  Future<VoiceUtteranceAcceptance?> startUtterance({
    required String utteranceId,
    required String text,
    String? localeId,
    int offset = 0,
  }) async {
    if (!releaseEnabled || text.trim().isEmpty || offset < 0) return null;
    try {
      final answer = await _channel
          .invokeMethod<Map<Object?, Object?>>('ttsSpeak', <String, Object?>{
            'utteranceId': utteranceId,
            'text': text,
            'locale': localeId,
            'offset': offset,
          });
      if (answer == null || answer['accepted'] != true) return null;
      final acceptedId = answer['utteranceId'];
      final acceptedLocale = answer['locale'];
      if (acceptedId != utteranceId ||
          acceptedLocale is! String ||
          acceptedLocale.isEmpty) {
        return null;
      }
      return VoiceUtteranceAcceptance(
        utteranceId: acceptedId as String,
        localeId: acceptedLocale,
      );
    } catch (error) {
      Diag.swallow('voice_reply.start', error);
      return null;
    }
  }

  /// Compatibility signature for the retired voice-first UI. That caller
  /// synthesizes a generated summary from a run-finished notification, so it
  /// must never reach the engine. Exact-answer playback uses [startUtterance]
  /// through VoicePlaybackController after an explicit play tap instead.
  Future<bool> speak(String text, {String? localeId}) async {
    final override = speakOverrideForTest;
    if (override != null) return override(text, localeId);
    return false;
  }

  @override
  Future<bool> pauseUtterance(String utteranceId) async {
    if (!releaseEnabled) return false;
    try {
      return await _channel.invokeMethod<bool>('ttsPause', {
            'utteranceId': utteranceId,
          }) ==
          true;
    } catch (error) {
      Diag.swallow('voice_reply.pause', error);
      return false;
    }
  }

  @override
  Future<bool> resumeUtterance(String utteranceId) async {
    if (!releaseEnabled) return false;
    try {
      return await _channel.invokeMethod<bool>('ttsResume', {
            'utteranceId': utteranceId,
          }) ==
          true;
    } catch (error) {
      Diag.swallow('voice_reply.resume', error);
      return false;
    }
  }

  @override
  Future<void> stop() async {
    final override = stopOverrideForTest;
    if (override != null) {
      override();
      return;
    }
    try {
      await _channel.invokeMethod<void>('ttsStop');
    } catch (error) {
      Diag.swallow('voice_reply.stop', error);
    }
  }

  static const List<({String id, String label, String localeId})> languages = [
    (id: 'en', label: 'English', localeId: 'en-IN'),
    (id: 'hi', label: 'हिन्दी', localeId: 'hi-IN'),
    (id: 'hinglish', label: 'Hinglish', localeId: 'hi-IN'),
    (id: 'pa', label: 'ਪੰਜਾਬੀ', localeId: 'pa-IN'),
    (id: 'ta', label: 'தமிழ்', localeId: 'ta-IN'),
  ];

  static String localeFor(String id) {
    for (final language in languages) {
      if (language.id == id) return language.localeId;
    }
    return id;
  }

  static String labelFor(String id) {
    for (final language in languages) {
      if (language.id == id) return language.label;
    }
    return id;
  }
}
