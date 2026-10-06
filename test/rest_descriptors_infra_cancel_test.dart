import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugins/rest_descriptors_infra.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the `cancellation` token handed to the inner REST engine so the
/// wrapper's forwarding contract can be asserted without any network I/O.
class _RecordingRestApiCapability extends RestApiCapability {
  _RecordingRestApiCapability(super.descriptor, {super.client});

  String? seenTool;
  UtilityCancellation? seenCancellation;

  @override
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  }) async {
    seenTool = toolName;
    seenCancellation = cancellation;
    return 'recorded:$toolName';
  }
}

/// A Vercel MCP wrapper whose inner engine is swapped for the recorder via the
/// [buildRestApiCapability] seam.
class _SeamVercelMcpCapability extends VercelMcpCapability {
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) {
    return recorder =
        _RecordingRestApiCapability(descriptor, client: client);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('wrapper forwards a non-null cancellation token to the inner call',
      () async {
    final cap = _SeamVercelMcpCapability();
    await cap.configure({'token': 'vercel-secret'});

    final token = UtilityCancellation();
    final out = await cap.callTool('list_projects', {}, cancellation: token);

    expect(out, 'recorded:list_projects');
    expect(cap.recorder, isNotNull);
    expect(cap.recorder!.seenTool, 'list_projects');
    expect(
      identical(cap.recorder!.seenCancellation, token),
      isTrue,
      reason: 'the exact wrapper token must reach RestApiCapability.callTool',
    );
  });

  test('wrapper passes a null token through when the caller supplies none',
      () async {
    final cap = _SeamVercelMcpCapability();
    await cap.configure({'token': 'vercel-secret'});

    await cap.callTool('list_projects', {});

    expect(cap.recorder, isNotNull);
    expect(cap.recorder!.seenCancellation, isNull);
  });
}
