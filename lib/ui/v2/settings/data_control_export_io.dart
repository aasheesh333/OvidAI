/// Native half of the "Save to device" export.
///
/// This file is only compiled when `dart:library.io` exists, so it may reach
/// the zip service and the platform save dialog directly.
library;

import 'package:file_picker/file_picker.dart';

import '../../../core/cloud/cloud_backup.dart';
import '../../../core/settings_backup_service.dart';
import 'data_control_export.dart';

/// Builds the same zip the export uses and hands it to the platform save
/// dialog, so "Save to device" produces a real file instead of a toast.
Future<SavedExport> saveHistoryExport() async {
  final snapshot = await CloudBackup().fetchHistory();
  final plan = SettingsBackupService.planExport(snapshot.sessions);
  if (plan.included.isEmpty) {
    return SavedExport.failed(
      plan.limitHit ?? 'There is nothing to export yet.',
    );
  }
  final bytes = await SettingsBackupService().export(plan.included);
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Ovid backup',
    fileName: 'ovid-transcripts-v1.zip',
    type: FileType.custom,
    allowedExtensions: const <String>['zip'],
    bytes: bytes,
  );
  if (path == null) return const SavedExport.cancelled();
  return SavedExport.saved(path);
}
