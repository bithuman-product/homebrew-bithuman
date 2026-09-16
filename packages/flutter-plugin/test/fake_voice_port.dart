// FakeVoicePort — the voice layer's stand-in for an avatar.
//
// Not an avatar, does not know what a texture is, never touches a method
// channel. It exists because `VoiceAudioPort` made it possible: before the
// port, a test of the conversation had to build a render object first.
//
// Shared by voice_port_test.dart and transport_registry_test.dart.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:typed_data' show Uint8List;

import 'package:bithuman/realtime_transport.dart' show VoiceAudioPort;

/// An audio port with no avatar behind it. Records what the voice layer asked
/// for and lets a test drive the on-device brain's event stream by hand.
class FakeVoicePort implements VoiceAudioPort {
  final List<String> calls = <String>[];
  final List<String> pushedText = <String>[];
  final List<bool> muteCalls = <bool>[];
  final StreamController<Map<dynamic, dynamic>> events =
      StreamController<Map<dynamic, dynamic>>.broadcast();

  @override
  Stream<Map<dynamic, dynamic>> get converseEvents => events.stream;

  @override
  Stream<Uint8List> get micStream => Stream<Uint8List>.empty();

  @override
  Future<void> audioStart({
    int vadThreshold = 0,
    bool enableMic = true,
    bool vpioAgc = true,
  }) async =>
      calls.add('audioStart(mic=$enableMic)');

  @override
  Future<void> audioStop() async => calls.add('audioStop');

  @override
  Future<void> playSpeakerPCM(Uint8List pcm24kPcm16le) async =>
      calls.add('playSpeakerPCM(${pcm24kPcm16le.length})');

  @override
  Future<void> notifyTurnEnd() async => calls.add('notifyTurnEnd');

  @override
  Future<void> interrupt({String reason = 'app'}) async =>
      calls.add('interrupt($reason)');

  @override
  Future<void> nativeLog(String line) async {/* the log is not the subject */}

  @override
  Future<void> attachWebrtcRemoteAudio(String trackId) async =>
      calls.add('attachWebrtc($trackId)');

  @override
  Future<void> detachWebrtcRemoteAudio() async => calls.add('detachWebrtc');

  @override
  Future<void> localAudioStart({
    required String ggufPath,
    String? supertonicAssets,
    String? voice,
    int vadThreshold = 0,
    String systemPrompt = '',
  }) async =>
      calls.add('localAudioStart($ggufPath)');

  @override
  Future<void> localAudioStop() async => calls.add('localAudioStop');

  @override
  Future<void> localPushText(String text) async {
    calls.add('localPushText');
    pushedText.add(text);
  }

  @override
  Future<void> localSetMuted(bool muted) async {
    calls.add('localSetMuted($muted)');
    muteCalls.add(muted);
  }
}
