import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Strict calendar instant; DateTime.parse alone normalizes invalid fields.
DateTime parseUtilityInstant(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) {
    throw const FormatException(
      'Expected YYYY-MM-DDTHH:MM:SS with optional fraction and explicit Z/offset.',
    );
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  final zone = match[7]!;
  if (year < 1 ||
      date.year != year ||
      date.month != month ||
      date.day != day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      zone != 'Z' &&
          (int.parse(zone.substring(1, 3)) > 14 ||
              int.parse(zone.substring(4)) > 59 ||
              int.parse(zone.substring(1, 3)) == 14 &&
                  int.parse(zone.substring(4)) != 0)) {
    throw const FormatException(
      'Invalid calendar instant or offset (maximum +/-14:00).',
    );
  }
  return DateTime.parse(value).toUtc();
}

/// Local invocation cancellation. The shared NativePluginCapability interface
/// currently has no cancellation parameter; concrete utility callers can pass
/// this token. Cancellation terminates an isolated worker or aborts a request.
class UtilityCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

/// Preflight traverses incrementally, without serializing untrusted objects.
/// Bounds total UTF-16 input, nodes, container width and depth (also cycles).
void checkUtilityInput(dynamic input) {
  var chars = 0;
  var nodes = 0;
  final ancestors = <Object>{};
  void visit(dynamic value, int depth) {
    if (++nodes > 20000 || depth > 64) {
      throw const FormatException(
        'Utility input node/depth limit exceeded: 20000/64.',
      );
    }
    if (value is String) {
      chars += value.length;
      if (chars > 262144) {
        throw const FormatException(
          'Utility input limit exceeded: 262144 code units.',
        );
      }
    } else if (value is Map) {
      if (value.length > 10000) {
        throw const FormatException('Utility container limit exceeded: 10000.');
      }
      if (!ancestors.add(value)) {
        throw const FormatException('Cyclic utility input is unsupported.');
      }
      for (final entry in value.entries) {
        visit(entry.key, depth + 1);
        visit(entry.value, depth + 1);
      }
      ancestors.remove(value);
    } else if (value is List) {
      if (value.length > 10000) {
        throw const FormatException('Utility container limit exceeded: 10000.');
      }
      if (!ancestors.add(value)) {
        throw const FormatException('Cyclic utility input is unsupported.');
      }
      for (final item in value) {
        visit(item, depth + 1);
      }
      ancestors.remove(value);
    } else if (value != null && value is! num && value is! bool) {
      throw const FormatException('Unsupported utility input value.');
    }
  }

  visit(input, 0);
}

void checkUtilityJson(String input) {
  checkUtilityInput(input);
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == '[' || c == '{') {
      if (++depth > 64) {
        throw const FormatException('Utility JSON depth limit exceeded: 64.');
      }
    } else if (c == ']' || c == '}') {
      depth--;
    }
  }
}

String checkUtilityOutput(String output) {
  if (output.length > 1048576) {
    throw const FormatException(
      'Utility output limit exceeded: 1048576 code units.',
    );
  }
  return output;
}

int _activeWorkers = 0;

/// No queue: at most four workers per caller isolate, including late spawns.
/// This is a concurrency/input/output bound, not a VM heap quota.
Future<String> runBoundedUtility(
  FutureOr<String> Function() operation, {
  UtilityCancellation? cancellation,
  int timeoutMs = 2000,
}) async {
  if (kIsWeb) {
    throw UnsupportedError(
      'Bounded utility execution requires native isolates.',
    );
  }
  if (cancellation?.isCancelled ?? false) {
    throw const FormatException('Utility operation cancelled.');
  }
  if (_activeWorkers >= 4) {
    throw const FormatException('Utility concurrency limit exceeded: 4.');
  }
  _activeWorkers++;
  final port = ReceivePort();
  final result = Completer<String>();
  Isolate? worker;
  var spawnSettled = false;
  var cleaned = false;
  var released = false;
  void release() {
    if (!released && spawnSettled && cleaned) {
      released = true;
      _activeWorkers--;
    }
  }

  final subscription = port.listen((dynamic message) {
    if (result.isCompleted) return;
    if (message is List && message.length == 2) {
      if (message[0] == 'ok') {
        result.complete(message[1] as String);
      } else if (message[0] == 'argument') {
        result.completeError(ArgumentError(message[1]));
      } else if (message[0] == 'unsupported') {
        result.completeError(UnsupportedError(message[1] as String));
      } else {
        result.completeError(FormatException(message[1].toString()));
      }
    } else {
      result.completeError(
        StateError('Utility worker exited without a result.'),
      );
    }
  });
  void stop(String message) {
    if (result.isCompleted) return;
    worker?.kill(priority: Isolate.immediate);
    result.completeError(FormatException(message));
  }

  final timer = Timer(
    Duration(milliseconds: timeoutMs),
    () => stop('Utility time limit exceeded: $timeoutMs ms; worker cancelled.'),
  );
  cancellation?.whenCancelled.then((_) => stop('Utility operation cancelled.'));
  unawaited(
    Isolate.spawn(
      _utilityWorker,
      [port.sendPort, operation],
      onError: port.sendPort,
      onExit: port.sendPort,
    ).then(
      (isolate) {
        worker = isolate;
        spawnSettled = true;
        if (result.isCompleted) isolate.kill(priority: Isolate.immediate);
        release();
      },
      onError: (Object e, StackTrace s) {
        spawnSettled = true;
        if (!result.isCompleted) result.completeError(e, s);
        release();
      },
    ),
  );
  try {
    return await result.future;
  } finally {
    timer.cancel();
    worker?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    port.close();
    cleaned = true;
    release();
  }
}

void _utilityWorker(List<dynamic> message) async {
  final port = message[0] as SendPort;
  try {
    final output = await (message[1] as FutureOr<String> Function())();
    port.send(['ok', checkUtilityOutput(output)]);
  } on ArgumentError catch (e) {
    port.send(['argument', e.message.toString()]);
  } on UnsupportedError catch (e) {
    port.send(['unsupported', e.message.toString()]);
  } catch (e) {
    port.send([
      'error',
      e is FormatException ? e.message.toString() : e.toString(),
    ]);
  }
}

/// Deadline covers headers AND collection. On overflow/timeout cancellation
/// aborts the request where supported and cancels the response subscription.
Future<http.Response> boundedUtilityRequest(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String>? headers,
  String? body,
  num timeoutSeconds = 10,
  UtilityCancellation? cancellation,
  int maxBytes = 1048576,
}) async {
  if (!timeoutSeconds.isFinite || timeoutSeconds <= 0 || timeoutSeconds > 300) {
    throw const FormatException(
      'HTTP timeout_seconds must be finite and >0..300.',
    );
  }
  checkUtilityInput([uri.toString(), headers, body]);
  if (cancellation?.isCancelled ?? false) {
    throw const FormatException('Utility operation cancelled.');
  }
  final abort = Completer<void>();
  final result = Completer<http.Response>();
  StreamSubscription<List<int>>? subscription;
  void stop(String message) {
    if (result.isCompleted) return;
    if (!abort.isCompleted) abort.complete();
    unawaited(subscription?.cancel());
    result.completeError(FormatException(message));
  }

  final timer = Timer(
    Duration(microseconds: (timeoutSeconds * 1000000).round()),
    () => stop('HTTP time limit exceeded; request cancelled.'),
  );
  cancellation?.whenCancelled.then((_) => stop('Utility operation cancelled.'));
  final request = http.AbortableRequest(
    method,
    uri,
    abortTrigger: abort.future,
  );
  request.headers.addAll(headers ?? const {});
  if (body != null) request.body = body;
  unawaited(
    client
        .send(request)
        .then(
          (response) {
            if (result.isCompleted) {
              unawaited(response.stream.listen((_) {}).cancel());
              return;
            }
            final bytes = <int>[];
            subscription = response.stream.listen(
              (chunk) {
                if (result.isCompleted) return;
                if (bytes.length + chunk.length > maxBytes) {
                  stop('HTTP response body limit exceeded: $maxBytes bytes.');
                  return;
                }
                bytes.addAll(chunk);
              },
              onError: (Object e, StackTrace s) {
                if (!result.isCompleted) result.completeError(e, s);
              },
              onDone: () {
                if (!result.isCompleted) {
                  result.complete(
                    http.Response.bytes(
                      bytes,
                      response.statusCode,
                      headers: response.headers,
                      request: request,
                    ),
                  );
                }
              },
            );
          },
          onError: (Object e, StackTrace s) {
            if (!result.isCompleted) result.completeError(e, s);
          },
        ),
  );
  try {
    return await result.future;
  } finally {
    timer.cancel();
    await subscription?.cancel();
  }
}
