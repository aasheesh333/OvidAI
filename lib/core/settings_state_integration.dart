part of 'state.dart';

/// These operations belong to AppState: the UI never mutates session storage.
extension _SettingsStateIntegration on AppState {
  void _bindSettingsActions() {
    SettingsActions.bindOwner(
      // The verified all-store reset runs under the same barrier as restore and
      // reports per-store readback truth; it never claims success for a store
      // whose storage it cannot read back.
      reset: _resetAllData,
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
      throw StateError(
        'Account changed or is not ready. No restore published.',
      );
    }
  }

  /// Verified all-store reset. Runs under the settings barrier so producers are
  /// fenced and pending writes drained, stages every canonical store without
  /// destroying data, then commits and reads each store back. A store whose
  /// owner exposes no readback API is reported unsupported rather than claimed
  /// as complete.
  Future<SettingsResetResult> _resetAllData() async {
    final account = _sessionAccountToken;
    final result = await _withSettingsBarrier(account, (token) async {
      _checkSettingsOwner(token);
      final ledgerIds = <String>{};
      final workspaceIds = <String>{};
      final receipts = ImageReceiptStore();
      final receiptAccount = ImageStudio.I.accountId;
      final coordinator = ResetCoordinator.canonical({
        ResetStoreKind.sessions: FunctionalResetStore(
          name: ResetStoreKind.sessions.id,
          onStage: () async {
            workspaceIds
              ..clear()
              ..addAll([
                for (final session in sessions)
                  if (session.sandboxId != null &&
                      session.sandboxId!.isNotEmpty)
                    session.sandboxId!,
              ]);
          },
          onDelete: () async {
            // Workspaces first: a failed workspace delete aborts before the
            // durable transcript rows are removed, so the store is reported
            // failed rather than silently half-reset.
            for (final sandboxId in workspaceIds) {
              await _workspaceDeleter(sandboxId);
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_accountKey(AppState._kSessions));
            await prefs.remove(_accountKey(AppState._kActive));
            await prefs.remove(_accountKey(AppState._kSessionBootstrap));
            await prefs.reload();
            _clearDeferredSessions();
            sessions.clear();
            activeSessionId = null;
            _dirtySessionIds.clear();
            _notifiedDeletedSessionIds.clear();
            _invalidateSessionPersistenceCache();
            refresh();
          },
          onVerifyDeleted: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.reload();
            final rows = prefs.getStringList(_accountKey(AppState._kSessions));
            return (rows == null || rows.isEmpty) &&
                sessions.isEmpty &&
                _deferredSessionJson == null &&
                activeSessionId == null;
          },
        ),
        ResetStoreKind.search: FunctionalResetStore(
          name: ResetStoreKind.search.id,
          onStage: () async {},
          onDelete: () => SessionSearch.I.clear(),
          onVerifyDeleted: () => SessionSearch.I.isEmpty(),
        ),
        ResetStoreKind.ledger: FunctionalResetStore(
          name: ResetStoreKind.ledger.id,
          onStage: () async {
            ledgerIds
              ..clear()
              ..addAll(sessions.map((session) => session.id))
              ..addAll(_deferredLedgerSessionIds());
          },
          onDelete: () async {
            for (final id in ledgerIds) {
              await SessionLedger.I.delete(id);
            }
          },
          onVerifyDeleted: () => SessionLedger.I.isEmpty(),
        ),
        ResetStoreKind.memory: FunctionalResetStore(
          name: ResetStoreKind.memory.id,
          onStage: () async {},
          onDelete: () async => (await _openMemoryStore()).deleteAll(),
          onVerifyDeleted: () async =>
              !(await _openMemoryStore()).root.existsSync(),
        ),
        ResetStoreKind.usage: FunctionalResetStore(
          name: ResetStoreKind.usage.id,
          onStage: () async {
            await _usageAppendTail;
            if (_usageAppendError != null) throw _usageAppendError!;
            final store = _usageAttemptStore;
            if (store != null) await store.retire();
          },
          onDelete: () async {
            final root = (await _usageAccountRoot())!;
            final journal = File(
              '${root.path}/${UsageAttemptStore.journalFileName}',
            );
            if (await journal.exists()) await journal.delete();
            if (await root.exists()) {
              await for (final entity in root.list(followLinks: false)) {
                if (entity is File &&
                    entity.path.startsWith('${journal.path}.tmp')) {
                  await entity.delete();
                }
              }
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_accountKey(AppState._kUsage));
            await prefs.reload();
            usageLog.clear();
            _usageAttemptStore = null;
            _usageStoreToken = null;
            _usageStorageError = null;
            _usageAppendError = null;
          },
          onVerifyDeleted: () async {
            final root = (await _usageAccountRoot())!;
            final journal = File(
              '${root.path}/${UsageAttemptStore.journalFileName}',
            );
            var staging = false;
            if (await root.exists()) {
              await for (final entity in root.list(followLinks: false)) {
                if (entity is File &&
                    entity.path.startsWith('${journal.path}.tmp')) {
                  staging = true;
                }
              }
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.reload();
            return !await journal.exists() &&
                !staging &&
                prefs.getStringList(_accountKey(AppState._kUsage)) == null &&
                usageLog.isEmpty &&
                _usageAttemptStore == null;
          },
        ),
        ResetStoreKind.account: FunctionalResetStore(
          name: ResetStoreKind.account.id,
          onStage: () async {},
          // Barrier-safe local sign-out: FirebaseService.signOutLocal() performs
          // the local sign-out side effects WITHOUT awaiting
          // AppState.transitionSessionAccount (which awaits this barrier's
          // `_settingsOperation` and would deadlock). Server-side deletion is a
          // separate, explicitly-requested flow.
          onDelete: () => FirebaseService.I.signOutLocal(),
          // `isSignedIn` is read back directly because `accountReady` also folds
          // in the barrier's own session-account fence and would otherwise
          // verify as empty.
          onVerifyDeleted: () async => !FirebaseService.I.isSignedIn,
        ),
        ResetStoreKind.imageReceipts: FunctionalResetStore(
          name: ResetStoreKind.imageReceipts.id,
          onStage: () async {},
          onDelete: () async {
            if (receiptAccount != null && receiptAccount.isNotEmpty) {
              await receipts.redactAccount(receiptAccount);
            }
          },
          onVerifyDeleted: () async {
            if (receiptAccount == null || receiptAccount.isEmpty) return true;
            return (await receipts.list(
              receiptAccount,
            )).every((row) => row.receipt == null);
          },
        ),
        ResetStoreKind.shares: FunctionalResetStore(
          name: ResetStoreKind.shares.id,
          onStage: () async {},
          // Local reset covers the app-owned local state: per-session browser
          // profiles and the local share cache. Server-side conversation
          // shares are deleted by the account lifecycle, not a device reset.
          onDelete: () async {
            await SessionBrowserProfiles.I.deleteAll();
            await ConversationShareService.production().clearLocal();
          },
          onVerifyDeleted: () async =>
              (await SessionBrowserProfiles.I.profileCount()) == 0 &&
              (await ConversationShareService.production().localShareCount()) ==
                  0,
        ),
      });
      await coordinator.prepare();
      return (await coordinator.commit()).toSettingsResult();
    });
    // Restore a usable empty chat after a verified session wipe, mirroring the
    // legacy reset. Kept outside the barrier so the fresh root is not itself a
    // reset store and is never read back as residual data.
    if (result.completed.contains(ResetStoreKind.sessions.id)) {
      try {
        _ensureActiveSession();
        refresh();
      } catch (e) {
        Diag.swallow('state', e);
      }
    }
    return result;
  }

  Set<String> _deferredLedgerSessionIds() {
    final ids = <String>{};
    for (final raw in _deferredSessionJson ?? const <String>[]) {
      try {
        final id = (jsonDecode(raw) as Map<String, dynamic>)['id'];
        if (id is String && id.isNotEmpty) ids.add(id);
      } catch (_) {
        // A malformed deferred row is not a ledger owner.
      }
    }
    return ids;
  }

  Future<T> _withSettingsBarrier<T>(
    Object expectedAccount,
    Future<T> Function(Object token) action,
  ) async {
    _checkSettingsOwner(expectedAccount);
    if (_settingsBusy)
      throw StateError('Settings operation already in progress.');
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
    // Capture every allowlisted setting before any transcript write so a failed
    // settings apply (or a later transcript rollback) can restore it exactly.
    final previousSettings = <String, Object?>{
      for (final settingKey in SettingsBackupService.settingsAllowlist)
        settingKey: prefs.get(settingKey),
    };
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
        newIds.values.any(
          (id) =>
              !RegExp(r'^restored-[a-f0-9]{32}$').hasMatch(id) ||
              existingIds.contains(id) ||
              sourceIds.contains(id),
        )) {
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
            0,
            SettingsBackupService.maxAttachmentBytes + 1,
          )) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.length != size ||
              bytes.length > SettingsBackupService.maxAttachmentBytes) {
            throw StateError(
              'Staged attachment changed size or exceeds its limit.',
            );
          }
          _checkSettingsOwner(token);
          if (workspaceStage == null) {
            workspaceStage = await workspaces.createTemp('.restore-');
            copiedDirectories.add(workspaceStage!);
          }
          final name = '${paths.length}.blob';
          final file = File('${workspaceStage!.path}/$name');
          await file.writeAsBytes(bytes, flush: true);
          if (sha256.convert(await file.readAsBytes()) !=
              sha256.convert(bytes)) {
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
              path = await copyAttachment(
                a['blob'] as String,
                a['size'] as int,
              );
            }
            attachments.add(
              MessageAttachment(
                name: a['name'] as String,
                size: a['size'] as int,
                path: path,
              ),
            );
          }
          messages.add(
            Message(
              role: raw['role'] as String,
              kind: MsgKind.values.byName(raw['kind'] as String),
              content: raw['content'] as String,
              time: DateTime.parse(raw['time'] as String),
              toolState: 'ok',
              attachments: attachments,
            ),
          );
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
        imported.add(
          ChatSession(
            id: id,
            title: row['title'] as String,
            model: 'Select a provider',
            mode: 'safe',
            createdAt: DateTime.parse(row['createdAt'] as String),
            messages: messages,
          ),
        );
      }
      void checkUnchanged() {
        _checkSettingsOwner(token);
        if (activeBefore != activeSessionId ||
            !listEquals(liveBefore, _sessionJsonForPersistence())) {
          throw StateError(
            'Sessions changed during restore. Retry the import.',
          );
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
      final rows = [
        ...?oldRows,
        for (final s in imported) jsonEncode(s.toJson()),
      ];
      writeAttempted = true;
      await _writeRestoreRows(prefs, key, rows);
      checkUnchanged();
      // Settings commit shares the transcript publication's rollback boundary:
      // `_writeRestoreRows` verified its own readback first, and a settings
      // failure self-rolls back every touched key before the catch below
      // restores the transcript rows. Transcript-only archives (empty
      // `settings`) never enter this branch, preserving version-1 exports.
      if (backup.settings.isNotEmpty) {
        await SettingsBackupService.applySettingsAtomically(
          snapshot: backup.settings,
          previous: previousSettings,
          write: (settingKey, value) async {
            final accepted = switch (value) {
              null => await prefs.remove(settingKey),
              final bool v => await prefs.setBool(settingKey, v),
              final int v => await prefs.setInt(settingKey, v),
              final double v => await prefs.setDouble(settingKey, v),
              final String v => await prefs.setString(settingKey, v),
              _ => throw StateError('Unsupported setting value.'),
            };
            await prefs.reload();
            if (!accepted || prefs.get(settingKey) != value) {
              throw StateError('Setting storage write/readback failed.');
            }
          },
        );
      }
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
          throw StateError(
            'Restore failed: $error. Rollback could not be '
            'verified: $rollbackError. Attachment copies retained at '
            '${copiedDirectories.map((d) => d.path).join(", ")}.',
          );
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
    SharedPreferences prefs,
    String key,
    List<String>? rows,
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
