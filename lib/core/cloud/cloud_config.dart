/// Cloud endpoints for the thin client (P8 Task 5).
///
/// Production pins the gateway REST and WS origins. A staging build overrides
/// either with `--dart-define=OVID_CLOUD_REST_BASE=…` /
/// `--dart-define=OVID_CLOUD_WS_URL=…` (staging only — release builds never
/// ship the defines, so the prod constants apply; an empty define is ignored).
class CloudConfig {
  const CloudConfig._();

  static const String prodRestBase = 'https://api.ovidsi.com/cloud/v1';
  static const String prodWsUrl = 'wss://api.ovidsi.com/cloud/ws';

  static const String _restBaseDefine =
      String.fromEnvironment('OVID_CLOUD_REST_BASE');
  static const String _wsUrlDefine = String.fromEnvironment('OVID_CLOUD_WS_URL');

  /// REST base URL (the `/cloud/v1` prefix, no trailing slash).
  static String get restBase =>
      _restBaseDefine.trim().isEmpty ? prodRestBase : _restBaseDefine;

  /// WebSocket URL (`/cloud/ws`, ticket-authenticated).
  static String get wsUrl => _wsUrlDefine.trim().isEmpty ? prodWsUrl : _wsUrlDefine;
}
