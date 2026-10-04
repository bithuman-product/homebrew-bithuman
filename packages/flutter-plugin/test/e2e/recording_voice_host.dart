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
// This one implements the sixteen members of [VoiceHost] and nothing else. It
// imports no bithuman render library, touches no channel, and would compile in a
// pure-Dart (non-Flutter) test. If the voice module ever reaches for a render
// member again, THIS FILE STOPS COMPILING — which is a stronger statement than
// any grep, and the reason the arms that use it are real arms.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:typed_data';

import 'package:bithuman/realtime_transport.dart' show VoiceHost, BithumanAudioInterruption, BithumanPlayout, BithumanModelRejected;

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
  final _interruptions = StreamController<BithumanAudioInterruption>.broadcast();
  final _playout = StreamController<BithumanPlayout>.broadcast();
  final _rejections = StreamController<BithumanModelRejected>.broadcast();
  BithumanModelRejected? _rejection;

  /// The engine refuses the model, as a native host reports it (2.6.29); replayed to later listeners.
  void rejectModel(BithumanModelRejected r) {
    _rejection = r;
    _rejections.add(r);
  }

  /// Push a playout report at the session, as the host would while the voice is heard.
  void emitPlayout(BithumanPlayout p) => _playout.add(p);

  /// Play what [playSpeakerPCM] hands over at 1x (from the moment it is handed, after
  /// [playoutLatency]) and report it as the native hosts do: at the first chunk, every
  /// 100 ms while it plays, at once when everything handed over has played, and after every
  /// [interrupt] (which discards the rest). Off by default.
  bool playsOut = false;
  Duration playoutLatency = const Duration(milliseconds: 100);
  int _fed = 0, _played = 0, _lastReported = -1;
  DateTime? _playFrom, _lastReportAt, _tickAt;
  Timer? _player;

  void _report() {
    _lastReported = _played;
    _lastReportAt = DateTime.now();
    if (!_playout.isClosed) _playout.add(BithumanPlayout(played: _played, fed: _fed));
  }

  void _playTick() {
    final now = DateTime.now();
    final from = _playFrom;
    final last = _tickAt ?? now;
    _tickAt = now;
    if (from == null || now.isBefore(from) || _played >= _fed) return;
    final since = last.isAfter(from) ? last : from;
    _played = (_played + now.difference(since).inMicroseconds * 24 ~/ 1000).clamp(0, _fed);
    final caughtUp = _played >= _fed && _lastReported < _fed;
    if (caughtUp || now.difference(_lastReportAt ?? DateTime(2000)).inMilliseconds >= 100) _report();
  }

  /// Push an audio interruption at the session, as the platform would (a phone call).
  void emitInterruption(BithumanAudioInterruption e) => _interruptions.add(e);

  /// Runs inside [audioStart] (e.g. a call that already holds the audio as the unit starts).
  void Function()? onAudioStart;

  /// [audioStart] throws this after [onAudioStart] (iOS refuses the unit during a call).
  Object? audioStartError;

  /// Push "microphone" PCM at the session, as the platform would.
  void emitMic(Uint8List pcm) => _mic.add(pcm);

  /// Push a brain event, as the local converse path would.
  void emitConverse(Map<dynamic, dynamic> ev) => _converse.add(ev);

  int count(String name) =>
      calls.where((c) => c == name || c.startsWith('$name:')).length;

  Future<void> close() async {
    await _mic.close();
    await _converse.close();
    await _interruptions.close();
    _player?.cancel();
    await _playout.close();
    await _rejections.close();
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
    _fed = 0;
    _played = 0;
    _lastReported = -1;
    _playFrom = null;
    onAudioStart?.call();
    final err = audioStartError;
    if (err != null) throw err;
  }

  @override
  Future<void> audioStop() async {
    calls.add('audioStop');
    _player?.cancel();
    _player = null;
  }

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
    if (playsOut) {
      _fed += pcm24kPcm16le.length ~/ 2;
      if (_played >= _fed - pcm24kPcm16le.length ~/ 2) _playFrom = DateTime.now().add(playoutLatency);
      if (_lastReported < 0) _report();
      _player ??= Timer.periodic(const Duration(milliseconds: 10), (_) => _playTick());
    }
  }

  @override
  Future<void> notifyTurnEnd() async => calls.add('notifyTurnEnd');

  @override
  Future<void> interrupt({String reason = 'app'}) async {
    calls.add('interrupt:$reason');
    if (playsOut) {
      _played = _fed;
      _report();
    }
  }

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
    String replyMode = 'local',
    String? sttDir,
    int maxSentences = 0,
  }) async {
    calls.add('localAudioStart:$ggufPath');
  }

  @override
  Future<void> localReplyText(int id, String text,
          {bool done = false, int result = 0}) async =>
      calls.add('localReplyText:$id:${done ? 'done' : text}');

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

  @override
  Stream<BithumanAudioInterruption> get audioInterruptions {
    calls.add('audioInterruptions');
    return _interruptions.stream;
  }

  @override
  Stream<BithumanPlayout> get speechPlayout {
    calls.add('speechPlayout');
    return _playout.stream;
  }

  @override
  Stream<BithumanModelRejected> get modelRejections {
    calls.add('modelRejections');
    final r = _rejection;
    return r != null ? Stream<BithumanModelRejected>.value(r) : _rejections.stream;
  }
}
