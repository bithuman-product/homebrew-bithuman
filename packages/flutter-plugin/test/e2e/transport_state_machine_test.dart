// Tier 1 — session-state machine: the UI-facing TransportStatus sequence a
// WebSocketTransport derives from server events, end to end over the mock
// realtime server (real client, real loopback socket, fake native engine).
//
// The UI (AvatarScreen) switches chrome purely on this enum, so the exact
// transition sequence IS the product contract:
//
//   closed →(start) connecting → listening →(speech_started) userSpeaking
//     →(speech_stopped) thinking →(response.done) responseDone
//     →(stop) closed
//
// Run: flutter test test/e2e/transport_state_machine_test.dart
//
// Apache-2.0; (c) bitHuman.


import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';
import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart';

import 'fake_avatar_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full conversation drives the documented status sequence', () async {
    final server = await MockRealtimeServer.start();
    final fake = FakeAvatarPlatform(textureId: 77);
    fake.install();
    final avatar = await BithumanAvatar.load('/fake/avatar.imx');
    BithumanRealtimeSession.debugEndpointOverride = server.url;

    final transport = WebSocketTransport(
      apiKey: 'e2e-fake-key',
      avatar: avatar,
      model: 'gpt-realtime-mock',
      voice: 'shimmer',
      systemPrompt: 'test',
      vadThreshold: 0,
    );
    final seen = <TransportStatus>[];
    final sub = transport.statusStream.listen(seen.add);

    try {
      final started = transport.start();
      final conn = await server.nextConnection();
      conn.sendSessionCreated();
      await conn.nextEventOfType('session.update');
      await conn.nextEventOfType('response.create'); // connect greeting
      await started;

      // Greeting reply → responseDone.
      await conn.sendResponse(transcript: 'hi', chunks: 2);
      await _waitForStatus(seen, TransportStatus.responseDone);

      // User turn: VAD start/stop → userSpeaking, thinking.
      conn.sendSpeechStarted();
      await _waitForStatus(seen, TransportStatus.userSpeaking);
      conn.sendSpeechStopped();
      await _waitForStatus(seen, TransportStatus.thinking);

      // Reply to the turn → responseDone again.
      await conn.sendResponse(transcript: 'answer', chunks: 2);
      await _waitForStatus(
          seen, TransportStatus.responseDone, expectCount: 2);

      await transport.stop();
      await _waitForStatus(seen, TransportStatus.closed);

      // Exact ordered contract (collapse consecutive duplicates first —
      // stream timing may re-emit a state).
      final collapsed = <TransportStatus>[];
      for (final s in seen) {
        if (collapsed.isEmpty || collapsed.last != s) collapsed.add(s);
      }
      expect(
        collapsed,
        [
          TransportStatus.connecting,
          TransportStatus.listening,
          TransportStatus.responseDone,
          TransportStatus.userSpeaking,
          TransportStatus.thinking,
          TransportStatus.responseDone,
          TransportStatus.closed,
        ],
        reason: 'UI chrome switches on exactly this sequence',
      );
    } finally {
      await sub.cancel();
      try {
        await transport.stop();
      } catch (_) {}
      await transport.dispose();
      BithumanRealtimeSession.debugEndpointOverride = null;
      try {
        await avatar.dispose();
      } catch (_) {}
      fake.uninstall();
      await server.close();
    }
  });
}

Future<void> _waitForStatus(List<TransportStatus> seen, TransportStatus want,
    {int expectCount = 1,
    Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (seen.where((s) => s == want).length < expectCount) {
    if (DateTime.now().isAfter(deadline)) {
      fail('status $want (×$expectCount) not seen within $timeout; got $seen');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
