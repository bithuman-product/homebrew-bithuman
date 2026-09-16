// Test double for the `ai.bithuman.avatar` platform channel.
//
// Lets pure-Dart (Tier 1) tests construct a real [BithumanAvatar] and a real
// [BithumanRealtimeSession] with NO native engine: every method call is
// recorded for assertions, `playSpeakerPCM` timestamps feed the pacing test,
// and the mic EventChannel is backed by a controllable sink so tests can
// inject "microphone" PCM.
//
// Apache-2.0; (c) bitHuman.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAvatarPlatform {
  FakeAvatarPlatform({this.textureId = 1, this.ready = true});

  final int textureId;

  /// What `isReady` reports (elevate warm-up simulation).
  bool ready;

  static const _channel = MethodChannel('ai.bithuman.avatar');

  /// Every method invocation, in order.
  final List<MethodCall> calls = [];

  /// Wall-clock arrival of each playSpeakerPCM call (pacing assertions).
  final List<DateTime> playSpeakerTimes = [];
  int playSpeakerBytes = 0;

  /// Live mic-channel sink once the session subscribes; null before.
  MockStreamHandlerEventSink? micSink;

  List<String> methodNames() => calls.map((c) => c.method).toList();
  int callCount(String method) =>
      calls.where((c) => c.method == method).length;

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'load':
          return textureId;
        case 'frameSize':
          return <String, int>{'width': 720, 'height': 1280};
        case 'isReady':
          return ready;
        case 'playSpeakerPCM':
          playSpeakerTimes.add(DateTime.now());
          final args = call.arguments as Map?;
          playSpeakerBytes += (args?['pcm'] as List?)?.length ?? 0;
          return null;
        case 'setDisplayMode':
          return false;
        case 'pipAvailable':
        case 'pipStart':
          return false;
        default:
          return null; // audioStart/audioStop/interrupt/dispose/pushAudio/…
      }
    });
    // Mic EventChannel: the avatar names it `…mic/<textureId>/<micGen>` and
    // micGen is 1 after the session's single audioStart. Register gens 1-3
    // so restart-style tests keep a live sink.
    for (var gen = 1; gen <= 3; gen++) {
      messenger.setMockStreamHandler(
        EventChannel('ai.bithuman.avatar.mic/$textureId/$gen'),
        MockStreamHandler.inline(
          onListen: (args, events) => micSink = events,
          onCancel: (args) => micSink = null,
        ),
      );
    }
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, null);
    for (var gen = 1; gen <= 3; gen++) {
      messenger.setMockStreamHandler(
        EventChannel('ai.bithuman.avatar.mic/$textureId/$gen'),
        null,
      );
    }
  }
}
