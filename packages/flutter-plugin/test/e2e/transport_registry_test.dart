// Tier 1 — the transport REGISTRY: routing as a decision table, graded on
// every platform from a Linux runner, with no host, no socket and no channel.
//
// ★WHY THIS EXISTS BESIDE transport_pick_test.dart. That file grades
// `pickTransport` — the factory that CONSTRUCTS — so it can only ever ask about
// the platform it is running on. Its one Apple row is `skip`ped on CI to this
// day, and correctly so: the factory reads `Platform.operatingSystem` and a
// Linux runner cannot be macOS. The routing rule and the construction are now
// two functions (`pickTransportDescriptor` decides, `pickTransport` builds), so
// the rule takes the platform as an ARGUMENT and every row of the table is
// graded on every runner — including the two Apple rows nothing has graded
// since the local transport was written.
//
// ★AND IT GRADES THAT THE CAPABILITY RECORD IS LOAD-BEARING. A registry whose
// fields nothing reads is decoration that drifts. `canMute` here is asserted to
// be the SAME OBJECT's field as the instance getter, not merely equal to it.
//
// Run: flutter test test/e2e/transport_registry_test.dart
// CI: .github/workflows/flutter-plugin-tests.yml, every push and PR.
//
// Apache-2.0; (c) bitHuman.

import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_voice_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the registry is well formed', () {
    test('ids are unique and every one resolves to its own row', () {
      final ids = kTransportRegistry.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate transport id');
      for (final d in kTransportRegistry) {
        expect(transportDescriptorFor(d.id), same(d));
        for (final a in d.aliases) {
          expect(transportDescriptorFor(a), same(d));
        }
      }
    });

    test('an unknown name resolves to nothing, and the default is registered',
        () {
      expect(transportDescriptorFor('carrier-pigeon'), isNull);
      expect(transportDescriptorFor(''), isNull);
      expect(kTransportRegistry, contains(kDefaultTransport));
    });

    test('exactly one row needs the on-device brain, and it is Apple-only', () {
      final brainy =
          kTransportRegistry.where((d) => d.requiresLocalBrain).toList();
      expect(brainy, hasLength(1));
      expect(brainy.single, same(kLocalConverseTransport));
      expect(brainy.single.runsOn('macos'), isTrue);
      expect(brainy.single.runsOn('ios'), isTrue);
      expect(brainy.single.runsOn('android'), isFalse);
      expect(brainy.single.runsOn('linux'), isFalse);
      // The two cloud rows run everywhere — that is the "one voice interaction
      // model on every target" claim, as data.
      expect(kWebSocketTransport.runsOn('android'), isTrue);
      expect(kWebRtcTransport.runsOn('android'), isTrue);
    });
  });

  group('the routing decision table', () {
    String pick({
      bool localMode = false,
      String? gguf,
      String? override,
      required String os,
    }) =>
        pickTransportDescriptor(
          localMode: localMode,
          ggufPath: gguf,
          transportOverride: override,
          operatingSystem: os,
        ).id;

    test('cloud default is the WebSocket transport on every platform', () {
      for (final os in ['macos', 'ios', 'android', 'linux', 'windows']) {
        expect(pick(os: os), 'websocket', reason: os);
      }
    });

    test('the webrtc override is honoured on every platform, any case', () {
      for (final os in ['macos', 'ios', 'android']) {
        expect(pick(os: os, override: 'webrtc'), 'webrtc', reason: os);
        expect(pick(os: os, override: 'WebRTC'), 'webrtc', reason: '$os cased');
      }
    });

    test('an unknown override falls back rather than failing', () {
      expect(pick(os: 'macos', override: 'carrier-pigeon'), 'websocket');
    });

    test('local mode with a brain on disk wins over the override — on Apple',
        () {
      // ★ THESE TWO ROWS HAVE NEVER BEEN GRADED ON CI. transport_pick_test's
      // local case is skipped off Apple because the FACTORY reads the real
      // Platform; the RULE takes the platform as an argument, so here they run.
      expect(
          pick(
              os: 'macos',
              localMode: true,
              gguf: '/m.gguf',
              override: 'webrtc'),
          'local');
      expect(pick(os: 'ios', localMode: true, gguf: '/m.gguf'), 'local');
    });

    test('local mode off Apple falls through to a cloud transport', () {
      // The brain binds Apple SpeechAnalyzer. Asking for it on Android must
      // degrade to cloud, never fail.
      expect(pick(os: 'android', localMode: true, gguf: '/m.gguf'), 'websocket');
      expect(
          pick(
              os: 'android',
              localMode: true,
              gguf: '/m.gguf',
              override: 'webrtc'),
          'webrtc');
    });

    test('local mode without a brain on disk is not local mode', () {
      expect(pick(os: 'macos', localMode: true, gguf: null), 'websocket');
      expect(pick(os: 'macos', localMode: true, gguf: ''), 'websocket');
    });

    test('the local transport is not reachable by name — it has no brain path',
        () {
      expect(pick(os: 'macos', override: 'local'), 'websocket');
    });
  });

  group('the factory builds what the rule decided, with no avatar present', () {
    late RecordingVoiceHost host;
    setUp(() => host = RecordingVoiceHost());
    tearDown(() => host.close());

    RealtimeTransport build({String? override}) => pickTransport(
          apiKey: 'k',
          avatar: host, // ← not a BithumanAvatar: the factory never needed one
          model: 'gpt-realtime-mock',
          voice: 'shimmer',
          systemPrompt: 'test',
          vadThreshold: 0,
          transportOverride: override,
          operatingSystem: 'macos',
        );

    test('the chosen transport carries its own registry row', () async {
      final ws = build();
      expect(ws, isA<WebSocketTransport>());
      expect(ws.descriptor, same(kWebSocketTransport));
      await ws.dispose();

      final rtc = build(override: 'webrtc');
      expect(rtc, isA<WebRTCTransport>());
      expect(rtc.descriptor, same(kWebRtcTransport));
      await rtc.dispose();
    });

    test('canMute IS the record, not a copy of it', () async {
      final ws = build();
      expect(ws.canMute, same(ws.descriptor.canMute));
      expect(ws.descriptor.canMute, kWebSocketTransport.canMute);
      await ws.dispose();
    });

    test('the pick is written to the host log — one trace, one clock', () {
      build(override: 'webrtc');
      expect(host.log, hasLength(1));
      expect(host.log.single, contains(kWebRtcTransport.label));
      expect(host.log.single, contains('(webrtc)'));
      expect(host.log.single, contains('macos'));
    });
  });
}
