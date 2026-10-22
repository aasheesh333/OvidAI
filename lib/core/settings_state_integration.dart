part of 'state.dart';

/// These operations belong to AppState: the UI never mutates session storage.
extension _SettingsStateIntegration on AppState {
  void _bindSettingsActions() {
    SettingsActions.bindOwner(
      // The verified all-store reset runs under the same barrier as restore and
      // reports per-store readback truth; it never claims success for a store
      // whose storage it cannot read back.
      reset: _resetAllData,
      // SE-009: archives are restored by uploading them to the user's Ovid
      // Cloud account (CloudBackup.uploadArchiveSessions), never by writing
      // local-only `restored-` rows that would not sync and that the model
      // would have no history for. The local publisher refuses.
      restore: () =>
          (StagedSettingsBackup backup, Map<String, String> ids) async {
            throw UnsupportedError(
              'Archives are imported into Ovid Cloud. No local data changed.',
            );
          },
    );
    // An accepted account deletion must not leave a readable transcript,
    // draft, cache or saved key on this device. The reset is the only wipe
    // that fences writers and reads every store back; it also performs the
    // local sign-out. A partial result throws so the deletion flow keeps the
    // person signed in and can retry instead of claiming the device is clean.
    FirebaseService.I.eraseDeviceCopyOnDeletion = () async {
      final result = await _resetAllData();
      if (!result.success) {
        final detail = result.failures.entries
            .map((entry) => '${entry.key}: ${entry.value}')
            .join('; ');
        throw StateError('Local erase incomplete ($detail)');
      }
    };
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
            await SessionHistoryRepository.I.removeRows(
              prefs,
              _accountKey(AppState._kSessions),
            );
            // chat-history.db: every namespace, the FTS index, migration
            // markers and quarantined raw rows — not just this account's.
            await SessionHistoryRepository.I.deleteAll();
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
            final rows = await SessionHistoryRepository.I.readRows(
              prefs,
              _accountKey(AppState._kSessions),
            );
            return (rows == null || rows.isEmpty) &&
                await SessionHistoryRepository.I.isEmpty() &&
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
        ResetStoreKind.memory: FunctionalResetStore(
          name: ResetStoreKind.memory.id,
          onStage: () async {},
          // Memory is server-owned; the pre-cloud Markdown directory is the
          // only local artifact and is removed directly (P8 Task 20 retired
          // the local store).
          onDelete: _deleteMemoryRoot,
          onVerifyDeleted: () async =>
              !(await _memoryRootForAccount(_sessionAccountId)).existsSync(),
        ),
        ResetStoreKind.account: FunctionalResetStore(
          name: ResetStoreKind.account.id,
          onStage: () async {},
          // Barrier-safe local sign-out: FirebaseService.signOutLocal() performs
          // the local sign-out side effects WITHOUT awaiting
          // AppState.transitionSessionAccount (which awaits this barrier's
          // `_settingsOperation` and would deadlock). Server-side deletion is a
          // separate, explicitly-requested flow.
          // Before the local sign-out: unregister this device's FCM token
          // while the ID token still works (SE-002). After it: sign the
          // Firebase/Google SDKs out too, or the persisted credential signs
          // the user back in on the next launch (SE-001).
          onDelete: () async {
            final firebase = FirebaseService.I;
            await firebase.runBeforeSignOut();
            await firebase.signOutLocal();
            await firebase.signOutSdk();
          },
          // `isSignedIn` is read back directly because `accountReady` also folds
          // in the barrier's own session-account fence and would otherwise
          // verify as empty. The SDK's persisted user is read back as well.
          onVerifyDeleted: () async =>
              !FirebaseService.I.isSignedIn && FirebaseService.I.sdkSignedOut,
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
          // Local reset covers the app-owned local share cache. Server-side
          // conversation shares are deleted by the account lifecycle, not a
          // device reset. Per-session browser profiles died with the on-device
          // browser (P8 Task 16).
          onDelete: () async {
            await ConversationShareService.production().clearLocal();
          },
          onVerifyDeleted: () async =>
              (await ConversationShareService.production().localShareCount()) ==
                  0,
        ),
        ResetStoreKind.collaboration: _accountLifecycle.asResetStore(
          ResetStoreKind.collaboration.id,
        ),
        ResetStoreKind.configuration: FunctionalResetStore(
          name: ResetStoreKind.configuration.id,
          onStage: () async {},
          onDelete: _resetConfiguration,
          onVerifyDeleted: _verifyConfigurationReset,
        ),
        ResetStoreKind.secrets: FunctionalResetStore(
          name: ResetStoreKind.secrets.id,
          onStage: () async {},
          onDelete: () async {
            await GitHubService.I.signOut();
            await AppState._secureStorage.deleteAll();
            for (final provider in providers) {
              provider.apiKey = '';
            }
          },
          onVerifyDeleted: () async =>
              (await AppState._secureStorage.readAll()).isEmpty &&
              providers.every((provider) => provider.apiKey.isEmpty),
        ),
        ResetStoreKind.preferences: FunctionalResetStore(
          name: ResetStoreKind.preferences.id,
          onStage: () async {},
          onDelete: _resetPreferences,
          onVerifyDeleted: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.reload();
            return prefs.getKeys().every(_resetKeepPreferences.contains);
          },
        ),
        ResetStoreKind.skills: FunctionalResetStore(
          name: ResetStoreKind.skills.id,
          onStage: () async {},
          onDelete: () async {
            final dir = await _userSkillsDir();
            if (await dir.exists()) await dir.delete(recursive: true);
          },
          onVerifyDeleted: () async => !await (await _userSkillsDir()).exists(),
        ),
        ResetStoreKind.exports: FunctionalResetStore(
          name: ResetStoreKind.exports.id,
          onStage: () async {},
          onDelete: () async {
            for (final file in await _legacyChatExports()) {
              await file.delete();
            }
          },
          onVerifyDeleted: () async => (await _legacyChatExports()).isEmpty,
        ),
        ResetStoreKind.cache: FunctionalResetStore(
          name: ResetStoreKind.cache.id,
          onStage: () async {},
          onDelete: () async {
            for (final entity in await _appTempArtifacts()) {
              await entity.delete(recursive: true);
            }
          },
          onVerifyDeleted: () async => (await _appTempArtifacts()).isEmpty,
        ),
        ResetStoreKind.cookies: FunctionalResetStore(
          name: ResetStoreKind.cookies.id,
          onStage: () async {},
          // The on-device WebView browser (and its cookie jars) was removed in
          // P8 Task 16; the cloud browser's cookies live server-side. The
          // canonical store stays so reset enumeration remains complete, and
          // there is nothing local left to verify.
          onDelete: () async {},
          onVerifyDeleted: () async => true,
        ),
        ResetStoreKind.drafts: FunctionalResetStore(
          name: ResetStoreKind.drafts.id,
          onStage: () async {},
          onDelete: () async {
            // In-memory owners first, so a debounced flush cannot write a
            // draft back after its file is gone. Studio state now lives in
            // StudioRemoteClient / StudioDraftStore (P8 Task 19 re-point).
            StudioRemoteClient.I.clearAll();
            await ComposerDraftStore.I.clearAll();
            // Studio editor drafts and legacy uncommitted drafts share
            // the same app-private record directory.
            await StudioDraftStore.I.deleteAll('');
          },
          onVerifyDeleted: () async =>
              StudioRemoteClient.I.noDrafts &&
              await ComposerDraftStore.I.isEmpty() &&
              await StudioDraftStore.I.isEmpty(),
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

  /// Preferences that survive an all-data reset.
  static const _resetKeepPreferences = <String>{};

  /// Configuration keys owned by [_resetConfiguration]. Prefix keys carry a
  /// per-server suffix.
  static const _configurationKeys = <String>{
    AppState._kProviders,
    AppState._kLastModel,
    AppState._kLastProvider,
    AppState._kRecentModels,
    AppState._kCustomPresets,
  };
  static const _configurationPrefixes = <String>[];

  bool _isConfigurationKey(String key) =>
      _configurationKeys.contains(key) ||
      _configurationPrefixes.any(key.startsWith);

  /// Providers, custom presets and global grants go back to the built-in
  /// catalog, in memory and on disk.
  Future<void> _resetConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where(_isConfigurationKey).toList()) {
      await prefs.remove(key);
    }
    await prefs.reload();
    providers.clear();
    _seed();
    PresetRegistry.clearCustom();
    lastSelectedModel = '';
    lastSelectedProviderId = null;
    refresh();
  }

  Future<bool> _verifyConfigurationReset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return !prefs.getKeys().any(_isConfigurationKey) &&
        PresetRegistry.customPresets.isEmpty &&
        providers.every((provider) => provider.apiKey.isEmpty);
  }

  /// Clears every remaining preference except the device keep-list, and
  /// returns the in-memory settings to their defaults so a later write
  /// cannot persist the old values again.
  Future<void> _resetPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final kept = <String, Object?>{
      for (final key in _resetKeepPreferences) key: prefs.get(key),
    };
    await prefs.clear();
    for (final entry in kept.entries) {
      final value = entry.value;
      switch (value) {
        case final bool v:
          await prefs.setBool(entry.key, v);
        case final int v:
          await prefs.setInt(entry.key, v);
        case final double v:
          await prefs.setDouble(entry.key, v);
        case final String v:
          await prefs.setString(entry.key, v);
        case final List<String> v:
          await prefs.setStringList(entry.key, v);
        default:
          break;
      }
    }
    await prefs.reload();
    memoryEnabled = true;
    showReasoning = true;
    githubSync = true;
    workflowEnabled = true;
    autoRunSafeCommands = true;
    shareSessionMemory = false;
    refresh();
  }

  Future<Directory> _userSkillsDir() async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/skills');

  /// `ovid-sessions-<ts>.json` files written by older "Export chats".
  Future<List<File>> _legacyChatExports() async {
    final docs = await getApplicationDocumentsDirectory();
    if (!await docs.exists()) return const [];
    return [
      await for (final entity in docs.list(followLinks: false))
        if (entity is File &&
            RegExp(
              r'^ovid-sessions-\d+\.json$',
            ).hasMatch(entity.uri.pathSegments.last))
          entity,
    ];
  }

  /// Temporary archives and staging directories the app itself creates
  /// (transcript backups, session exports, chat exports, restore staging,
  /// native share snapshots).
  /// Other temp content belongs to plugins/WebView and is left alone.
  Future<List<FileSystemEntity>> _appTempArtifacts() async {
    final temp = await getTemporaryDirectory();
    if (!await temp.exists()) return const [];
    const prefixes = [
      'ovid-backup-',
      'ovid-export-',
      'ovid-chat-export-',
      'ovid-restore-',
      // Native share snapshots (Android cacheDir/outgoing-shares).
      'outgoing-shares',
    ];
    return [
      await for (final entity in temp.list(followLinks: false))
        if (prefixes.any(
          (prefix) => _baseName(entity.path).startsWith(prefix),
        ))
          entity,
    ];
  }

  String _baseName(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  Future<T> _withSettingsBarrier<T>(
    Object expectedAccount,
    Future<T> Function(Object token) action,
  ) async {
    _checkSettingsOwner(expectedAccount);
    if (_settingsBusy) {
      throw StateError('Settings operation already in progress.');
    }
    final settled = Completer<void>();
    _settingsOperation = settled.future;
    _settingsBusy = true;
    // Revoke captured run/lifecycle ownership synchronously, including queued
    // prompts. The public readiness getter prevents new agent/schedule work.
    final token = _sessionAccountToken = Object();
    _accountLifecycle.fenceSynchronously();
    _cancelPersistDebounce();
    try {
      CloudAgentFacade.resetAccountStateIfInstalled();
      refresh();
      await _persistWriteInFlight;
      await _featureBinding;
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
}
