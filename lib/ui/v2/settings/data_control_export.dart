/// Web-safe half of the "Save to device" export.
///
/// The real writer needs `CloudBackup`, the zip service and the platform save
/// dialog, all of which reach `core/state.dart` and therefore `sqlite3` →
/// `dart:ffi`. That cannot compile for web, so the page imports this file and
/// [data_control_export_io.dart] conditionally. On web the button reports that
/// saving lives in the app instead of failing to build the gallery.
library;

/// Outcome of writing a backup archive to the device.
///
/// A cancelled save and a failed save are different: cancellation is silent,
/// a failure names what went wrong.
class SavedExport {
  const SavedExport.saved(String this.path) : message = null;

  const SavedExport.cancelled() : path = null, message = null;

  const SavedExport.failed(String this.message) : path = null;

  /// Where the archive was written, or null when nothing was written.
  final String? path;

  /// What to tell the person when the save failed, or null when it did not.
  final String? message;

  bool get isCancelled => path == null && message == null;
}

/// Default (web) implementation: saving a backup needs the app.
Future<SavedExport> saveHistoryExport() async => const SavedExport.failed(
  'Saving a backup is available in the app.',
);
