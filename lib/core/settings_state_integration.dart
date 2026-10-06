part of 'state.dart';

/// These operations belong to AppState: the UI never mutates session storage.
extension _SettingsStateIntegration on AppState {
  void _bindSettingsActions() {
    SettingsActions.bindOwner(
      // The existing Settings UI treats a non-null callback as READY. Legacy
      // best-effort deletion cannot satisfy its verified all-store contract.
      reset: null,
      restore: () {
        final account = _sessionAccountToken;
        return (backup, ids) => _withSettingsBarrier(
          account,
          (token) => _publishSettingsBackup(backup, ids, token),
        );
      },
    );
  }

  void _checkSettingsOwner(Object token) {
    if (!identical(AppState.I, this) ||
        !identical(token, _sessionAccountToken) ||
        !_sessionAccountReady) {
      throw StateError('Account changed or is not ready. No restore published.');
    }
  }

  Future<T> _withSettingsBarrier<T>(
    Object expectedAccount,
    Future<T> Function(Object token) action,
  ) async {
    _checkSettingsOwner(expectedAccount);
    if (_settingsBusy) throw StateError('Settings operation already in progress.');
    final settled = Completer<void>();
    _settingsOperation = settled.future;
    _settingsBusy = true;
    // Revoke captured run/lifecycle ownership synchronously, including queued
    // prompts. The public readiness getter prevents new agent/schedule work.
    final token = _sessionAccountToken = Object();
    _cancelPersistDebounce();
    try {
      AgentService.I.sessionAccountChanged();
      refresh();
      await _persistWriteInFlight;
      await SettingsActions.awaitPendingWrites();
      _checkSettingsOwner(token);
      return await action(token);
    } finally {
      _settingsBusy = false;
      _settingsOperation = null;
      settled.complete();
      if (_persistScheduled && _sessionAccountReady) _armPersistDebounce();
      refresh();
    }
  }

  Future<void> _publishSettingsBackup(
    StagedSettingsBackup backup,
    Map<String, String> newIds,
    Object token,
  ) async {
    if (!_sessionNamespaceLoaded) {
      throw StateError('Load the account session history before restoring.');
    }
    await _loadDeferredSessionSnapshot();
    _checkSettingsOwner(token);
    // Pending deletion can remove an ID/workspace after publication. Do not
    // retry failed destructive work as a side effect of a transcript import.
    await _awaitWorkspaceDeletions();
    _checkSettingsOwner(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    _checkSettingsOwner(token);
    final key = _accountKey(AppState._kSessions);
    final oldRows = prefs.getStringList(key);
    final liveBefore = _sessionJsonForPersistence();
    final activeBefore = activeSessionId;
    final existingIds = <String>{
      for (final s in sessions) s.id,
      for (final raw in [...?oldRows, ...liveBefore])
        (jsonDecode(raw) as Map<String, dynamic>)['id'] as String,
    };
    final sourceIds = backup.sessions.map((s) => s['id'] as String).toSet();
    if (sourceIds.length != backup.sessions.length ||
        !setEquals(sourceIds, newIds.keys.toSet()) ||
        newIds.values.toSet().length != sourceIds.length ||
        newIds.values.any((id) =>
            !RegExp(r'^restored-[a-f0-9]{32}$').hasMatch(id) ||
            existingIds.contains(id) || sourceIds.contains(id))) {
      throw StateError('Restore requires distinct, fresh session IDs.');
    }

    final copiedDirectories = <Directory>[];
    var writeAttempted = false;
    var keepCopies = false;
    try {
      final support = await getApplicationSupportDirectory();
      _checkSettingsOwner(token);
      final workspaces = Directory('${support.path}/workspaces');
      await workspaces.create(recursive: true);
      final stagingRoot = await backup.directory.resolveSymbolicLinks();
      final imported = <ChatSession>[];
      for (final row in backup.sessions) {
        _checkSettingsOwner(token);
        final id = newIds[row['id']]!;
        final workspace = Directory('${workspaces.path}/ws_$id');
        if (FileSystemEntity.typeSync(workspace.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('Restore workspace ID already exists.');
        }
        final paths = <String, String>{};
        Directory? workspaceStage;
        Future<String> copyAttachment(String blob, int size) async {
          if (paths.containsKey(blob)) return paths[blob]!;
          final source = backup.attachments[blob];
          if (source == null) throw StateError('Missing staged attachment.');
          if (await FileSystemEntity.type(source.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              !(await source.resolveSymbolicLinks()).startsWith(
                '$stagingRoot${Platform.pathSeparator}',
              )) {
            throw StateError('Staged attachment is no longer a regular file.');
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in source.openRead(
            0, SettingsBackupService.maxAttachmentBytes + 1,
          )) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.length != size ||
              bytes.length > SettingsBackupService.maxAttachmentBytes) {
            throw StateError('Staged attachment changed size or exceeds its limit.');
          }
          _checkSettingsOwner(token);
          if (workspaceStage == null) {
            workspaceStage = await workspaces.createTemp('.restore-');
            copiedDirectories.add(workspaceStage!);
          }
          final name = '${paths.length}.blob';
          final file = File('${workspaceStage!.path}/$name');
          await file.writeAsBytes(bytes, flush: true);
          if (sha256.convert(await file.readAsBytes()) != sha256.convert(bytes)) {
            throw StateError('Attachment copy verification failed.');
          }
          return paths[blob] = '${workspace.path}/$name';
        }
        final messages = <Message>[];
        for (final raw in row['messages'] as List) {
          final attachments = <MessageAttachment>[];
          for (final a in raw['attachments'] as List) {
            String? path;
            if (a['status'] == 'included') {
              path = await copyAttachment(a['blob'] as String, a['size'] as int);
            }
            attachments.add(MessageAttachment(
              name: a['name'] as String, size: a['size'] as int, path: path,
            ));
          }
          messages.add(Message(
            role: raw['role'] as String,
            kind: MsgKind.values.byName(raw['kind'] as String),
            content: raw['content'] as String,
            time: DateTime.parse(raw['time'] as String),
            toolState: 'ok',
            attachments: attachments,
          ));
        }
        if (workspaceStage != null) {
          _checkSettingsOwner(token);
          // Reserve only this new session's workspace. No existing folder is
          // reused or replaced, and normal session deletion owns these copies.
          if (FileSystemEntity.typeSync(workspace.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw StateError('Restore workspace ID already exists.');
          }
          workspaceStage!.renameSync(workspace.path);
          copiedDirectories[copiedDirectories.length - 1] = workspace;
        }
        imported.add(ChatSession(
          id: id, title: row['title'] as String,
          model: 'Select a provider', mode: 'safe',
          createdAt: DateTime.parse(row['createdAt'] as String),
          messages: messages,
        ));
      }
      void checkUnchanged() {
        _checkSettingsOwner(token);
        if (activeBefore != activeSessionId ||
            !listEquals(liveBefore, _sessionJsonForPersistence())) {
          throw StateError('Sessions changed during restore. Retry the import.');
        }
      }

      checkUnchanged();
      await prefs.reload();
      checkUnchanged();
      if (!listEquals(oldRows, prefs.getStringList(key))) {
        throw StateError('Session storage changed during restore.');
      }
      // One authoritative write: append without rewriting a single existing
      // row, active selection, bootstrap snapshot, setting, grant or schedule.
      final rows = [...?oldRows, for (final s in imported) jsonEncode(s.toJson())];
      writeAttempted = true;
      await _writeRestoreRows(prefs, key, rows);
      checkUnchanged();
      sessions.addAll(imported);
      _sessionNamespaceLoaded = true;
      keepCopies = true;
      // No session-start hook, workspace warmup, or execution on import.
    } catch (error) {
      if (writeAttempted) {
        try {
          // The account handoff waits for this rollback. Use the captured key,
          // never the possibly new account's current namespace.
          await _writeRestoreRows(prefs, key, oldRows);
        } catch (rollbackError) {
          // A persisted candidate may still reference these files. Preserve
          // them rather than turning recoverable data into dangling paths.
          keepCopies = true;
          throw StateError('Restore failed: $error. Rollback could not be '
              'verified: $rollbackError. Attachment copies retained at '
              '${copiedDirectories.map((d) => d.path).join(", ")}.');
        }
      }
      rethrow;
    } finally {
      _invalidateSessionPersistenceCache();
      if (!keepCopies) {
        for (final directory in copiedDirectories) {
          await directory.delete(recursive: true);
        }
      }
    }
  }

  Future<void> _writeRestoreRows(
    SharedPreferences prefs, String key, List<String>? rows,
  ) async {
    final accepted = rows == null
        ? await prefs.remove(key)
        : await prefs.setStringList(key, rows);
    await prefs.reload();
    if (!accepted || !listEquals(rows, prefs.getStringList(key))) {
      throw StateError('Session storage write/readback failed.');
    }
  }
}
