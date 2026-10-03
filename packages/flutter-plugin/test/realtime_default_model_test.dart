// The realtime session's default model (2.6.36): `gpt-realtime-mini`, the model the relay serves on every
// API secret. Until 2.6.35 it was `gpt-realtime`, which the relay refuses (HTTP 403) on any account not
// entitled to it, so a session that left `model` out never started on a standard secret.
//
// Apache-2.0; (c) bitHuman.

import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2e/recording_voice_host.dart';

void main() {
  test('a session without `model` asks the relay for gpt-realtime-mini', () {
    final s = BithumanRealtimeSession(apiKey: 'secret', avatar: RecordingVoiceHost());
    expect(BithumanRealtimeSession.defaultModel, 'gpt-realtime-mini');
    expect(s.model, 'gpt-realtime-mini');
  });

  test('an explicit model is kept (entitled accounts may pass gpt-realtime)', () {
    final s = BithumanRealtimeSession(apiKey: 'secret', avatar: RecordingVoiceHost(), model: 'gpt-realtime');
    expect(s.model, 'gpt-realtime');
  });
}
