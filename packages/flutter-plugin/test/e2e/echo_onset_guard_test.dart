// The relay session's echo-onset guard and speech-ready wait (2.6.21 candidate), driven
// end to end against the hermetic mock realtime server with a VoiceHost that has no
// render in it. See BithumanRealtimeSession.echoOnsetGuard / speechReady.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart';

import 'recording_voice_host.dart';

/// 100 ms of 24 kHz PCM16 at a constant [peak] (a square wave).
Uint8List pcmAt(int peak) {
  final b = ByteData(2400 * 2);
  for (var i = 0; i < 2400; i++) {
    b.setInt16(i * 2, i.isEven ? peak : -peak, Endian.little);
  }
  return b.buffer.asUint8List();
}

int peakOf(String b64) {
  final bytes = base64Decode(b64);
  final d = ByteData.sublistView(bytes);
  var p = 0;
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final v = d.getInt16(i, Endian.little).abs();
    if (v > p) p = v;
  }
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRealtimeServer server;
  late RecordingVoiceHost host;

  setUp(() async {
    server = await MockRealtimeServer.start();
    host = RecordingVoiceHost();
    BithumanRealtimeSession.debugEndpointOverride = server.url;
  });

  tearDown(() async {
    BithumanRealtimeSession.debugEndpointOverride = null;
    await host.close();
    await server.close();
  });

  Future<MockConnection> dial(BithumanRealtimeSession s) async {
    final started = s.start();
    final conn = await server.nextConnection();
    conn.sendSessionCreated();
    await conn.nextEventOfType('session.update');
    await conn.nextEventOfType('response.create');
    await started;
    return conn;
  }

  Future<List<int>> sendAndReadPeaks(MockConnection conn, List<Uint8List> chunks) async {
    final before = conn.eventsOfType('input_audio_buffer.append').length;
    for (final c in chunks) {
      host.emitMic(c);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (conn.eventsOfType('input_audio_buffer.append').length < before + chunks.length) {
      if (DateTime.now().isAfter(deadline)) fail('uplink did not carry every chunk');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return conn
        .eventsOfType('input_audio_buffer.append')
        .skip(before)
        .map((e) => peakOf(e.json['audio'] as String))
        .toList();
  }

  test('while the agent is first audible, echo-level mic chunks go up as silence, '
      'a voice-level chunk goes up intact', () async {
    final s = BithumanRealtimeSession(apiKey: 'k', avatar: host, model: 'm');
    final conn = await dial(s);
    await conn.sendResponse(chunks: 10, chunkMs: 100, done: false); // 1 s of agent audio
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final peaks = await sendAndReadPeaks(conn, [pcmAt(1400), pcmAt(2200), pcmAt(12000)]);
    expect(peaks[0], 0, reason: 'a -27 dBFS residual (09-28 iPhone echo) is silenced');
    expect(peaks[1], 0, reason: 'a -23 dBFS residual is silenced');
    expect(peaks[2], 12000, reason: 'a person talking over the agent still reaches the server');
    await s.stop();
  });

  test('before the agent has spoken, and with the guard off, the uplink is untouched',
      () async {
    final s = BithumanRealtimeSession(
        apiKey: 'k', avatar: host, model: 'm', echoOnsetGuard: Duration.zero);
    final conn = await dial(s);
    expect(await sendAndReadPeaks(conn, [pcmAt(1400)]), [1400]);
    await conn.sendResponse(chunks: 10, chunkMs: 100, done: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await sendAndReadPeaks(conn, [pcmAt(1400)]), [1400],
        reason: 'Duration.zero disables the guard');
    await s.stop();
  });

  test('speechReady holds the dial (and so the greeting) until it completes', () async {
    final ready = Completer<void>();
    final s = BithumanRealtimeSession(
        apiKey: 'k', avatar: host, model: 'm', speechReady: ready.future);
    final started = s.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(host.count('audioStart'), 0, reason: 'nothing starts before the mouth can move');
    ready.complete();
    final conn = await server.nextConnection();
    conn.sendSessionCreated();
    await conn.nextEventOfType('session.update');
    await conn.nextEventOfType('response.create');
    await started;
    expect(host.count('audioStart'), 1);
    await s.stop();
  });
}
