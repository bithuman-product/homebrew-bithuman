// A [VoiceHost] with NO render, NO engine and NO platform channel.
//
// ★WHY THIS FILE IS THE POINT. The owner's acceptance test for the unified
// layer is "to test voice chat we do not even need visuals". Until 2026-09-16
// that sentence was not expressible in Dart: `BithumanRealtimeSession` and all
// three transports took `required BithumanAvatar avatar` — the concrete render
// class — so the only way to run a voice session in a test was
// `FakeAvatarPlatform`, which works by mocking the `ai.bithuman.avatar` METHOD
// CHANNEL underneath a real `BithumanAvatar`. That is a fine double, and it
// stays; but it proves the voice layer only through the render class, and it
// needs the Flutter binding's mock messenger to exist at all.
//
// This one implements the fourteen members of [VoiceHost] and nothing else. It
// imports no bithuman render library, touches no channel, and would compile in a
// pure-Dart (non-Flutter) test. If the voice module ever reaches for a render
// member again, THIS FILE STOPS COMPILING — which is a stronger statement than
// any grep, and the reason the arms that use it are real arms.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:typed_data';

import 'package:bithuman/realtime_transport.dart' show VoiceHost;

class RecordingVoiceHost implements VoiceHost {
  /// Every call, in order, as `name` or `name:arg` — the assertion surface.
  final List<String> calls = <String>[];

  /// Bot PCM handed to the speaker, chunk by chunk.
  final List<Uint8List> spoken = <Uint8List>[];
  int get spokenBytes => spoken.fold(0, (a, b) => a + b.length);

  /// Wall-clock arrival of each [playSpeakerPCM] (pacing assertions).
  final List<DateTime> spokenAt = <DateTime>[];

  /// Native log lines, so a test can read the same trace a device would emit.
  final List<String> log = <String>[];

  final _mic = StreamController<Uint8List>.broadcast();
  final _converse = StreamController<Map<dynamic, dynamic>>.broadcast();

  /// Push "microphone" PCM at the session, as the platform would.
  void emitMic(Uint8List pcm) => _mic.add(pcm);

  /// Push a brain event, as the local converse path would.
  void emitConverse(Map<dynamic, dynamic> ev) => _converse.add(ev);

  int count(String name) =>
      calls.where((c) => c == name || c.startsWith('$name:')).length;

  Future<void> close() async {
    await _mic.close();
    await _converse.close();
  }

  @override
  Future<void> nativeLog(String line) async {
    calls.add('nativeLog');
    log.add(line);
  }

  @override
  Future<void> audioStart(
      {int vadThreshold = 0, bool enableMic = true, bool vpioAgc = true}) async {
    calls.add('audioStart:vad=$vadThreshold,mic=$enableMic,agc=$vpioAgc');
  }

  @override
  Future<void> audioStop() async => calls.add('audioStop');

  @override
  Stream<Uint8List> get micStream {
    calls.add('micStream');
    return _mic.stream;
  }

  @override
  Future<void> playSpeakerPCM(Uint8List pcm24kPcm16le) async {
    calls.add('playSpeakerPCM');
    spoken.add(pcm24kPcm16le);
    spokenAt.add(DateTime.now());
  }

  @override
  Future<void> notifyTurnEnd() async => calls.add('notifyTurnEnd');

  @override
  Future<void> interrupt({String reason = 'app'}) async =>
      calls.add('interrupt:$reason');

  @override
  Future<void> attachWebrtcRemoteAudio(String trackId) async =>
      calls.add('attachWebrtcRemoteAudio:$trackId');

  @override
  Future<void> detachWebrtcRemoteAudio() async =>
      calls.add('detachWebrtcRemoteAudio');

  @override
  Future<void> localAudioStart({
    required String ggufPath,
    String? supertonicAssets,
    String? voice,
    int vadThreshold = 0,
    String systemPrompt = '',
  }) async {
    calls.add('localAudioStart:$ggufPath');
  }

  @override
  Future<void> localAudioStop() async => calls.add('localAudioStop');

  @override
  Future<void> localPushText(String text) async => calls.add('localPushText');

  @override
  Future<void> localSetMuted(bool muted) async =>
      calls.add('localSetMuted:$muted');

  @override
  Stream<Map<dynamic, dynamic>> get converseEvents {
    calls.add('converseEvents');
    return _converse.stream;
  }
}
