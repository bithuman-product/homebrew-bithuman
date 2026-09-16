// Tier 1 — A FULL VOICE SESSION WITH NO AVATAR IN IT.
//
// A real `BithumanRealtimeSession` (lib/bithuman_realtime.dart) dials a real
// loopback socket served by mock_realtime, and the platform under it is
// `RecordingVoiceHost` — fourteen methods of plain Dart. There is no
// `BithumanAvatar` in this file, no `ai.bithuman.avatar` method channel, no
// mock messenger, no engine and no texture. That is the owner's acceptance test
// for the unified layer, executed: "to test voice chat we do not even need
// visuals".
//
// ★WHAT THIS GRADES THAT test/e2e/realtime_session_mock_test.dart CANNOT. That
// file is the same conversation through `FakeAvatarPlatform`, which mocks the
// method channel UNDERNEATH a real `BithumanAvatar` — so it passes whether or
// not the voice module depends on the render class. These arms compile only
// while the voice module's audio host is a PROTOCOL. Re-typing one constructor
// back to `BithumanAvatar` does not fail a grep here; it fails the compile, and
// this whole file goes red at once.
//
// Run: flutter test test/e2e/headless_voice_host_test.dart
// CI: .github/workflows/flutter-plugin-tests.yml, every push and PR.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';

import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart';

import 'recording_voice_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRealtimeServer server;
  late RecordingVoiceHost host;
  late BithumanRealtimeSession session;
  late List<RealtimeStatus> statuses;
  late StreamSubscription<RealtimeStatus> statusSub;

  setUp(() async {
    server = await MockRealtimeServer.start();
    host = RecordingVoiceHost();
    BithumanRealtimeSession.debugEndpointOverride = server.url;
    session = BithumanRealtimeSession(
      apiKey: 'headless-fake-key', // not a secret — the mock accepts anything
      avatar: host, // ← a VoiceHost that is not an avatar at all
      model: 'gpt-realtime-mock',
      voice: 'shimmer',
      systemPrompt: 'You are a test persona.',
      vadThreshold: 0,
    );
    statuses = [];
    statusSub = session.statusStream.listen(statuses.add);
  });

  tearDown(() async {
    await statusSub.cancel();
    try {
      await session.stop();
    } catch (_) {}
    BithumanRealtimeSession.debugEndpointOverride = null;
    await host.close();
    await server.close();
  });

  Future<MockConnection> connect() async {
    final started = session.start();
    final conn = await server.nextConnection();
    conn.sendSessionCreated();
    await conn.nextEventOfType('session.update');
    await conn.nextEventOfType('response.create'); // connect greeting
    await started;
    return conn;
  }

  test('a voice session starts, speaks and stops with no avatar present',
      () async {
    final conn = await connect();
    final transcript = StringBuffer();
    final tSub = session.botTranscriptStream.listen(transcript.write);

    // The audio unit came up with the cloud-path contract — vadThreshold 0,
    // because barge is server-VAD's job on this path, not a local energy VAD.
    expect(host.calls.where((c) => c.startsWith('audioStart:')).single,
        'audioStart:vad=0,mic=true,agc=true');

    await conn.sendResponse(
        // One transcript word per audio delta (mock_realtime sendResponse), so
        // the word count must equal `chunks` or the tail is never sent.
        transcript: 'Hello no face', chunks: 3, chunkMs: 60);
    await _waitFor(() => statuses.contains(RealtimeStatus.responseDone));
    // The last transcript delta is delivered on its own microtask turn, so it
    // can land a tick after response.done; wait for the text, not the status.
    await _waitFor(() => transcript.toString() == 'Hello no face');

    // 3 x 60 ms @ 24 kHz PCM16 = 3 x 2880 bytes, all of it handed to the host.
    expect(host.count('playSpeakerPCM'), 3);
    expect(host.spokenBytes, 3 * 2880);

    await session.stop();
    expect(host.count('audioStop'), 1);
    expect(host.count('interrupt'), greaterThanOrEqualTo(1),
        reason: 'stop() flushes the host even when the host has no mouth');
    await tSub.cancel();
  });

  test('barge-in reaches a host that has no render in it', () async {
    final conn = await connect();
    await conn.sendResponse(
        chunks: 30,
        chunkMs: 100,
        interDelta: const Duration(milliseconds: 40),
        done: false);
    await _waitFor(() => host.count('playSpeakerPCM') >= 2);
    final before = host.count('interrupt');

    conn.sendSpeechStarted();
    final cancel = await conn.nextEventOfType('response.cancel',
        timeout: const Duration(seconds: 3));
    expect(cancel.type, 'response.cancel');
    await _waitFor(() => host.count('interrupt') > before);

    // The reason string is the barge-in audit trail on a real device log.
    expect(host.calls, contains('interrupt:speech_started'));

    // Stale deltas that were in flight when the cancel landed must not be
    // handed over — a host with a mouth would keep articulating cancelled
    // audio, and one without would keep playing it.
    final frozen = host.count('playSpeakerPCM');
    conn.sendAudioDelta(synthPcm(100));
    conn.sendAudioDelta(synthPcm(100));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(host.count('playSpeakerPCM'), frozen);
  });

  test('the host microphone reaches the provider, and mute makes it deaf',
      () async {
    final conn = await connect();
    await _waitFor(() => host.count('micStream') >= 1);

    host.emitMic(synthPcm(40));
    final append = await conn.nextEventOfType('input_audio_buffer.append',
        timeout: const Duration(seconds: 3));
    expect(append.json['audio'], isA<String>());

    session.muted = true;
    host.emitMic(synthPcm(40));
    host.emitMic(synthPcm(40));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(conn.eventsOfType('input_audio_buffer.append').length, 1,
        reason: 'a muted session must forward nothing from the host mic');
  });
}

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
