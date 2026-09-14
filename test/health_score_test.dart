import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';

/// Health score must never cross 100 — the screen renders "$score of 100"
/// and a progress ring with `value: score / 100`.
void main() {
  HealthCheck ok(String name, int points) =>
      HealthCheck(name: name, points: points, ok: true, detail: 'ok');

  test('score never exceeds 100 when every check passes', () {
    // Mirrors the installed-path weights in HealthService.runChecks:
    // 20 + 15 + 10*5 + 5 + 5 + 10 + 10 = 115 raw points.
    const report = HealthReport([
      HealthCheck(
        name: 'sandbox',
        points: 20,
        ok: true,
        detail: 'ok',
      ),
      HealthCheck(name: 'bash', points: 15, ok: true, detail: 'ok'),
      HealthCheck(name: 'apt', points: 10, ok: true, detail: 'ok'),
      HealthCheck(name: 'python', points: 10, ok: true, detail: 'ok'),
      HealthCheck(name: 'node', points: 10, ok: true, detail: 'ok'),
      HealthCheck(name: 'git', points: 10, ok: true, detail: 'ok'),
      HealthCheck(name: 'curl', points: 10, ok: true, detail: 'ok'),
      HealthCheck(name: 'rg', points: 5, ok: true, detail: 'ok'),
      HealthCheck(name: 'ssh', points: 5, ok: true, detail: 'ok'),
      HealthCheck(name: 'workspace', points: 10, ok: true, detail: 'ok'),
      HealthCheck(name: 'provider', points: 10, ok: true, detail: 'ok'),
    ]);
    expect(report.score, lessThanOrEqualTo(100));
    expect(report.score, 100);
  });

  test('score still reflects partial failures below the cap', () {
    final report = HealthReport([
      ok('a', 20),
      ok('b', 15),
      const HealthCheck(name: 'c', points: 10, ok: false, detail: 'bad'),
    ]);
    expect(report.score, 35);
  });
}
