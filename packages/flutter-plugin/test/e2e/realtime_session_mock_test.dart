// Tier 1 — BithumanRealtimeSession against the hermetic mock realtime server.
//
// The REAL WebSocket client (lib/bithuman_realtime.dart) dials a REAL local
// socket served by mock_realtime; the native avatar engine is replaced by
// FakeAvatarPlatform. No OpenAI, no network beyond loopback, no secrets.
//
// Covers: the connect contract (session.update GA shape + voice policy),
// the response turn (audio → playSpeakerPCM, transcripts), the lipsync
// pacing governor under burst deltas, barge-in → response.cancel +
// avatar.interrupt + stale-delta drop, the cancel-when-idle guard, mic
// mute policy, and clean stop (no stuck gate).
//
// Run: flutter test test/e2e/realtime_session_mock_test.dart
// CI: .github/workflows/flutter-plugin-tests.yml runs it on every push and PR
// that touches packages/flutter-plugin/**.
//
// ★ PROVENANCE. This harness was written in bithuman-jarvis-app, a repo with
// no .github/ at all, and moved here 2026-09-16 so it runs on every push. It
// had never been executed against this plugin's main: the first run reddened
// two assertions, BOTH because the behaviour under them was deliberately
// changed and nobody re-ran the test — semantic_vad → server_vad (#44) and
// the 1x pacer's deletion (#47). Both are corrected below with the reason.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart';

import 'fake_avatar_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRealtimeServer server;
  late FakeAvatarPlatform fake;
  late BithumanAvatar avatar;
  late BithumanRealtimeSession session;
  late List<RealtimeStatus> statuses;
  late StreamSubscription<RealtimeStatus> statusSub;
  var nextTextureId = 1;

  const testVoice = 'shimmer';
  const testPrompt = 'You are a test persona.';

  setUp(() async {
    server = await MockRealtimeServer.start();
    fake = FakeAvatarPlatform(textureId: nextTextureId++);
    fake.install();
    avatar = await BithumanAvatar.load('/fake/avatar.imx');
    BithumanRealtimeSession.debugEndpointOverride = server.url;
    session = BithumanRealtimeSession(
      apiKey: 'e2e-fake-key', // not a secret — the mock accepts anything
      avatar: avatar,
      model: 'gpt-realtime-mock',
      voice: testVoice,
      systemPrompt: testPrompt,
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
    try {
      await avatar.dispose();
    } catch (_) {}
    fake.uninstall();
    await server.close();
  });

  /// start() the session and consume the connect handshake on the server
  /// side. Returns the live mock connection with session.update (+ the
  /// greeting response.create, per the current macOS WS contract) consumed.
  Future<MockConnection> connect() async {
    final started = session.start();
    final conn = await server.nextConnection();
    conn.sendSessionCreated();
    final update = await conn.nextEventOfType('session.update');
    final sess = update.json['session'] as Map<String, dynamic>;
    expect(sess['type'], 'realtime', reason: 'GA session shape required');
    await conn.nextEventOfType('response.create'); // connect greeting
    await started;
    return conn;
  }

  test('connect contract: GA session.update shape + voice policy', () async {
    final started = session.start();
    final conn = await server.nextConnection();

    // Bearer is forwarded verbatim (the umbrella ephemeral token in prod).
    expect(conn.authorization, 'Bearer e2e-fake-key');

    // First client event MUST be the GA-shape session.update.
    final update = await conn.nextEvent();
    expect(update.type, 'session.update');
    final sess = update.json['session'] as Map<String, dynamic>;
    expect(sess['type'], 'realtime');
    expect(sess['instructions'], testPrompt);
    expect(sess['output_modalities'], ['audio']);
    final audio = sess['audio'] as Map<String, dynamic>;
    final input = audio['input'] as Map<String, dynamic>;
    final output = audio['output'] as Map<String, dynamic>;
    expect((output['voice'] as String?), testVoice);
    expect((output['format'] as Map)['rate'], 24000);
    expect((input['format'] as Map)['rate'], 24000);
    final vad = input['turn_detection'] as Map<String, dynamic>;
    // ★ server_vad, and this assertion is load-bearing. The session shipped
    // `semantic_vad` (eagerness: low) until 2026-09-15 under a comment that
    // said server_vad; an interruption arm measured ZERO `speech_started`
    // in 5 minutes on that build, because semantic_vad waits for a model to
    // judge a COMPLETE turn — so the agent talked over the user. #44 put the
    // onset detector back. The owner's rule is "the moment the user starts
    // talking the agent stops": only an onset detector can serve it.
    expect(vad['type'], 'server_vad',
        reason: 'only server_vad fires speech_started on ONSET (#44)');
    expect(vad['interrupt_response'], true,
        reason: 'barge-in must cancel the agent at the source');
    // The threshold is the DEVICE row in EchoProfile — a measured residual
    // with a falsifier beside it, never a literal in the session JSON.
    expect(vad['threshold'], isA<num>());

    // VOICE POLICY (current WS contract): exactly ONE response.create fires
    // at connect — the warm-greeting that doubles as the connection-validation
    // watchdog probe. NOTE: the WebRTC transport (iOS/Android) has already
    // moved to NO proactive speech (greeting is opt-in dev-only via
    // BITHUMAN_DEV_GREETING); this WS/macOS greeting is a DOCUMENTED policy
    // deviation — see e2e/README.md TODOs. When the WS path aligns, flip this
    // expectation to zero.
    final greeting = await conn.nextEvent();
    expect(greeting.type, 'response.create');

    conn.sendSessionCreated();
    await started;

    // The greeting reply settles the turn; afterwards the client must send
    // NO further response.create on its own (server VAD owns turn-taking).
    await conn.sendResponse(transcript: 'Greetings.', chunks: 3);
    await _waitFor(() => statuses.contains(RealtimeStatus.responseDone));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(conn.eventsOfType('response.create').length, 1,
        reason: 'no proactive response.create beyond the connect greeting');

    // The native audio engine came up with the cloud-path contract:
    // vadThreshold 0 (barge is server-VAD's job, not the local energy VAD).
    final audioStart =
        fake.calls.where((c) => c.method == 'audioStart').toList();
    expect(audioStart, hasLength(1));
    expect((audioStart.single.arguments as Map)['vadThreshold'], 0);
  });

  test('response turn: audio deltas reach the speaker, transcript streams',
      () async {
    final conn = await connect();
    final transcript = StringBuffer();
    final tSub = session.botTranscriptStream.listen(transcript.write);

    await conn.sendResponse(
        transcript: 'Hello there friend', chunks: 3, chunkMs: 60);
    await _waitFor(() => statuses.contains(RealtimeStatus.responseDone));

    expect(fake.callCount('playSpeakerPCM'), 3,
        reason: 'every audio delta must reach the unified speaker+lipsync');
    // 3 × 60 ms @ 24 kHz PCM16 = 3 × 2880 bytes.
    expect(fake.playSpeakerBytes, 3 * 2880);
    expect(transcript.toString(), 'Hello there friend');
    await tSub.cancel();
  });

  test('burst delivery: every byte reaches the speaker, none metered, none lost',
      () async {
    final conn = await connect();

    // Burst 10 × 100 ms instantly — OpenAI's faster-than-realtime delivery
    // (measured 8-28x).
    await conn.sendResponse(chunks: 10, chunkMs: 100, interDelta: Duration.zero);
    await _waitFor(() => fake.callCount('playSpeakerPCM') >= 10,
        timeout: const Duration(seconds: 5));

    // ★ THIS TEST WAS INVERTED WHEN IT WAS ADOPTED, 2026-09-16. It used to
    // assert a 1x pacing governor (spread > 500 ms). #47 DELETED that pacer
    // on every platform: metering the deltas to ~1x made the engine pay its
    // look-ahead in wall clock — the Android 1 s pause and +900 ms of TTFA —
    // while the presenter is clocked by the ENGINE's frames and the engine
    // already bounds its own backlog. So the contract is now the opposite,
    // and it has TWO halves that must be graded together:
    //   (a) nothing is metered — the hand-off is prompt;
    //   (b) nothing is DROPPED. #47 says un-pacing is "SAFE ONLY BECAUSE the
    //       drop-oldest audioQueue cap is gone in the same change (a 42 s
    //       reply arriving in 4.5 s would otherwise lose 37 s of lipsync
    //       audio)". Re-introduce a cap and (b) goes red here.
    final spread = fake.playSpeakerTimes.last
        .difference(fake.playSpeakerTimes.first)
        .inMilliseconds;
    expect(spread, lessThan(500),
        reason: 'the 1x pacer is gone (#47): 1 s of burst audio must hand '
            'over promptly, not be metered out (got ${spread}ms)');
    expect(fake.callCount('playSpeakerPCM'), 10,
        reason: 'every delta of the burst must reach the speaker');
    // 10 × 100 ms @ 24 kHz PCM16 = 10 × 4800 bytes. A cap or a drop-oldest
    // queue anywhere between the socket and the plugin shows up HERE.
    expect(fake.playSpeakerBytes, 10 * 4800,
        reason: 'no audioQueue cap may silently discard lipsync audio');
  });

  test('barge-in: response.cancel + avatar.interrupt + stale deltas dropped',
      () async {
    final conn = await connect();

    // Long in-flight reply…
    await conn.sendResponse(
        chunks: 30,
        chunkMs: 100,
        interDelta: const Duration(milliseconds: 40),
        done: false);
    await _waitFor(() => fake.callCount('playSpeakerPCM') >= 2);
    final interruptsBefore = fake.callCount('interrupt');

    // …user starts talking.
    conn.sendSpeechStarted();
    final cancel = await conn.nextEventOfType('response.cancel',
        timeout: const Duration(seconds: 3));
    expect(cancel.type, 'response.cancel');
    await _waitFor(() => statuses.contains(RealtimeStatus.userSpeaking));
    await _waitFor(() => fake.callCount('interrupt') > interruptsBefore);

    // Stale deltas (in flight when the cancel landed) must NOT reach the
    // speaker — the mouth would keep articulating cancelled audio.
    final frozen = fake.callCount('playSpeakerPCM');
    conn.sendAudioDelta(synthPcm(100));
    conn.sendAudioDelta(synthPcm(100));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(fake.callCount('playSpeakerPCM'), frozen,
        reason: 'post-barge deltas of the cancelled response must be dropped');

    // Turn completes: VAD stop → fresh response flows again.
    conn.sendResponseCancelled();
    conn.sendSpeechStopped();
    await _waitFor(() => statuses.contains(RealtimeStatus.userStopped));
    await conn.sendResponse(transcript: 'Fresh reply', chunks: 2);
    await _waitFor(() => fake.callCount('playSpeakerPCM') == frozen + 2);
    await _waitFor(() => statuses.contains(RealtimeStatus.responseDone));
  });

  test('cancel-when-idle guard: no response.cancel without an active response',
      () async {
    final conn = await connect();
    // Settle the greeting turn → nothing in flight.
    await conn.sendResponse(chunks: 1);
    await _waitFor(() => statuses.contains(RealtimeStatus.responseDone));

    conn.sendSpeechStarted();
    await _waitFor(() => statuses.contains(RealtimeStatus.userSpeaking));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(conn.eventsOfType('response.cancel'), isEmpty,
        reason: 'cancelling with nothing in flight makes OpenAI raise an '
            'error event — the client must gate on _haveActiveResponse');
  });

  test('mic policy: chunks forwarded as appends; muted = deaf', () async {
    final conn = await connect();
    await _waitFor(() => fake.micSink != null,
        timeout: const Duration(seconds: 3));

    // Unmuted: a mic chunk becomes input_audio_buffer.append, verbatim b64.
    final chunk = synthPcm(20); // 20 ms @ 24 kHz = 960 B
    fake.micSink!.success(chunk);
    final append = await conn.nextEventOfType('input_audio_buffer.append',
        timeout: const Duration(seconds: 3));
    expect(append.json['audio'], base64Encode(chunk));

    // Muted: capture keeps running (AEC reference) but nothing is forwarded.
    session.muted = true;
    final appendsBefore =
        conn.eventsOfType('input_audio_buffer.append').length;
    fake.micSink!.success(synthPcm(20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(conn.eventsOfType('input_audio_buffer.append').length,
        appendsBefore, reason: 'muted mic must not reach the server');

    // Unmute restores the flow.
    session.muted = false;
    fake.micSink!.success(synthPcm(20));
    await _waitFor(() =>
        conn.eventsOfType('input_audio_buffer.append').length ==
        appendsBefore + 1);
  });

  test('clean stop: interrupt + audioStop, socket closed, no stuck gate',
      () async {
    final conn = await connect();

    // Stop mid-reply — the worst case for a stuck gate.
    await conn.sendResponse(
        chunks: 20,
        chunkMs: 100,
        interDelta: const Duration(milliseconds: 40),
        done: false);
    await _waitFor(() => fake.callCount('playSpeakerPCM') >= 1);

    await session.stop();

    expect(fake.callCount('interrupt'), greaterThanOrEqualTo(1),
        reason: 'stop() must flush the lipsync queue (no zombie mouth)');
    expect(fake.callCount('audioStop'), 1,
        reason: 'stop() must tear the VP-IO audio engine down');
    await _waitFor(() =>
        statuses.isNotEmpty && statuses.last == RealtimeStatus.closed);
    await conn.done.timeout(const Duration(seconds: 3));

    // Anything still buffered client-side must not reach the speaker.
    final frozen = fake.callCount('playSpeakerPCM');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(fake.callCount('playSpeakerPCM'), frozen);
  });
}

/// Poll [cond] (with real timers — these tests run on the live event loop)
/// until true or [timeout].
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
