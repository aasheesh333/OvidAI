import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../private_sync/file_outbox.dart';
import '../private_sync/production.dart'
    show configuredHttpsEndpoint, productionId, accountDirectoryName;
import '../reset_coordinator.dart';
import 'client.dart';
import 'coordinator.dart';
import 'file_store.dart';
import 'models.dart';
import 'reducer.dart' as projection;
import 'store.dart';

class ProductionCollaborationScheduler implements CollaborationTimerScheduler {
  ProductionCollaborationScheduler({this.onTick});
  final void Function()? onTick;
  @override
  CollaborationTimer schedule(Duration delay, void Function() callback) =>
      _Timer(
        Timer(delay, () {
          callback();
          onTick?.call();
        }),
      );
}

class _Timer implements CollaborationTimer {
  _Timer(this.timer);
  final Timer timer;
  @override
  void cancel() => timer.cancel();
}

/// Owns the real account-scoped collaboration transport and inert projection.
/// There is deliberately no AgentService or execution callback in this owner.
class CollaborationProduction extends ChangeNotifier {
  CollaborationProduction({
    this.endpoint = const String.fromEnvironment('OVID_COLLABORATION_BASE_URL'),
    required this.rootDirectory,
    required this.accountReady,
    required this.currentUid,
    required this.accessToken,
    required this.appCheckToken,
    this.scheduler,
    http.Client Function()? httpClientFactory,
  }) : httpClientFactory = httpClientFactory ?? http.Client.new;

  final String endpoint;
  final Future<Directory> Function() rootDirectory;
  final bool Function() accountReady;
  final String? Function() currentUid;
  final Future<String?> Function() accessToken;
  final Future<String?> Function() appCheckToken;
  final http.Client Function() httpClientFactory;
  final CollaborationTimerScheduler? scheduler;
  String? _uid;
  int _epoch = 0;
  bool _foreground = false;
  Directory? _root;
  Map<String, dynamic> _metadata = {};
  FileOutboxPersistence? _metadataFile;
  _FencedBackend? _backend;
  CollaborationStore? _store;
  CollaborationClient? _client;
  http.Client? _http;
  CollaborationCoordinator? _coordinator;
  Future<void> _work = Future.value();
  String? invitationCode;

  bool get configured => configuredHttpsEndpoint(endpoint) != null;
  bool get available =>
      configured && _uid != null && accountReady() && currentUid() == _uid;
  String? get sessionToken =>
      available ? _metadata['sessionToken'] as String? : null;
  projection.CollaborationState? get state => available ? _store?.state : null;
  bool get stale => _coordinator?.isStale ?? true;
  bool get isOwner =>
      state?.localParticipantId == state?.session.ownerParticipantId &&
      state != null;
  bool _owns(int epoch) => epoch == _epoch && available;

  AccountLifecycleDependencies get lifecycle => AccountLifecycleDependencies(
    onFence: fence,
    onRevoke: release,
    onBind: bind,
    onClear: clear,
    onVerifyEmpty: verifyEmpty,
  );

  Future<void> bind(String uid, int generation) async {
    if (!configured || !accountReady() || currentUid() != uid) return;
    if (_uid == uid && _store != null && _client != null) return;
    await release();
    _uid = uid;
    final epoch = _epoch;
    final base = await rootDirectory();
    if (!_owns(epoch)) return;
    _root = Directory(
      '${base.path}/collaboration/${accountDirectoryName(uid)}',
    );
    _metadataFile = FileOutboxPersistence(
      File('${_root!.path}/session.json'),
      owns: () => _owns(epoch),
    );
    final bytes = await _metadataFile!.read();
    if (!_owns(epoch)) return;
    _metadata = bytes == null
        ? {'accountId': uid}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    if (_metadata['accountId'] != uid) {
      throw StateError('Collaboration account mismatch');
    }
    _backend = _FencedBackend(
      FileCollaborationStoreBackend(
        File('${_root!.path}/projection.json'),
        ownerFence: uid,
      ),
      () => _owns(epoch),
      () {
        if (_owns(epoch)) notifyListeners();
      },
    );
    _store = CollaborationStore(_backend!, ownerFence: uid);
    await _store!.load();
    if (!_owns(epoch)) return;
    _http = httpClientFactory();
    _client = CollaborationClient(
      baseUri: configuredHttpsEndpoint(endpoint)!,
      httpClient: _http,
      accessToken: () => _token(accessToken, epoch),
      appCheckToken: () => _token(appCheckToken, epoch),
    );
    _start();
    notifyListeners();
  }

  Future<String?> _token(Future<String?> Function() get, int epoch) async {
    if (!_owns(epoch)) return null;
    final token = await get();
    return _owns(epoch) ? token : null;
  }

  Future<void> _save() =>
      _metadataFile!.writeAtomically(utf8.encode(jsonEncode(_metadata)));

  Future<String> _requestKey(String operation) async {
    final key = 'request:$operation';
    _metadata[key] ??= productionId();
    await _save();
    return _metadata[key] as String;
  }

  void _check() {
    if (!available || _client == null) {
      throw StateError('Collaboration requires a configured, ready account');
    }
  }

  Future<void> create() => _serialize(() async {
    _check();
    final epoch = _epoch;
    final key = await _requestKey('create');
    if (!_owns(epoch)) return;
    final result = await _client!.create(requestId: key);
    if (!_owns(epoch)) return;
    _metadata['sessionToken'] = result.sessionToken;
    _metadata.remove('request:create');
    await _save();
    if (!_owns(epoch)) return;
    await _store!.installBootstrap(
      accountId: _uid!,
      sessionGeneration: 0,
      state: projection.CollaborationState.bootstrap(
        session: result.session,
        members: [result.member],
        localParticipantId: result.member.participantId,
        lastSequence: 0,
      ),
    );
    if (!_owns(epoch)) return;
    _start();
    notifyListeners();
  });

  Future<void> join(String token, String code) => _serialize(() async {
    _check();
    _validateToken(token);
    if (code.isEmpty) throw StateError('Invitation code is required');
    final epoch = _epoch;
    final key = await _requestKey(
      'join:${sha256.convert(utf8.encode('$token:$code'))}',
    );
    if (!_owns(epoch)) return;
    await _client!.join(token, invitationCode: code, idempotencyKey: key);
    if (!_owns(epoch)) return;
    _metadata['sessionToken'] = token;
    await _save();
    if (!_owns(epoch)) return;
    _store!.fence();
    _start();
    notifyListeners();
  });

  Future<void> sendMessage(String text) => _serialize(() async {
    _check();
    final token = sessionToken;
    if (token == null ||
        state == null ||
        state!.status != projection.CollaborationStatus.live ||
        text.trim().isEmpty) {
      throw StateError('An active collaboration and message are required');
    }
    final epoch = _epoch;
    final operation = 'message:${sha256.convert(utf8.encode('$token:$text'))}';
    final store = _store!;
    final generation = store.sessionGeneration;
    final key = await _requestKey(operation);
    if (!_owns(epoch)) return;
    // The only outbound event from this screen is an explicit local message.
    // Replay is never fed into an agent prompt, queue, tool, or execution bridge.
    final result = await _client!.appendEvents(
      token,
      events: [
        {
          'schemaVersion': 1,
          'eventId': key,
          'kind': 'message',
          'payload': MessagePayload(text).toWire(),
        },
      ],
      idempotencyKey: key,
    );
    if (!_owns(epoch)) return;
    if (generation != null) {
      await store.applyAcknowledgement(ownerFence: _uid!, sessionGeneration: generation, page: result.events);
    }
    _metadata.remove('request:$operation');
    await _save();
    if (_owns(epoch)) {
      _coordinator?.refresh();
      notifyListeners();
    }
  });

  Future<void> invite() => _serialize(() async {
    _check();
    if (!isOwner || sessionToken == null) {
      throw StateError('Owner permission required');
    }
    final epoch = _epoch;
    final key = await _requestKey('invite:$sessionToken');
    if (!_owns(epoch)) return;
    final result = await _client!.createInvite(
      sessionToken!,
      idempotencyKey: key,
    );
    if (!_owns(epoch)) return;
    invitationCode = result.inviteCode;
    _metadata.remove('request:invite:$sessionToken');
    await _save();
    if (_owns(epoch)) notifyListeners();
  });

  Future<void> revokeMember(String participantId) => _serialize(() async {
    _check();
    if (!isOwner || sessionToken == null) {
      throw StateError('Owner permission required');
    }
    final epoch = _epoch;
    await _client!.revokeMember(sessionToken!, participantId: participantId);
    if (_owns(epoch)) _coordinator?.refresh();
  });

  Future<void> leaveOrClose() => _serialize(() async {
    _check();
    final token = sessionToken;
    if (token == null) return;
    final epoch = _epoch;
    try {
    if (isOwner) {
      final key = await _requestKey('close:$token');
      if (!_owns(epoch)) return;
      await _client!.close(token, idempotencyKey: key);
    } else {
      await _client!.leave(token);
    }
    } on CollaborationClientException catch (error) {
      if (!_terminal(error)) rethrow;
    }
    if (!_owns(epoch)) return;
    await _disconnect(epoch, token);
  });

  /// Leaves the local session even when its remote authority is unavailable.
  Future<void> disconnect() => _serialize(() async {
    _check();
    final token = sessionToken;
    if (token != null) await _disconnect(_epoch, token);
  });

  Future<void> _disconnect(int epoch, String token) async {
    if (!_owns(epoch) || sessionToken != token) return;
    _coordinator?.dispose();
    _coordinator = null;
    _store!.fence();
    final cleared = <String, dynamic>{'accountId': _uid};
    await _metadataFile!.writeAtomically(utf8.encode(jsonEncode(cleared)));
    if (!_owns(epoch)) return;
    _metadata = cleared;
    await _store!.drained;
    if (_owns(epoch)) {
      invitationCode = null;
      notifyListeners();
    }
  }

  static bool _terminal(CollaborationClientException error) =>
      error.isTerminalSessionError;

  void _start() {
    _coordinator?.dispose();
    _coordinator = null;
    if (!_foreground ||
        !available ||
        sessionToken == null ||
        _store == null ||
        _client == null) {
      return;
    }
    final epoch = _epoch;
    final token = sessionToken!;
    _coordinator = CollaborationCoordinator(
      client: _client!,
      store: _store!,
      accountId: _uid!,
      sessionToken: sessionToken!,
      scheduler: scheduler ?? ProductionCollaborationScheduler(
        onTick: () {
          if (_owns(epoch)) notifyListeners();
        },
      ),
      random: Random().nextDouble,
      onTerminal: (_) {
        unawaited(_serialize(() => _disconnect(epoch, token)).catchError((Object _) {}));
      },
    )..start();
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _start();
  }

  void refresh() {
    if (_coordinator == null) {
      _start();
    } else {
      _coordinator!.refresh();
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final epoch = _epoch;
    final token = sessionToken;
    final next = _work.then((_) async {
      try {
        await action();
      } on CollaborationClientException catch (error) {
        if (_terminal(error) && token != null) await _disconnect(epoch, token);
        rethrow;
      }
    });
    _work = next.catchError((Object _) {});
    return next;
  }

  void fence() {
    _epoch++;
    _uid = null;
    _coordinator?.dispose();
    _coordinator = null;
    _store?.fence();
    _http?.close();
    _http = null;
    _client = null;
    invitationCode = null;
    notifyListeners();
  }

  Future<void> release() async {
    fence();
    await _work;
    await _metadataFile?.drained;
    await _backend?.drained;
    await _store?.drained;
    _store = null;
    _metadata = {};
  }

  Future<void> clear() async {
    await release();
    final root = Directory('${(await rootDirectory()).path}/collaboration');
    if (await root.exists()) await root.delete(recursive: true);
  }

  Future<bool> verifyEmpty() async => !await Directory(
    '${(await rootDirectory()).path}/collaboration',
  ).exists();

  static void _validateToken(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,512}$').hasMatch(value)) {
      throw StateError('Invalid session token');
    }
  }
}

class _FencedBackend implements GuardedCollaborationStoreBackend {
  _FencedBackend(this.backend, this.owns, this.changed);
  final FileCollaborationStoreBackend backend;
  final bool Function() owns;
  final void Function() changed;
  Future<void> _tail = Future.value();
  Future<void> get drained => _tail;
  @override
  Future<Map<String, Object?>?> read() => backend.read();
  @override
  Future<void> write(Map<String, Object?> record) => writeGuarded(record, () => true);

  @override
  Future<void> writeGuarded(Map<String, Object?> record, bool Function() sessionOwns) {
    final next = _tail.then((_) async {
      if (!owns()) throw StateError('Account changed');
      await backend.writeGuarded(record, () => owns() && sessionOwns());
      if (!owns()) throw StateError('Account changed');
      Timer.run(() {
        if (owns()) changed();
      });
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> clear() => backend.clear();
}
