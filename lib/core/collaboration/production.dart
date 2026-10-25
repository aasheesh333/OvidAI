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

/// Legacy call-site metadata only. These values are never uploaded or used to
/// seed a collaboration; the canonical server session owns its existing history.
@Deprecated('Pass only sourceSessionId; server history is authoritative.')
class CollaborationSeedMessage {
  const CollaborationSeedMessage(this.role, this.text);
  final MessageRole role;
  final String text;
}

/// Actual user-selected file bytes for the real attachment pipeline. Local
/// filesystem paths are deliberately not accepted or put on the wire.
class CollaborationAttachmentInput {
  const CollaborationAttachmentInput({
    required this.name,
    required this.bytes,
    this.contentType,
  });

  final String name;
  final List<int> bytes;
  final String? contentType;
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

/// Owns account-fenced transport and an inert server replay projection.
/// Turns, assistant text, model status, usage, and membership facts originate
/// only at the server. This class has no model/provider execution dependency.
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
  final Future<Directory> Function() rootDirectory;
  final bool Function() accountReady;
  final String? Function() currentUid;
  final Future<String?> Function() accessToken;
  /// Null when App Check is off (`OVID_APPCHECK`, the default).
  final Future<String?> Function()? appCheckToken;
  final http.Client Function() httpClientFactory;
  final CollaborationTimerScheduler? scheduler;
  String? _uid;
  int? _accountGeneration;
  int _epoch = 0;
  Future<void>? _profileRefresh;
  bool _profileRefreshScheduled = false;
  bool _profileRefreshAgain = false;
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
  String? get accountUid => _uid;
  int? get accountGeneration => _accountGeneration;
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
    if (_uid == uid &&
        _accountGeneration == generation &&
        _store != null &&
        _client != null) {
      return;
    }
    await release();
    _uid = uid;
    _accountGeneration = generation;
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

  Future<void> create({String? sessionId}) => _serialize(() async {
    _check();
    final epoch = _epoch;
    final operation = 'create:${sessionId ?? 'new'}';
    final key = await _requestKey(operation);
    if (!_owns(epoch)) return;
    final result = await _client!.create(requestId: key, sessionId: sessionId);
    if (!_owns(epoch)) return;
    _metadata['sessionToken'] = result.sessionToken;
    _metadata.remove('request:$operation');
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

  /// Adopts an existing canonical chat. The server derives all history; no
  /// local message seed, presence event, or assistant synthesis is uploaded.
  Future<void> startFromConversation({
    required String sourceSessionId,
    @Deprecated('Ignored; canonical server history is authoritative.')
    List<CollaborationSeedMessage> seed = const [],
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
    await create(sessionId: sourceSessionId);
    await _serialize(() async {
      _check();
      if (sessionToken == null) {
        throw StateError('Live session was not created.');
      }
      _metadata['sourceSessionId'] = sourceSessionId;
      await _save();
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
  }

  /// Admits a turn and returns after the authoritative DTO arrives. No prompt,
  /// status, assistant reply, or usage event is synthesized locally; visible
  /// changes arrive only through subsequent authoritative state/replay.
  Future<void> sendTurn(
    String text, {
    String? model,
    @Deprecated('Legacy UI argument; never sent or used for execution.')
    String? providerId,
    @Deprecated('Legacy UI argument; never sent or used for execution.')
    String? modelLabel,
    List<CollaborationAttachmentInput> attachments = const [],
  }) async {
    if (text.trim().isEmpty) throw StateError('Type a message first.');
    if (_turnRunning) throw StateError('Wait for your current reply to finish.');
    final epoch = _epoch;
    _turnRunning = true;
    notifyListeners();
    try {
      await _serialize(() async {
        _check();
        final token = _liveToken();
        final identity = sha256.convert(utf8.encode(jsonEncode({
          'text': text,
          'model': model,
          'attachments': [
            for (final attachment in attachments)
              {
                'name': attachment.name,
                'contentType': attachment.contentType,
                'sha256': sha256.convert(attachment.bytes).toString(),
              },
          ],
        })));
        final operation = 'turn:$token:$identity';
        final key = await _requestKey(operation);
        if (!_owns(epoch)) return;
        final attachmentIds = <String>[];
        for (var index = 0; index < attachments.length; index++) {
          final pendingAttachment = 'turn-attachment:$operation:$index';
          final finalizedId = _metadata[pendingAttachment];
          if (finalizedId is String && finalizedId.isNotEmpty) {
            attachmentIds.add(finalizedId);
            continue;
          }
          final input = attachments[index];
          final ticket = await _client!.createAttachment(
            token,
            idempotencyKey: '$key-a$index-c',
            name: input.name,
            size: input.bytes.length,
            contentType: input.contentType ?? 'application/octet-stream',
          );
          if (!_owns(epoch)) return;
          await _client!.uploadAttachment(ticket, input.bytes);
          if (!_owns(epoch)) return;
          final finalized = await _client!.finalizeAttachment(
            token,
            attachmentId: ticket.attachmentId,
          );
          if (!_owns(epoch)) return;
          // Durably retain the ready identity before admission. A lost turn
          // response must reuse this ID because ready objects cannot be
          // created again through the pending-ticket endpoint.
          _metadata[pendingAttachment] = finalized.attachmentId;
          await _save();
          if (!_owns(epoch)) return;
          attachmentIds.add(finalized.attachmentId);
        }
        await _client!.turn(
          token,
          idempotencyKey: key,
          text: text,
          model: model,
          attachmentIds: attachmentIds,
        );
        if (!_owns(epoch)) return;
        // Cleanup is an in-memory transaction as well as a disk write. If the
        // write fails, retain the old operation key and ready IDs so the next
        // call replays the accepted admission instead of creating another run.
        final pending = Map<String, dynamic>.from(_metadata);
        _metadata.remove('request:$operation');
        for (var index = 0; index < attachments.length; index++) {
          _metadata.remove('request:$operation:a$index-c');
          _metadata.remove('turn-attachment:$operation:$index');
        }
        try {
          await _save();
        } catch (_) {
          _metadata = pending;
          rethrow;
        }
        if (!_owns(epoch)) return;
        _coordinator?.refresh();
        notifyListeners();
      });
    } finally {
      if (epoch == _epoch) {
        _turnRunning = false;
        notifyListeners();
      }
    }
  }

  String _liveToken() {
    final token = sessionToken;
    if (token == null ||
        state == null ||
        state!.status != projection.CollaborationStatus.live) {
      throw StateError('This live session is not active.');
    }
    return token;
  }

  /// Compatibility alias for older callers. It uses the same server admission
  /// contract as [sendTurn], never the retired arbitrary event writer.
  Future<void> sendMessage(String text) => sendTurn(text);

  Future<String> report({
    required String kind,
    required String targetId,
    required String reason,
    String? details,
  }) async {
    var reportId = '';
    await _serialize(() async {
      _check();
      final token = _liveToken();
      final epoch = _epoch;
      final operation = 'report:$token:${sha256.convert(utf8.encode(jsonEncode({
        'kind': kind,
        'targetId': targetId,
        'reason': reason,
        'details': details,
      })))}';
      final key = await _requestKey(operation);
      if (!_owns(epoch)) return;
      reportId = await _client!.report(
        token,
        requestId: key,
        kind: kind,
        targetId: targetId,
        reason: reason,
        details: details,
      );
      if (!_owns(epoch)) return;
      _metadata.remove('request:$operation');
      await _save();
    });
    if (reportId.isEmpty) {
      throw StateError('Collaboration account changed.');
    }
    return reportId;
  }

  Future<void> block(String participantId) => _serialize(() async {
    _check();
    final epoch = _epoch;
    await _client!.block(_liveToken(), participantId: participantId);
    if (_owns(epoch)) _coordinator?.refresh();
  });

  Future<void> unblock(String participantId) => _serialize(() async {
    _check();
    final epoch = _epoch;
    await _client!.unblock(_liveToken(), participantId: participantId);
    if (_owns(epoch)) _coordinator?.refresh();
  });

  Future<void> removeMessage(String messageId) => _serialize(() async {
    _check();
    if (!isOwner) throw StateError('Owner permission required');
    final epoch = _epoch;
    await _client!.removeMessage(_liveToken(), messageId: messageId);
    if (_owns(epoch)) _coordinator?.refresh();
  });

  /// Mints a fresh authorized object capability without persisting or logging
  /// its signed URL. A stale account/session response is never returned.
  Future<CollaborationObjectUrl> objectUrl({
    String? artifactId,
    String? attachmentId,
  }) async {
    _check();
    final epoch = _epoch;
    final token = _liveToken();
    final result = await _client!.objectUrl(
      token,
      artifactId: artifactId,
      attachmentId: attachmentId,
    );
    if (!_owns(epoch) || sessionToken != token) {
      throw StateError('Collaboration account changed.');
    }
    return result;
  }

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
      onChanged: () {
        if (_owns(epoch)) notifyListeners();
      },
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

  bool _ownsProfile(String uid, int generation, int epoch) =>
      _owns(epoch) &&
      _uid == uid &&
      _accountGeneration == generation &&
      currentUid() == uid;

  /// Fire-and-forget after the account server confirms a profile rename. It
  /// never awaits or rethrows into the rename/Firebase-mirror path. Duplicate
  /// same-tick calls coalesce; a later confirmed rename leaves a trailing read.
  void forceRefreshAfterProfileRename({
    required String uid,
    required int generation,
  }) {
    final epoch = _epoch;
    if (!_ownsProfile(uid, generation, epoch)) return;
    final token = sessionToken;
    if (token == null || _client == null || _store == null) return;
    if (_coordinator != null) {
      if (_profileRefreshScheduled) return;
      _profileRefreshScheduled = true;
      scheduleMicrotask(() {
        if (epoch != _epoch) return;
        _profileRefreshScheduled = false;
        if (_ownsProfile(uid, generation, epoch)) {
          _coordinator?.refreshRoomFacts();
        }
      });
      return;
    }
    if (_profileRefresh != null) {
      _profileRefreshAgain = true;
      return;
    }
    if (_profileRefreshScheduled) return;
    _profileRefreshScheduled = true;
    scheduleMicrotask(() {
      if (epoch != _epoch) return;
      _profileRefreshScheduled = false;
      if (!_ownsProfile(uid, generation, epoch)) return;
      final operation = _refreshProfileWithoutCoordinator(
        uid,
        generation,
        epoch,
        token,
      );
      _profileRefresh = operation;
      unawaited(operation.whenComplete(() {
        if (identical(_profileRefresh, operation)) _profileRefresh = null;
      }));
    });
  }

  Future<void> _refreshProfileWithoutCoordinator(
    String uid,
    int generation,
    int epoch,
    String token,
  ) async {
    do {
      _profileRefreshAgain = false;
      try {
        final fresh = await _client!.state(token);
        if (!_ownsProfile(uid, generation, epoch) || sessionToken != token) {
          return;
        }
        final coordinator = _coordinator;
        if (coordinator != null) {
          coordinator.refreshRoomFacts();
          return;
        }
        final store = _store!;
        final current = store.state;
        if (current != null &&
            current.status == projection.CollaborationStatus.live) {
          final storeGeneration = store.sessionGeneration;
          if (store.accountId != uid || storeGeneration == null) return;
          store.state = current.refreshServerFacts(
            session: fresh.session,
            members: fresh.members,
            turn: fresh.turn,
          );
        } else {
          await store.installBootstrap(
            accountId: uid,
            sessionGeneration: epoch,
            state: projection.CollaborationState.bootstrap(
              session: fresh.session.withTurn(fresh.turn),
              members: fresh.members,
              localParticipantId: fresh.member.participantId,
              lastSequence: 0,
              replayThroughSequence: fresh.replayThroughSequence,
            ),
          );
        }
        if (_ownsProfile(uid, generation, epoch)) notifyListeners();
      } catch (_) {
        // Isolated from the already-successful server rename and Firebase
        // mirror. Ordinary polling or a later confirmation can retry.
      }
    } while (_profileRefreshAgain &&
        _ownsProfile(uid, generation, epoch));
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
    _accountGeneration = null;
    _profileRefresh = null;
    _profileRefreshScheduled = false;
    _profileRefreshAgain = false;
    _coordinator?.dispose();
    _coordinator = null;
    _store?.fence();
    _http?.close();
    _http = null;
    _client = null;
    invitationCode = null;
    _turnRunning = false;
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
