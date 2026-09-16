// THE ROUTING TABLE, GRADED FOR EVERY TARGET FROM ANY MACHINE.
//
// Which transport owns a session is a product contract with four named
// outcomes (docs/TRANSPORT.md). The only test of it that existed is in the
// product app — `test/e2e/transport_pick_test.dart` — it is written
// `skip: !Platform.isMacOS`, and the product app has no CI, so on the hardware
// that grades this repository it decided nothing about any target, and off it
// it decided nothing at all. A path that has never been exercised is not a path
// that works.
//
// The decision now lives in `kTransportRegistry` as data, and the platform
// arrives in `TransportRequest` as a field rather than being read from the
// middle of the factory — so the whole matrix is gradeable on the ubuntu runner
// that runs `flutter test` here.
//
// ★WHAT THIS DOES NOT CLAIM. Resolving a descriptor is not the same as
// building a transport. The last group below builds the real objects through
// `pickTransport` on THIS machine, which is the only leg where "the table said
// websocket and a WebSocketTransport came back" is checked end to end.
//
// Run: flutter test test/transport_registry_test.dart
//
// Apache-2.0; (c) bitHuman.

import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_voice_port.dart';

TransportRequest req({
  bool localMode = false,
  bool hasLocalBrain = false,
  bool platformHasLocalBrain = false,
  String override = '',
}) =>
    TransportRequest(
      localMode: localMode,
      hasLocalBrain: hasLocalBrain,
      platformHasLocalBrain: platformHasLocalBrain,
      override: override,
    );

void main() {
  group('the registry is well formed', () {
    test('slugs are unique and resolvable', () {
      final slugs = kTransportRegistry.map((d) => d.slug).toList();
      expect(slugs.toSet(), hasLength(slugs.length));
      for (final s in slugs) {
        expect(transportDescriptorFor(s)?.slug, s);
      }
      expect(transportDescriptorFor('carrier-pigeon'), isNull);
    });

    // pickTransportDescriptor's fallback return is unreachable only while this
    // holds. Asserting it is cheaper than trusting it.
    test('the last entry is unconditional, and no earlier one is', () {
      final tail = kTransportRegistry.last;
      final everything = <TransportRequest>[
        req(),
        req(override: 'webrtc'),
        req(localMode: true, hasLocalBrain: true, platformHasLocalBrain: true),
        req(localMode: true),
        req(override: 'nonsense'),
      ];
      for (final r in everything) {
        expect(tail.selects(r), isTrue, reason: 'the tail must accept anything');
      }
      for (final d in kTransportRegistry.take(kTransportRegistry.length - 1)) {
        expect(everything.any((r) => !d.selects(r)), isTrue,
            reason: '${d.slug} accepts everything — it would shadow the tail');
      }
    });
  });

  group('the routing contract, for every target', () {
    test('cloud default on every platform is the WebSocket transport', () {
      // The shipped path on Android, iOS and macOS alike. A docstring in this
      // file's subject asserted the opposite about Android for months.
      for (final platformHasLocalBrain in <bool>[true, false]) {
        expect(
          pickTransportDescriptor(
                  req(platformHasLocalBrain: platformHasLocalBrain))
              .slug,
          'websocket',
        );
      }
    });

    test('BITHUMAN_TRANSPORT=webrtc routes the cloud session to WebRTC', () {
      expect(pickTransportDescriptor(req(override: 'webrtc')).slug, 'webrtc');
    });

    test('an unknown override keeps the default — it is not an error', () {
      expect(
        pickTransportDescriptor(req(override: 'carrier-pigeon')).slug,
        'websocket',
      );
    });

    test('local mode wins over the transport override', () {
      expect(
        pickTransportDescriptor(req(
          localMode: true,
          hasLocalBrain: true,
          platformHasLocalBrain: true,
          override: 'webrtc',
        )).slug,
        'local',
      );
    });

    test('local mode without a brain path falls back to cloud', () {
      // The old factory required `ggufPath != null && ggufPath.isNotEmpty`;
      // this is that clause, and it is the one a caller trips by shipping a
      // LOCAL toggle before the model has downloaded.
      expect(
        pickTransportDescriptor(
                req(localMode: true, platformHasLocalBrain: true))
            .slug,
        'websocket',
      );
    });

    test('local mode on a platform without the brain falls back to cloud', () {
      // Android today: the on-device brain binds an Apple-only API, so the
      // toggle must not route there. Graded here on Linux, which is the point.
      expect(
        pickTransportDescriptor(req(localMode: true, hasLocalBrain: true)).slug,
        'websocket',
      );
    });
  });

  group('the capability record matches the transport it describes', () {
    // A descriptor field that drifts from the object is worse than no field:
    // the UI hides its mute control off `canMute`, so a lie here is a control
    // that does not work or a control that is missing.
    test('canMute agrees with the built transport', () {
      final port = FakeVoicePort();
      final built = <String, RealtimeTransport>{
        'websocket': WebSocketTransport(
          apiKey: 'k',
          avatar: port,
          model: 'm',
          voice: 'v',
          systemPrompt: '',
          vadThreshold: 0,
        ),
        'webrtc': WebRTCTransport(
          apiKey: 'k',
          avatar: port,
          model: 'm',
          voice: 'v',
          systemPrompt: '',
          vadThreshold: 0,
        ),
        'local': LocalConverseTransport(
          avatar: port,
          ggufPath: '/fake/model.gguf',
        ),
      };
      for (final d in kTransportRegistry) {
        expect(built[d.slug]!.canMute, d.canMute,
            reason: '${d.slug}: descriptor says canMute=${d.canMute}');
      }
      // Constructing touched nothing — no channel, no socket, no permission.
      expect(port.calls, isEmpty);
    });
  });

  group('pickTransport builds what the table named, on this machine', () {
    // The end-to-end leg. This runner is Linux, so the branch it exercises is
    // the cloud default — the one every Android device also takes.
    RealtimeTransport pick({String? override, bool localMode = false}) =>
        pickTransport(
          apiKey: 'k',
          avatar: FakeVoicePort(),
          model: 'gpt-realtime-mock',
          voice: 'shimmer',
          systemPrompt: 'test',
          vadThreshold: 0,
          localMode: localMode,
          transportOverride: override,
        );

    test('the default is a WebSocketTransport', () {
      expect(pick(), isA<WebSocketTransport>());
    });

    test('the override builds a WebRTCTransport', () {
      expect(pick(override: 'webrtc'), isA<WebRTCTransport>());
    });

    test('an unknown override builds the default', () {
      expect(pick(override: 'carrier-pigeon'), isA<WebSocketTransport>());
    });
  });
}
