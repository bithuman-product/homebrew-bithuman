// Standalone mock realtime server for OUT-OF-PROCESS test targets (Tier 3
// device smoke, or manual app runs against the mock):
//
//   dart run bin/serve.dart [--port 8765]
//
// Then point the app at it:
//   flutter run … --dart-define=BITHUMAN_REALTIME_WS_URL=ws://<host-ip>:8765
//
// Scenario (auto-driven, since no test process is attached): every
// connection gets the greeting exchange, then a response per
// input_audio_buffer.commit, with a barge round if speech is appended
// mid-response. Tier 2 sims use the in-process library instead — richer,
// test-driven scripting.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:io';

import 'package:mock_realtime/mock_realtime.dart';

Future<void> main(List<String> args) async {
  var port = 8765;
  final i = args.indexOf('--port');
  if (i >= 0 && i + 1 < args.length) port = int.parse(args[i + 1]);

  final server = await MockRealtimeServer.start(port: port);
  stdout.writeln('[mock_realtime] listening on ${server.url}');

  // Auto-drive each connection forever.
  while (true) {
    final conn = await server.nextConnection(timeout: const Duration(days: 1));
    stdout.writeln('[mock_realtime] client connected '
        '(auth=${conn.authorization != null ? 'present' : 'none'})');
    unawaited(_drive(conn));
  }
}

Future<void> _drive(MockConnection conn) async {
  try {
    conn.sendSessionCreated();
    while (!conn.isClosed) {
      final ev = await conn.nextEvent(timeout: const Duration(days: 1));
      switch (ev.type) {
        case 'session.update':
          stdout.writeln('[mock_realtime] session.update applied');
        case 'response.create':
          stdout.writeln('[mock_realtime] response.create → scripted reply');
          await conn.sendResponse(
              transcript: 'This is the mock agent speaking.',
              chunks: 10,
              interDelta: const Duration(milliseconds: 60));
        case 'response.cancel':
          stdout.writeln('[mock_realtime] response.cancel → cancelled');
          conn.sendResponseCancelled();
        case 'input_audio_buffer.commit':
          await conn.sendResponse(transcript: 'Reply to your committed turn.');
        default:
          break; // appends and friends — ignore
      }
    }
  } catch (e) {
    stdout.writeln('[mock_realtime] connection ended: $e');
  }
}
