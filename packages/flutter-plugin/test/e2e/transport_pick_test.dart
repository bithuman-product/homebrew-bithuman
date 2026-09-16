// Tier 1 — pickTransport routing contract (no device, no network).
//
// The factory's platform-conditional branches ARE the product contract for
// which audio stack owns a session (docs/TRANSPORT.md):
//   desktop cloud default        → WebSocketTransport  (native VP-IO audio)
//   BITHUMAN_TRANSPORT=webrtc    → WebRTCTransport     (libwebrtc audio) —
//                                  the staged macOS-unification A/B knob
//   local mode (+ gguf)          → LocalConverseTransport, override ignored
//
// `transportOverride` is the injectable twin of the compile-time
// `--dart-define=BITHUMAN_TRANSPORT` (a const can't be varied inside one
// test binary). Constructing each transport is pure Dart — no platform
// channel fires until start() — so these tests stay hermetic.
//
// Run: flutter test test/e2e/transport_pick_test.dart
// CI: .github/workflows/flutter-plugin-tests.yml, every push and PR.
//
// ★ THE SKIPS WERE RE-SCOPED WHEN THIS MOVED HERE, 2026-09-16. All four
// cases were guarded on the host being macOS, which on a Linux CI runner
// means the whole file is adopted and NONE of it is executed — a test that
// exists and does not run. Read against `pickTransport`, that guard is true
// for exactly ONE of them: the factory's single platform branch is
// `localMode && (isMacOS || isIOS)`. The cloud default, the webrtc override
// and the unknown-override fallback have no platform branch at all and now
// run on every host. The LOCAL case keeps its guard, with the branch it
// needs named in the reason instead of a bare boolean.
//
// Apache-2.0; (c) bitHuman.

import 'dart:io' show Platform;

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_avatar_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAvatarPlatform fake;
  late BithumanAvatar avatar;

  setUp(() async {
    fake = FakeAvatarPlatform(textureId: 31);
    fake.install();
    avatar = await BithumanAvatar.load('/fake/avatar.imx');
  });

  tearDown(() => fake.uninstall());

  RealtimeTransport pick({
    bool localMode = false,
    String gguf = '',
    String? override,
  }) {
    return pickTransport(
      apiKey: 'k',
      avatar: avatar,
      model: 'gpt-realtime-mock',
      voice: 'shimmer',
      systemPrompt: 'test',
      vadThreshold: 0,
      localMode: localMode,
      ggufPath: gguf,
      transportOverride: override,
    );
  }

  test('desktop cloud default is the WebSocket transport', () async {
    final t = pick();
    expect(t, isA<WebSocketTransport>());
    await t.dispose();
  });

  test('BITHUMAN_TRANSPORT=webrtc routes desktop cloud to WebRTC', () async {
    final t = pick(override: 'webrtc');
    expect(t, isA<WebRTCTransport>());
    await t.dispose();
  });

  test('unknown override values keep the platform default', () async {
    final t = pick(override: 'carrier-pigeon');
    expect(t, isA<WebSocketTransport>());
    await t.dispose();
  });

  test('local mode wins over the transport override', () {
    final t = pick(
      localMode: true,
      gguf: '/fake/model.gguf',
      override: 'webrtc',
    );
    expect(t, isA<LocalConverseTransport>());
    // No dispose: LocalConverseTransport.dispose() calls stop() →
    // localAudioStop on a session that never started; keep the test inert.
  },
      skip: (Platform.isMacOS || Platform.isIOS)
          ? false
          : 'pickTransport routes LOCAL only on macOS/iOS — the converse brain '
              'binds Apple SpeechAnalyzer; off Apple the factory correctly falls '
              'through to the cloud transport');
}
