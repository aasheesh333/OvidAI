// Agent-level image tasks against a fake gateway: batch edits stay
// independent and ordered, single edits stay faithful (preservation clause,
// nearest-ratio size, original pixel size restored), per-image errors never
// abort a batch, and the attachment note carries sizes and ratios.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/image_task.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_task_test.dart' show gatewayCaps;

/// Solid-colour PNG of the given size.
Future<Uint8List> solid(int w, int h, int argb) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = ui.Color(argb),
  );
  final pic = recorder.endRecording();
  final image = await pic.toImage(w, h);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  pic.dispose();
  return bytes;
}

/// ARGB of the centre pixel.
Future<int> centre(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final i = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
  final rgba = data.buffer.asUint8List();
  image.dispose();
  codec.dispose();
  return (rgba[i + 3] << 24) |
      (rgba[i] << 16) |
      (rgba[i + 1] << 8) |
      rgba[i + 2];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory work;
  late ChatSession session;
  late List<ImageInferRequest> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('image-edit-tasks-');
    work = await Directory('${root.path}/work').create();
    SessionLedger.rootOverrideForTest = await Directory(
      '${root.path}/ledger',
    ).create();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    session = ChatSession(
      id: 'imgtasks',
      title: 'Images',
      model: 'test',
      mode: 'auto',
    )..workspaceFolder = work.path;
    app.sessions.add(session);
    app.activeSessionId = session.id;
    AgentService.setRunSessionForTest(session.id);
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.imageCapabilitiesOverrideForTest = gatewayCaps();
    calls = [];
  });

  tearDown(() async {
    AgentService.imageInferOverrideForTest = null;
    AgentService.imageCapabilitiesOverrideForTest = null;
    await SessionLedger.I.close(session.id);
    SessionLedger.rootOverrideForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await root.delete(recursive: true);
  });

  Future<String> write(String name, Uint8List bytes) async {
    final f = File('${work.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  List<Message> outputs() =>
      session.messages.where((m) => m.kind == MsgKind.imageGen).toList();

  test('4 images + "make background white" → 4 independent edit calls, '
      'same instruction, outputs in input order, no merge', () async {
    const colours = [0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffff00];
    final paths = <String>[];
    final inputs = <Uint8List>[];
    for (var i = 0; i < 4; i++) {
      final bytes = await solid(40 + i * 10, 30, colours[i]);
      inputs.add(bytes);
      paths.add(await write('in$i.png', bytes));
    }
    var inFlight = 0, maxInFlight = 0;
    AgentService.imageInferOverrideForTest = (req) async {
      calls.add(req);
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      // Finish out of order: later images return first.
      final index = inputs.indexWhere((b) => _same(b, req.input!));
      await Future<void>.delayed(Duration(milliseconds: 80 - index * 20));
      inFlight--;
      final size = PixelSize.parse(req.size)!;
      return ImageInferOutcome(
        bytes: await solid(
          size.width ~/ 8,
          size.height ~/ 8,
          await centre(req.input!),
        ),
        accounting: 'Request `${req.requestId}`: completed.',
      );
    };
    final result = await AgentService.I.dispatchForTest('edit_images', {
      'paths': paths,
      'prompt': 'make background white',
      'request_id': 'batch-0001',
    });
    expect(calls, hasLength(4));
    for (final c in calls) {
      expect(c.prompt, preservationPrompt('make background white'));
      expect(c.references, isEmpty, reason: 'never merged');
      expect(c.mask, isNull);
      expect(c.input, isNotNull);
      expect(c.requirements?['operation'], 'edit');
    }
    expect(calls.map((c) => c.requestId).toSet(), {
      'batch-0001-1',
      'batch-0001-2',
      'batch-0001-3',
      'batch-0001-4',
    });
    for (final input in inputs) {
      expect(calls.where((c) => _same(c.input!, input)), hasLength(1));
    }
    expect(maxInFlight, inInclusiveRange(2, 3));
    final shown = outputs();
    expect(shown, hasLength(4));
    for (var i = 0; i < 4; i++) {
      final bytes = await File(shown[i].imagePath!).readAsBytes();
      expect(await centre(bytes), colours[i], reason: 'output $i in order');
      final info = await ImageStudio.inspect(bytes);
      expect((info.width, info.height), (40 + i * 10, 30));
    }
    expect(result, startsWith('Edited 4 of 4 images independently'));
    final order = [
      for (var i = 0; i < 4; i++) result.indexOf('${i + 1}. "${paths[i]}"'),
    ];
    expect(order.every((p) => p >= 0), isTrue);
    expect(order, [...order]..sort());
  });

  test('a failing image never aborts the batch', () async {
    final paths = [
      for (var i = 0; i < 3; i++)
        await write('b$i.png', await solid(20, 20, 0xff000000 + i)),
    ];
    AgentService.imageInferOverrideForTest = (req) async {
      calls.add(req);
      if (req.requestId.endsWith('-3')) {
        return const ImageInferOutcome(error: 'image_unavailable HTTP 503');
      }
      return ImageInferOutcome(bytes: await solid(64, 64, 0xffffffff));
    };
    final result = await AgentService.I.dispatchForTest('edit_images', {
      'paths': [paths[0], '${work.path}/missing.png', paths[1], paths[2]],
      'prompt': 'make background white',
      'request_id': 'batch-0002',
    });
    expect(
      calls,
      hasLength(3),
      reason: 'the missing file never reaches the cloud',
    );
    expect(outputs(), hasLength(2));
    expect(result, startsWith('Edited 2 of 4 images'));
    expect(result, contains('2. "${work.path}/missing.png" → Error'));
    expect(result, contains('3. "${paths[1]}" → Error: image_unavailable'));
    expect(result, contains('Only the failed images need a retry'));
  });

  test(
    'single image + "keep same, remove the text" → edit with the '
    'preservation clause, nearest-ratio size, restored to 1080x1350',
    () async {
      final path = await write(
        'poster.png',
        await solid(1080, 1350, 0xff336699),
      );
      AgentService.imageInferOverrideForTest = (req) async {
        calls.add(req);
        final size = PixelSize.parse(req.size)!;
        return ImageInferOutcome(
          bytes: await solid(size.width, size.height, 0xff336699),
        );
      };
      final note = AgentService.I.attachmentContextForTest([
        MessageAttachment(name: 'poster.png', size: 1, path: path),
      ]);
      expect(note, contains('1080x1350 px, 4:5 portrait'));
      final result = await AgentService.I.dispatchForTest('edit_image', {
        'path': path,
        'prompt': 'remove the text',
        'request_id': 'single-0001',
      });
      expect(calls, hasLength(1));
      final call = calls.single;
      expect(call.input, isNotNull, reason: 'an edit, not a generation');
      expect(call.prompt, startsWith('Change ONLY: remove the text. '));
      expect(call.prompt, contains(preservationClause));
      expect(call.size, '1024x1536', reason: '2:3 is the nearest ratio to 4:5');
      final out = await File(outputs().single.imagePath!).readAsBytes();
      final info = await ImageStudio.inspect(out);
      expect((info.width, info.height), (1080, 1350));
      expect(
        result,
        contains('Output 1080x1350 matches the original 1080x1350 (4:5)'),
      );
      expect(result, contains('centre-cropped'));
      expect(result, contains('Model: auto (expected'));
    },
  );

  test(
    'preserve: false sends the instruction alone and keeps the model size',
    () async {
      final path = await write('p.png', await solid(100, 50, 0xff112233));
      AgentService.imageInferOverrideForTest = (req) async {
        calls.add(req);
        return ImageInferOutcome(bytes: await solid(96, 64, 0xff112233));
      };
      final result = await AgentService.I.dispatchForTest('edit_image', {
        'path': path,
        'prompt': 'reimagine as a watercolour',
        'request_id': 'single-0002',
        'preserve': false,
      });
      expect(calls.single.prompt, 'reimagine as a watercolour');
      expect(calls.single.size, '1536x1024');
      final info = await ImageStudio.inspect(
        await File(outputs().single.imagePath!).readAsBytes(),
      );
      expect((info.width, info.height), (96, 64));
      expect(result, contains('Output 96x64'));
    },
  );

  test(
    'generation with a requested ratio is cropped to exactly that ratio',
    () async {
      AgentService.imageInferOverrideForTest = (req) async {
        calls.add(req);
        final size = PixelSize.parse(req.size)!;
        return ImageInferOutcome(
          bytes: await solid(size.width ~/ 4, size.height ~/ 4, 0xffaa0000),
        );
      };
      final result = await AgentService.I.dispatchForTest('generate_image', {
        'prompt': 'a poster of a red fox',
        'aspect_ratio': '4:5',
        'request_id': 'gen-00001',
      });
      expect(calls.single.input, isNull);
      expect(calls.single.size, '1024x1536');
      final info = await ImageStudio.inspect(
        await File(outputs().single.imagePath!).readAsBytes(),
      );
      expect((info.width, info.height), (256, 320));
      expect(info.width / info.height, closeTo(0.8, 1e-9));
      expect(result, contains('exactly 256x320 (4:5)'));
    },
  );

  test('attachment note lists every file with index, path, pixel size and '
      'ratio, and flags several images as a batch edit', () async {
    final a = await write('a.png', await solid(1080, 1350, 0xff000000));
    final b = await write('b.png', await solid(1920, 1080, 0xff000000));
    final t = await write('notes.txt', Uint8List.fromList('hi'.codeUnits));
    final note = AgentService.I.attachmentContextForTest([
      MessageAttachment(name: 'a.png', size: 10, path: a),
      MessageAttachment(name: 'b.png', size: 10, path: b),
      MessageAttachment(name: 'notes.txt', size: 2, path: t),
    ]);
    expect(
      note,
      contains('1. "a.png" (10 B, image 1080x1350 px, 4:5 portrait): "$a"'),
    );
    expect(
      note,
      contains('2. "b.png" (10 B, image 1920x1080 px, 16:9 landscape): "$b"'),
    );
    expect(note, contains('3. "notes.txt" (2 B): "$t"'));
    expect(note, contains('attachments 1, 2 are images'));
    expect(note, contains('edit_images with ALL those paths in this order'));
    expect(note, contains('never merged'));
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
