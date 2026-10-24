/// Wave 4 (Settings truthfulness) — the account settings the server owns and
/// enforces on every run. Contract: cloud/packages/shared/src/settings.ts and
/// cloud/apps/gateway/src/routes/{accountSettings,memory,health}.ts.
///
///  - `GET/PATCH /settings` — push notifications on/off, the BYOK key + model
///    runs use (SE-004, SE-010).
///  - `GET /presets`, `PUT/DELETE /presets/:id`, `PUT /sessions/:id/preset`
///    — custom agent presets the worker enforces (SE-007).
///  - `GET/PUT/DELETE /memory[/:name]` — the agent's memory files (SE-006).
///  - `GET /health/status` — public coarse service status (SE-014).
library;

import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';

@immutable
class MemoryListing {
  const MemoryListing(this.files, {required this.shared});
  final List<MemoryFileSummary> files;
  final bool shared;
}

/// The escrowed key (and provider model) every run uses.
@immutable
class ByokDefault {
  const ByokDefault({required this.keyId, required this.model});

  static ByokDefault? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final keyId = raw['keyId'];
    final model = raw['model'];
    if (keyId is! String ||
        keyId.isEmpty ||
        model is! String ||
        model.isEmpty) {
      return null;
    }
    return ByokDefault(keyId: keyId, model: model);
  }

  final String keyId;
  final String model;

  Map<String, Object> toJson() => {'keyId': keyId, 'model': model};
}

const int minResponseWaitSeconds = 15;
const int maxResponseWaitSeconds = 600;

@immutable
class ResponseWaitPreset {
  const ResponseWaitPreset({
    required this.id,
    required this.label,
    required this.seconds,
  });

  final String id;
  final String label;
  final int seconds;
}

const responseWaitPresets = <ResponseWaitPreset>[
  ResponseWaitPreset(id: 'fast', label: 'Fast', seconds: 15),
  ResponseWaitPreset(id: 'balanced', label: 'Balanced', seconds: 45),
  ResponseWaitPreset(id: 'deep', label: 'Deep', seconds: 120),
];

@immutable
class AccountSettings {
  const AccountSettings({
    required this.notificationsEnabled,
    required this.byokDefault,
    this.responseWaitSeconds,
  });

  factory AccountSettings.fromJson(Map<String, dynamic> j) {
    final wait = j['responseWaitSeconds'];
    return AccountSettings(
      notificationsEnabled: j['notificationsEnabled'] as bool? ?? true,
      byokDefault: ByokDefault.fromJson(j['byokDefault']),
      responseWaitSeconds:
          wait is num &&
              wait.isFinite &&
              wait >= minResponseWaitSeconds &&
              wait <= maxResponseWaitSeconds
          ? wait.toInt()
          : null,
    );
  }

  static const defaults = AccountSettings(
    notificationsEnabled: true,
    byokDefault: null,
  );

  final bool notificationsEnabled;
  final ByokDefault? byokDefault;

  /// Server-owned response wait. Null means an older server did not report it.
  final int? responseWaitSeconds;
}

/// One family of tools a custom preset can switch off.
@immutable
class PresetToolGroup {
  const PresetToolGroup({
    required this.id,
    required this.label,
    required this.tools,
  });

  factory PresetToolGroup.fromJson(Map<String, dynamic> j) => PresetToolGroup(
    id: j['id'] as String,
    label: j['label'] as String? ?? j['id'] as String,
    tools: [
      for (final t in (j['tools'] as List? ?? const <dynamic>[]))
        if (t is String) t,
    ],
  );

  final String id;
  final String label;
  final List<String> tools;
}

/// A custom preset stored on the server.
@immutable
class CloudCustomPreset {
  const CloudCustomPreset({
    required this.id,
    required this.label,
    this.description = '',
    this.deniedTools = const [],
    this.model,
    this.temperature,
  });

  factory CloudCustomPreset.fromJson(Map<String, dynamic> j) =>
      CloudCustomPreset(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        description: j['description'] as String? ?? '',
        deniedTools: [
          for (final t in (j['deniedTools'] as List? ?? const <dynamic>[]))
            if (t is String) t,
        ],
        model: (j['model'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['model'] as String).trim(),
        temperature: (j['temperature'] as num?)?.toDouble(),
      );

  final String id;
  final String label;
  final String description;
  final List<String> deniedTools;
  final String? model;
  final double? temperature;

  /// PUT /presets/:id body (the id rides the path).
  Map<String, Object?> toBody() => {
    'label': label,
    'description': description,
    'deniedTools': deniedTools,
    'model': model,
    'temperature': temperature,
  };

  /// Group ids whose every tool is denied.
  Set<String> deniedGroups(List<PresetToolGroup> groups) => {
    for (final g in groups)
      if (g.tools.isNotEmpty && g.tools.every(deniedTools.contains)) g.id,
  };

  /// A url-safe custom id from [label] (`custom-<slug>`), unique among
  /// [taken].
  static String idFor(String label, Iterable<String> taken) {
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base =
        'custom-${slug.isEmpty ? 'preset' : (slug.length > 32 ? slug.substring(0, 32).replaceAll(RegExp(r'-+$'), '') : slug)}';
    final used = taken.toSet();
    if (!used.contains(base)) return base;
    for (var i = 2; ; i++) {
      final candidate = '$base-$i';
      if (!used.contains(candidate)) return candidate;
    }
  }
}

@immutable
class CloudPresetCatalog {
  const CloudPresetCatalog({
    required this.builtIn,
    required this.custom,
    required this.toolGroups,
    required this.maxCustom,
  });

  factory CloudPresetCatalog.fromJson(Map<String, dynamic> j) =>
      CloudPresetCatalog(
        builtIn: [
          for (final id in (j['builtIn'] as List? ?? const <dynamic>[]))
            if (id is String) id,
        ],
        custom: [
          for (final p in (j['custom'] as List? ?? const <dynamic>[]))
            if (p is Map<String, dynamic>) CloudCustomPreset.fromJson(p),
        ],
        toolGroups: [
          for (final g in (j['toolGroups'] as List? ?? const <dynamic>[]))
            if (g is Map<String, dynamic>) PresetToolGroup.fromJson(g),
        ],
        maxCustom: (j['maxCustom'] as num?)?.toInt() ?? 20,
      );

  final List<String> builtIn;
  final List<CloudCustomPreset> custom;
  final List<PresetToolGroup> toolGroups;
  final int maxCustom;
}

@immutable
class MemoryFileSummary {
  const MemoryFileSummary({required this.name, required this.sizeBytes});
  final String name;
  final int sizeBytes;
}

@immutable
class MemoryFile {
  const MemoryFile({
    required this.name,
    required this.content,
    required this.revision,
  });

  factory MemoryFile.fromJson(Map<String, dynamic> j) => MemoryFile(
    name: j['name'] as String,
    content: j['content'] as String? ?? '',
    revision: j['revision'] as String? ?? '',
  );

  final String name;
  final String content;
  final String revision;
}

/// "ok" | "degraded" | "down" | "unknown" per capability.
enum ServiceCheck { ok, degraded, down, unknown }

ServiceCheck _check(Object? raw) => switch (raw) {
  'ok' => ServiceCheck.ok,
  'degraded' => ServiceCheck.degraded,
  'down' => ServiceCheck.down,
  _ => ServiceCheck.unknown,
};

@immutable
class ServiceStatus {
  const ServiceStatus({
    required this.overall,
    required this.storage,
    required this.queue,
    required this.agents,
    required this.models,
    required this.checkedAt,
  });

  factory ServiceStatus.fromJson(Map<String, dynamic> j) {
    final checks = j['checks'] is Map
        ? (j['checks'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    return ServiceStatus(
      overall: _check(j['status']),
      storage: _check(checks['storage']),
      queue: _check(checks['queue']),
      agents: _check(checks['agents']),
      models: _check(checks['models']),
      checkedAt: DateTime.tryParse(j['checkedAt'] as String? ?? ''),
    );
  }

  final ServiceCheck overall;
  final ServiceCheck storage;
  final ServiceCheck queue;
  final ServiceCheck agents;
  final ServiceCheck models;
  final DateTime? checkedAt;
}

/// Same rule as the server's `isValidMemoryName`.
bool isValidMemoryName(String name) =>
    name.length <= 80 &&
    RegExp(
      r'^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*\.md$',
    ).hasMatch(name) &&
    !(name.toLowerCase() == 'memory.md' && name != 'MEMORY.md');

class AccountSettingsClient {
  AccountSettingsClient({CloudRestClient? rest})
    : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  static AccountSettingsClient? _instance;
  static AccountSettingsClient get I => _instance ??= AccountSettingsClient();

  @visibleForTesting
  static void installForTest(AccountSettingsClient? client) =>
      _instance = client;

  // -- /settings ------------------------------------------------------------

  Future<AccountSettings> getSettings() async =>
      AccountSettings.fromJson(await _rest.getJson('/settings'));

  Future<AccountSettings> setNotificationsEnabled(bool enabled) async =>
      AccountSettings.fromJson(
        await _rest.patchJson(
          '/settings',
          body: {'notificationsEnabled': enabled},
        ),
      );

  /// null clears the BYOK default (runs use Ovid models again).
  Future<AccountSettings> setByokDefault(ByokDefault? value) async =>
      AccountSettings.fromJson(
        await _rest.patchJson(
          '/settings',
          body: {'byokDefault': value?.toJson()},
        ),
      );

  /// Persists only the wait preference. This does not touch a run or its
  /// cancellation endpoint; the server applies the setting to later waits.
  Future<AccountSettings> setResponseWaitSeconds(int seconds) async {
    if (seconds < minResponseWaitSeconds || seconds > maxResponseWaitSeconds) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        'Must be between $minResponseWaitSeconds and '
            '$maxResponseWaitSeconds seconds',
      );
    }
    final saved = AccountSettings.fromJson(
      await _rest.patchJson(
        '/settings',
        body: {'responseWaitSeconds': seconds},
      ),
    );
    if (saved.responseWaitSeconds != seconds) {
      throw StateError('The server did not confirm the response wait');
    }
    return saved;
  }

  // -- /presets -------------------------------------------------------------

  Future<CloudPresetCatalog> presets() async =>
      CloudPresetCatalog.fromJson(await _rest.getJson('/presets'));

  Future<CloudCustomPreset> savePreset(CloudCustomPreset preset) async =>
      CloudCustomPreset.fromJson(
        await _rest.putJson(
          '/presets/${Uri.encodeComponent(preset.id)}',
          body: preset.toBody(),
        ),
      );

  Future<void> deletePreset(String id) =>
      _rest.delete('/presets/${Uri.encodeComponent(id)}');

  /// Applies a built-in or custom preset to a chat (server session id).
  Future<void> applyPreset(String serverSessionId, String presetId) async {
    await _rest.putJson(
      '/sessions/${Uri.encodeComponent(serverSessionId)}/preset',
      body: {'presetId': presetId},
    );
  }

  // -- /memory --------------------------------------------------------------

  Future<MemoryListing> memoryFiles(String sessionId) async {
    final json = await _rest.getJson(
      '/memory?sessionId=${Uri.encodeComponent(sessionId)}',
    );
    final files = [
      for (final item in (json['items'] as List? ?? const <dynamic>[]))
        if (item is Map && item['name'] is String)
          MemoryFileSummary(
            name: item['name'] as String,
            sizeBytes: (item['sizeBytes'] as num?)?.toInt() ?? 0,
          ),
    ];
    return MemoryListing(files, shared: json['scope'] == 'shared');
  }

  Future<MemoryFile> readMemory(
    String sessionId,
    String name,
  ) async => MemoryFile.fromJson(
    await _rest.getJson(
      '/memory/${Uri.encodeComponent(name)}?sessionId=${Uri.encodeComponent(sessionId)}',
    ),
  );

  Future<MemoryFile> writeMemory(
    String sessionId,
    String name,
    String content, {
    String? ifRevision,
  }) async => MemoryFile.fromJson(
    await _rest.putJson(
      '/memory/${Uri.encodeComponent(name)}?sessionId=${Uri.encodeComponent(sessionId)}',
      body: {'content': content, 'ifRevision': ?ifRevision},
    ),
  );

  Future<void> deleteMemory(String sessionId, String name) => _rest.delete(
    '/memory/${Uri.encodeComponent(name)}?sessionId=${Uri.encodeComponent(sessionId)}',
  );

  // -- /health/status -------------------------------------------------------

  Future<ServiceStatus> serviceStatus() async => ServiceStatus.fromJson(
    await _rest.publicGetJson(
      '/health/status',
      timeout: const Duration(seconds: 10),
    ),
  );
}
