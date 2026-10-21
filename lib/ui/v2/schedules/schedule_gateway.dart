/// The scheduler operations the Schedules screens need.
///
/// The screens never touch `ScheduleClient` directly: the flow injects this
/// seam so a widget test can drive real state without a network, and the app
/// uses [ScheduleClientGateway].
library;

import '../../../core/cloud/schedule_client.dart';

abstract class ScheduleGateway {
  Future<List<ScheduleDto>> list();

  Future<ScheduleDto> create({
    required String title,
    required String description,
    required ScheduleTrigger trigger,
    String? sessionId,
    int maxRetries,
  });

  Future<ScheduleDto> update(
    String id, {
    String? title,
    String? description,
    ScheduleTrigger? trigger,
    String? status,
  });

  Future<void> delete(String id);

  Future<void> runNow(String id);

  Future<List<ScheduleRunDto>> runs(String id);
}

/// The production gateway: the process-wide [ScheduleClient].
class ScheduleClientGateway implements ScheduleGateway {
  const ScheduleClientGateway([this._client]);

  final ScheduleClient? _client;

  ScheduleClient get _scheduleClient => _client ?? ScheduleClient.I;

  @override
  Future<List<ScheduleDto>> list() =>
      _scheduleClient.list(includeCancelled: true);

  @override
  Future<ScheduleDto> create({
    required String title,
    required String description,
    required ScheduleTrigger trigger,
    String? sessionId,
    int maxRetries = 0,
  }) {
    return _scheduleClient.create(
      title: title,
      description: description,
      trigger: trigger,
      sessionId: sessionId,
      maxRetries: maxRetries,
    );
  }

  @override
  Future<ScheduleDto> update(
    String id, {
    String? title,
    String? description,
    ScheduleTrigger? trigger,
    String? status,
  }) {
    return _scheduleClient.update(
      id,
      title: title,
      description: description,
      trigger: trigger,
      status: status,
    );
  }

  @override
  Future<void> delete(String id) => _scheduleClient.delete(id);

  @override
  Future<void> runNow(String id) => _scheduleClient.runNow(id);

  @override
  Future<List<ScheduleRunDto>> runs(String id) => _scheduleClient.runs(id);
}
