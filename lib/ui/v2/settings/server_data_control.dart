/// Copy and confirmation data for the two server-backed destructive actions.
///
/// Both routes compare the typed value with the account's registered EMAIL.
/// The server stores no phone, so this file never offers one and never falls
/// back to the sheet's `DELETE` word: a value the server cannot check must not
/// be presented as a confirmation.
library;

import '../../../core/cloud/data_control_client.dart';
import 'confirm_typed_sheet.dart';

/// The confirmation sheet for `POST /data/delete-all`.
V2ConfirmTypedSheetData serverDeleteConfirmation(String email) {
  return V2ConfirmTypedSheetData(
    contact: email,
    title: 'Delete all data?',
    irreversibleLabel: 'Cannot be undone',
    removalsTitle: 'Removed from your account',
    removals: const <String>[
      'Every chat and message',
      'Uploaded files and artifacts',
      'Chat memory',
      'Scheduled runs',
    ],
    // Not a subscription action: nothing here touches Play billing.
    playNote: '',
    prompt: 'Type your email to confirm',
    fieldLabel: 'Email',
    mismatchMessage: 'That does not match the email on your account.',
    matchedMessage: 'Matches the email on your account.',
    lockHint: 'The button below stays locked until it matches.',
    disabledHint: 'Type the email on your account to enable this action.',
    confirmLabel: 'Delete everything',
    cancelLabel: 'Cancel',
  );
}

/// The confirmation sheet for `POST /memory/reset`.
V2ConfirmTypedSheetData serverResetConfirmation(String email) {
  return V2ConfirmTypedSheetData(
    contact: email,
    title: 'Reset memory?',
    irreversibleLabel: 'Cannot be undone',
    removalsTitle: 'Ovid will forget',
    removals: const <String>['Global memory', 'Project memory', 'Chat memory'],
    playNote: '',
    prompt: 'Type your email to confirm',
    fieldLabel: 'Email',
    mismatchMessage: 'That does not match the email on your account.',
    matchedMessage: 'Matches the email on your account.',
    lockHint: 'The button below stays locked until it matches.',
    disabledHint: 'Type the email on your account to enable this action.',
    confirmLabel: 'Reset memory',
    cancelLabel: 'Cancel',
  );
}

/// What the server counted, in one line. Only ever built from a confirmed
/// answer: the screen has no other source for these numbers.
String serverDeleteSummary(DataDeletionCounts counts) {
  final files = counts.attachments + counts.artifacts + counts.workspaceFiles;
  return '${_plural(counts.sessions, 'chat', 'chats')} · '
      '${_plural(files, 'file', 'files')}';
}

/// The memory reset's confirmed count.
String serverResetSummary(int files) => files == 0
    ? 'There was no memory to reset.'
    : '${_plural(files, 'file', 'files')} removed.';

String _plural(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';
