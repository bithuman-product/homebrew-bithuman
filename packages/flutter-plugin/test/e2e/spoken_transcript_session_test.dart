// Captions in step with the voice, through a REAL BithumanRealtimeSession (2.6.27).
//
// The mock relay bursts a reply (its text and its audio in a few milliseconds, as the real
// relay does for a short reply); the headless host plays the audio at 1x and reports playout
// as the native hosts do. `botTranscriptStream` has the whole text at once — that is what the
// app used to caption from — while `spokenTranscriptStream` releases it as it is heard, and a
// barge-in ends the caption with the words heard so far.
//
// Run: flutter test test/e2e/spoken_transcript_session_test.dart

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

  setUp(() async {
    server = await MockRealtimeServer.start();
    host = RecordingVoiceHost()..playsOut = true;
    BithumanRealtimeSession.debugEndpointOverride = server.url;
    session = BithumanRealtimeSession(apiKey: 'headless-fake-key', avatar: host, model: 'gpt-realtime-mock');
  });

  tearDown(() async {
    try {
      await session.stop();
    } catch (_) {}
    BithumanRealtimeSession.debugEndpointOverride = null;
    await host.close();
    await server.close();
  });

  Future<MockConnection> connect() async {
    final started = session.start(enableMic: false);
    final conn = await server.nextConnection();
    conn.sendSessionCreated();
    await conn.nextEventOfType('session.update');
    await conn.nextEventOfType('response.create');
    await started;
    return conn;
  }

  const text = 'one two three four five six seven eight nine ten eleven twelve';

  test('a burst reply: the text arrives at once, the caption follows the voice', () async {
    final conn = await connect();
    final arrived = StringBuffer();
    final spoken = <(Duration, BithumanSpokenText)>[];
    final sw = Stopwatch()..start();
    final done = Completer<void>();
    session.botTranscriptStream.listen(arrived.write);
    session.spokenTranscriptStream.listen((e) {
      spoken.add((sw.elapsed, e));
      if (e.isFinal && !done.isCompleted) done.complete();
    });
    // 12 words, 12 x 100 ms of audio = 1.2 s of voice, all sent at once.
    await conn.sendResponse(transcript: text, chunks: 12, chunkMs: 100);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(arrived.toString(), text, reason: 'the arrival stream has the whole text at once');
    final early = spoken.isEmpty ? '' : spoken.last.$2.text;
    expect(early.split(' ').where((w) => w.isNotEmpty).length, lessThan(4),
        reason: 'the caption did not run ahead of the voice: "$early" at 150 ms');
    await done.future.timeout(const Duration(seconds: 5));
    final last = spoken.last;
    expect(last.$2.text, text);
    expect(last.$2.isFinal, isTrue);
    expect(last.$2.interrupted, isFalse);
    // 1.2 s of voice after a 100 ms output latency: not complete before it was heard.
    expect(last.$1.inMilliseconds, greaterThanOrEqualTo(1100));
    // Released in pieces, each extending the last.
    expect(spoken.length, greaterThan(4));
    for (var i = 1; i < spoken.length; i++) {
      expect(spoken[i].$2.text.startsWith(spoken[i - 1].$2.text), isTrue);
    }
    expect(host.log.any((l) => l.startsWith('[bhcaption] reply=1') && l.contains(' final')), isTrue);
    expect(host.log.where((l) => l.startsWith('[bhcaption]')).any((l) => l.contains('seven')), isFalse,
        reason: 'the caption log line carries counts, never the words');
  });

  test('barge-in mid-reply: the final caption holds only the words heard', () async {
    final conn = await connect();
    final spoken = <BithumanSpokenText>[];
    final fin = Completer<BithumanSpokenText>();
    session.spokenTranscriptStream.listen((e) {
      spoken.add(e);
      if (e.isFinal && !fin.isCompleted) fin.complete(e);
    });
    await conn.sendResponse(transcript: text, chunks: 12, chunkMs: 100, done: false);
    // ~0.6 s heard (after the 100 ms latency): about half the words.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    conn.sendSpeechStarted();
    final e = await fin.future.timeout(const Duration(seconds: 3));
    expect(e.interrupted, isTrue);
    final n = e.text.split(' ').where((w) => w.isNotEmpty).length;
    expect(n, inInclusiveRange(2, 9), reason: '"${e.text}"');
    expect(text.startsWith(e.text), isTrue);
    // Nothing more for that reply after the cut (the host jumped to `fed` on interrupt).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(spoken.last, same(e));
    expect(host.count('interrupt'), greaterThanOrEqualTo(1));
  });
}
