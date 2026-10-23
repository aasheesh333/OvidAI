import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

/// Absolute HTTPS endpoint or null. Collaboration metadata must never point
/// at an arbitrary URL (no userinfo/query/fragment).
Uri? _configuredHttpsEndpoint(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

String _productionId() => List.generate(
  24,
  (_) => Random.secure().nextInt(256),
).map((n) => n.toRadixString(16).padLeft(2, '0')).join();

String _accountDirectoryName(String uid) =>
    sha256.convert(utf8.encode(uid)).toString();

/// Atomic single-file persistence for the account-scoped collaboration
/// metadata. The private-sync outbox that used to provide this helper was
/// deleted (spec D6); collaboration only needs read + write-atomic here.
class _AtomicAccountFile {
  _AtomicAccountFile(this.file, {required this.owns});

  final File file;
  final bool Function() owns;
  Future<void> _tail = Future.value();
  int _sequence = 0;

  Future<void> get drained => _tail;

  Future<List<int>?> read() async {
    await _tail;
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> writeAtomically(List<int> bytes) {
    final operation = _tail.then((_) async {
      if (!owns()) throw StateError('Collaboration account changed.');
      await file.parent.create(recursive: true);
      final staged = File('${file.path}.tmp-$pid-${_sequence++}');
      try {
        await staged.writeAsBytes(bytes, flush: true);
        if (!owns()) throw StateError('Collaboration account changed.');
        staged.renameSync(file.path);
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    });
    _tail = operation.catchError((Object _) {});
    return operation;
  }
}

/// Runs one AI turn on THIS device's own provider/model/key and returns the
/// reply text. Injected by the caller in production so this owner never
/// imports an agent runtime; remote events can never invoke it.
typedef CollaborationTurnRunner =
    Future<String> Function({
      required String providerId,
      required String model,
      required List<Map<String, dynamic>> messages,
    });

/// A message copied from the owner's local chat when Collab starts.
class CollaborationSeedMessage {
  const CollaborationSeedMessage(this.role, this.text);
  final MessageRole role;
  final String text;
}

/// The gateway's own `turn_locked` copy, kept verbatim so the Android app and
/// the web client say exactly the same sentence.
const String collabTurnLockedSentence =
    "Another participant's reply is still streaming. Send when it finishes.";

/// What to say when the gateway has no `/chat` routes at all.
///
/// The collaboration routes are not committed on the gateway yet; only the
/// legacy `/shares` surface is. The client treats that as "not deployed" and
/// keeps the read-only share path usable.
const String collabUnavailableSentence =
    "Live sessions aren't available yet. Share a read-only link instead.";

/// User-facing reason for a collaboration failure (never echoes tokens).
String collaborationErrorMessage(Object error) {
  if (error is CollaborationClientException) {
    return switch (error.code) {
      // The single-sender rule refused this send. One plain sentence, the
      // same words the web client shows; never the machine code.
      'turn_locked' => collabTurnLockedSentence,
      'collab_unavailable' => collabUnavailableSentence,
      'session_full' =>
        'This session is full ($maxActiveMembers/$maxActiveMembers).',
      'invite_invalid' || 'invite_not_found' =>
        'This link was revoked or has expired. Ask the owner for a new link.',
      'membership_revoked' => 'The owner removed you from this session.',
      'session_not_found' => 'This live session no longer exists.',
      'session_closed' => 'The owner ended this live session.',
      'not_member' => 'You are no longer a member of this session.',
      'rate_limited' => 'This session is busy. Wait a moment and retry.',
      'quota_exhausted' => 'This session reached its message limit.',
      'unauthenticated' || 'credential_unavailable' =>
        'Sign in again to use live sessions.',
      'account_deleted' || 'account_deletion_pending' =>
        'This account is unavailable.',
      'request_timeout' => 'The request timed out. Check your connection and retry.',
      _ => 'Live session request failed. Check your connection and retry.',
    };
  }
  if (error is StateError) return error.message;
  return 'Live session request failed. Check your connection and retry.';
}

/// Owns the real account-scoped collaboration transport and inert projection.
/// Model turns run only through the injected [turnRunner], and only for text
/// the LOCAL user explicitly sends; remote events never reach it.
class CollaborationProduction extends ChangeNotifier {
  CollaborationProduction({
    this.endpoint = const String.fromEnvironment(
      'OVID_COLLABORATION_BASE_URL',
      defaultValue: 'https://api.ovidsi.com',
    ),
    this.publicOrigin = const String.fromEnvironment(
      'OVID_PUBLIC_SHARE_ORIGIN',
      defaultValue: 'https://ovidsi.com',
    ),
    this.turnRunner,
    required this.rootDirectory,
    required this.accountReady,
    required this.currentUid,
    required this.accessToken,
    this.appCheckToken,
    this.scheduler,
    http.Client Function()? httpClientFactory,
  }) : httpClientFactory = httpClientFactory ?? http.Client.new;

  final String endpoint;
  final String publicOrigin;
  final CollaborationTurnRunner? turnRunner;
  final Future<Directory> Function() rootDirectory;
  final bool Function() accountReady;
  final String? Function() currentUid;
  final Future<String?> Function() accessToken;
  /// Null when App Check is off (`OVID_APPCHECK`, the default).
  final Future<String?> Function()? appCheckToken;
  final http.Client Function() httpClientFactory;
  final CollaborationTimerScheduler? scheduler;
  String? _uid;
  int _epoch = 0;
  bool _foreground = false;
  Directory? _root;
  Map<String, dynamic> _metadata = {};
  _AtomicAccountFile? _metadataFile;
  _FencedBackend? _backend;
  CollaborationStore? _store;
  CollaborationClient? _client;
  http.Client? _http;
  CollaborationCoordinator? _coordinator;
  Future<void> _work = Future.value();
  String? invitationCode;

  bool get configured => _configuredHttpsEndpoint(endpoint) != null;
  bool get available =>
      configured && _uid != null && accountReady() && currentUid() == _uid;
  String? get sessionToken =>
      available ? _metadata['sessionToken'] as String? : null;
  projection.CollaborationState? get state => available ? _store?.state : null;
  bool get stale => _coordinator?.isStale ?? true;
  bool get isOwner =>
      state?.localParticipantId == state?.session.ownerParticipantId &&
      state != null;

  /// Owner's current share link, or null when none/revoked.
  String? get shareLink {
    final token = sessionToken;
    final code = available ? _metadata['linkCode'] as String? : null;
    final origin = _configuredHttpsEndpoint(publicOrigin);
    if (token == null || code == null || origin == null) return null;
    return '${origin.toString().replaceFirst(RegExp(r'/+$'), '')}/s/$token/$code';
  }

  /// Local chat session this live session was started from (owner only).
  String? get sourceSessionId =>
      available ? _metadata['sourceSessionId'] as String? : null;

  /// Participant ids whose model is currently producing a reply.
  Iterable<String> get respondingParticipants =>
      (state?.modelStates.entries ?? const [])
          .where(
            (e) =>
                e.value.status == ModelExecutionStatus.running ||
                e.value.status == ModelExecutionStatus.queued,
          )
          .map((e) => e.key);

  bool _live = false;

  /// True while the live session screen is visible: long-poll for ~1 s delivery.
  set live(bool value) {
    _live = value;
    _coordinator?.live = value;
  }

  bool _turnRunning = false;
  bool get turnRunning => _turnRunning;
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
      '${base.path}/collaboration/${_accountDirectoryName(uid)}',
    );
    _metadataFile = _AtomicAccountFile(
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
      baseUri: _configuredHttpsEndpoint(endpoint)!,
      httpClient: _http,
      accessToken: () => _token(accessToken, epoch),
      appCheckToken: appCheckToken == null
          ? null
          : () => _token(appCheckToken!, epoch),
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
    _metadata[key] ??= _productionId();
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

  /// Owner: create a live session from a local chat, copy its recent visible
  /// messages in as context, and mint a multi-use share link.
  Future<void> startFromConversation({
    required String sourceSessionId,
    required List<CollaborationSeedMessage> seed,
  }) async {
    if (sessionToken != null) {
      if (sourceSessionId == this.sourceSessionId && isOwner) {
        if (shareLink == null) await newLink();
        return;
      }
      throw StateError(
        'You are already in a live session. Leave it before starting another.',
      );
    }
    await create();
    await _serialize(() async {
      _check();
      final token = sessionToken;
      if (token == null) throw StateError('Live session was not created.');
      _metadata['sourceSessionId'] = sourceSessionId;
      await _save();
      final events = <Map<String, Object?>>[
        _event('presence', const PresencePayload(PresenceState.online)),
        for (final message in seed.length > maxSeedMessages
            ? seed.sublist(seed.length - maxSeedMessages)
            : seed)
          if (message.text.trim().isNotEmpty)
            _event('message', MessagePayload(message.text, role: message.role)),
      ];
      await _append(token, events);
    });
    await newLink();
  }

  /// Owner: (re)issue the share link. Revokes the previous link first.
  Future<void> newLink() => _serialize(() async {
    _check();
    final token = sessionToken;
    if (!isOwner || token == null) throw StateError('Owner permission required');
    final epoch = _epoch;
    final old = _metadata['linkInviteId'] as String?;
    if (old != null) {
      try {
        await _client!.revokeInvite(token, inviteId: old);
      } on CollaborationClientException catch (error) {
        if (error.code != 'invite_not_found') rethrow;
      }
    }
    final key = await _requestKey('link:$token:${old ?? 'first'}');
    if (!_owns(epoch)) return;
    final invite = await _client!.createInvite(
      token,
      idempotencyKey: key,
      maxUses: maxCollaborationInviteUses,
      ttlSeconds: 7 * 86400,
    );
    if (!_owns(epoch)) return;
    _metadata
      ..remove('request:link:$token:${old ?? 'first'}')
      ..['linkInviteId'] = invite.inviteId
      ..['linkCode'] = invite.inviteCode
      ..['linkExpiresAt'] = invite.expiresAt.toIso8601String();
    await _save();
    if (_owns(epoch)) notifyListeners();
  });

  /// Owner: stop the link admitting anyone new. Members stay.
  Future<void> revokeLink() => _serialize(() async {
    _check();
    final token = sessionToken;
    final inviteId = _metadata['linkInviteId'] as String?;
    if (!isOwner || token == null) throw StateError('Owner permission required');
    final epoch = _epoch;
    if (inviteId != null) {
      try {
        await _client!.revokeInvite(token, inviteId: inviteId);
      } on CollaborationClientException catch (error) {
        if (error.code != 'invite_not_found') rethrow;
      }
    }
    if (!_owns(epoch)) return;
    _metadata
      ..remove('linkInviteId')
      ..remove('linkCode')
      ..remove('linkExpiresAt');
    await _save();
    if (_owns(epoch)) notifyListeners();
  });

  /// Joiner: accept a `/s/<token>/<code>` link. A different current session
  /// must be left first (the UI confirms that with the user).
  Future<void> joinLink(String token, String code) async {
    if (sessionToken == token) return;
    if (sessionToken != null) {
      throw StateError(
        'You are already in a live session. Leave it before joining another.',
      );
    }
    await join(token, code);
    await _serialize(() async {
      _check();
      // Presence stamps this member's verified name for everyone's roster.
      await _append(token, [
        _event('presence', const PresencePayload(PresenceState.online)),
      ]);
    });
  }

  /// Sends the local user's prompt, then answers it with THIS user's own
  /// provider/model/key and publishes the reply. Everyone sees both.
  Future<void> sendTurn(
    String text, {
    required String providerId,
    required String model,
    required String modelLabel,
  }) async {
    final runner = turnRunner;
    if (runner == null) throw StateError('Live replies are unavailable in this build.');
    if (text.trim().isEmpty) throw StateError('Type a message first.');
    if (_turnRunning) throw StateError('Wait for your current reply to finish.');
    _turnRunning = true;
    notifyListeners();
    try {
      late String promptId;
      late List<Map<String, dynamic>> context;
      await _serialize(() async {
        _check();
        final token = _liveToken();
        final prompt = _event('message', MessagePayload(text, role: MessageRole.user));
        promptId = prompt['eventId']! as String;
        await _append(token, [
          prompt,
          _event('modelStatus', _status(providerId, model, modelLabel, ModelExecutionStatus.running)),
        ]);
        context = _context(state!);
      });
      String reply;
      try {
        reply = await runner(providerId: providerId, model: model, messages: context);
      } catch (error) {
        await _serialize(() async {
          _check();
          await _append(_liveToken(), [
            _event('modelStatus', _status(providerId, model, modelLabel, ModelExecutionStatus.failed)),
          ]);
        });
        rethrow;
      }
      await _serialize(() async {
        _check();
        await _append(_liveToken(), [
          _event(
            'message',
            MessagePayload(
              _bounded(reply),
              role: MessageRole.assistant,
              model: modelLabel,
              replyTo: promptId,
            ),
          ),
          _event('modelStatus', _status(providerId, model, modelLabel, ModelExecutionStatus.completed)),
        ]);
      });
    } finally {
      _turnRunning = false;
      notifyListeners();
    }
  }

  static const maxSeedMessages = 40;
  static const _maxMessageChars = 60000;

  static String _bounded(String text) => text.length <= _maxMessageChars
      ? text
      : '${text.substring(0, _maxMessageChars)}\n\n[Reply truncated for the live session]';

  String _liveToken() {
    final token = sessionToken;
    if (token == null ||
        state == null ||
        state!.status != projection.CollaborationStatus.live) {
      throw StateError('This live session is not active.');
    }
    return token;
  }

  ModelStatusPayload _status(
    String providerId,
    String model,
    String label,
    ModelExecutionStatus status,
  ) => ModelStatusPayload(
    providerId: providerId,
    requestedModel: model,
    reportedModel: null,
    displayName: label,
    streaming: false,
    status: status,
  );

  Map<String, Object?> _event(String kind, CollaborationPayload payload) => {
    'schemaVersion': collaborationSchemaVersion,
    'eventId': _productionId(),
    'kind': kind,
    'payload': payload.toWire(),
  };

  Future<void> _append(String token, List<Map<String, Object?>> events) async {
    final epoch = _epoch;
    final store = _store!;
    final generation = store.sessionGeneration;
    for (var i = 0; i < events.length; i += maxCollaborationEvents) {
      final batch = events.sublist(i, min(i + maxCollaborationEvents, events.length));
      final key = batch.first['eventId']! as String;
      final result = await _client!.appendEvents(token, events: batch, idempotencyKey: key);
      if (!_owns(epoch)) return;
      if (generation != null) {
        await store.applyAcknowledgement(
          ownerFence: _uid!,
          sessionGeneration: generation,
          page: result.events,
        );
      }
    }
    if (_owns(epoch)) {
      _coordinator?.refresh();
      notifyListeners();
    }
  }

  /// Shared transcript as chat turns for the local model. Other people's
  /// prompts are attributed by name so the model can tell speakers apart.
  static List<Map<String, dynamic>> contextFor(
    projection.CollaborationState state, {
    int maxMessages = 40,
    int maxChars = 120000,
  }) {
    final rows = <Map<String, dynamic>>[];
    var used = 0;
    for (final message in state.messages.reversed) {
      if (rows.length >= maxMessages || used + message.text.length > maxChars) break;
      used += message.text.length;
      rows.add(
        message.isAssistant
            ? {'role': 'assistant', 'content': message.text}
            : {
                'role': 'user',
                'content': '${state.nameOf(message.author)}: ${message.text}',
              },
      );
    }
    return [
      {
        'role': 'system',
        'content':
            'You are an AI assistant inside a shared live chat with several '
            'people. Each user message starts with the author\'s name. Earlier '
            'assistant replies may come from other people\'s models. Answer the '
            'latest user message, addressing its author.',
      },
      ...rows.reversed,
    ];
  }

  List<Map<String, dynamic>> _context(projection.CollaborationState state) =>
      contextFor(state);

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
    _coordinator!.live = _live;
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
