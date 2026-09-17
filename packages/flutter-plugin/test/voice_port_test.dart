// A CONVERSATION WITH NO AVATAR — the arm for the turned import edge.
//
// The owner's acceptance test for the unification is, in his words: "to test
// voice chat we do not even need visuals". Until `VoiceAudioPort` existed that
// sentence was false in Dart: `BithumanRealtimeSession` and all three
// transports took `required BithumanAvatar avatar`, so the only way to reach
// the voice code was to build a native texture first. The product app's own
// voice tests reach it by installing a fake platform channel and calling
// `BithumanAvatar.load('/fake/avatar.imx')` — a render object, standing in for
// a render object, so that a conversation can be tested.
//
// This file passes an object that is not an avatar, does not know what a
// texture is, and never touches a method channel. Every test below is a
// COMPILE-TIME proof as much as a runtime one: put `BithumanAvatar` back on
// those constructors and this file does not compile.
//
// ★THE EXACT PARTITION, MEASURED (scripts/ci/mutate_voice_render_edge.py M5,
// graded per test FILE on 2026-09-16 — not asserted from reading). Dropping the
// `implements VoiceAudioPort` clause reddens exactly four files: this one, and
// the three `test/e2e/` files, which pass a REAL `BithumanAvatar` in and are
// therefore the backward-compatibility half of the same claim. It leaves
// avatar_fit / echo_profile / essence2_catalog green — they never touch voice —
// AND it leaves `transport_registry_test.dart` green, because that file drives
// the whole routing table through `FakeVoicePort` and never names the render
// class at all. An earlier draft of this header claimed the registry test goes
// red here; it does not, and a partition claim nobody ran is the same species of
// defect as the factory docstring this change deleted.
//
// Run: flutter test test/voice_port_test.dart
//
// Apache-2.0; (c) bitHuman.

import 'dart:io' show File;

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';
import 'package:bithuman/realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_voice_port.dart';

void main() {
  group('the edge points render → voice', () {
    // The mechanism, stated as a fact about the bytes. `BithumanAvatar`
    // satisfying the port is what makes the other direction unnecessary; this
    // assignment is the assertion, and it is checked by the compiler.
    test('BithumanAvatar is a VoiceAudioPort', () {
      // The compiler is half the assertion: this upcast is legal only while
      // BithumanAvatar declares the port, so dropping the `implements` clause
      // is a compile error right here. The subtype check is the other half, so
      // the arm reports a value and not merely the absence of an error.
      VoiceAudioPort upcast(BithumanAvatar a) => a;
      expect(upcast, isNotNull);
      // Typed as Object so the analyzer cannot fold the check away: at runtime
      // a List<BithumanAvatar> is a List<VoiceAudioPort> exactly when the
      // subtype relation this arm is about actually holds.
      final Object probe = <BithumanAvatar>[];
      expect(probe is List<VoiceAudioPort>, isTrue);
    });

    // Belt to the compiler's braces: the import edge itself. A type can be
    // satisfied while the import quietly comes back for some other reason, and
    // "voice does not import render" is the claim being made.
    test('no voice library imports the render entry point', () {
      for (final path in const <String>[
        'lib/bithuman_realtime.dart',
        'lib/realtime_transport.dart',
        'lib/openai_webrtc_session.dart',
        'lib/src/voice_protocol.dart',
      ]) {
        final src = File(path).readAsStringSync();
        final offenders =
            src.split('\n').where(_isRenderImport).toList();
        expect(offenders, isEmpty,
            reason: '$path imports the render layer: $offenders');
      }
    });
  });

  group('a conversation with no avatar', () {
    test('a realtime session takes a port that is not an avatar', () {
      final port = FakeVoicePort();
      final session = BithumanRealtimeSession(
        apiKey: 'not-a-key',
        avatar: port,
        model: 'gpt-realtime-mock',
        vadThreshold: 0,
      );
      // Constructing does not touch the port, the network or the platform.
      expect(session.avatar, same(port));
      expect(port.calls, isEmpty);
    });

    test('the on-device transport runs a turn head-first, no engine', () async {
      final port = FakeVoicePort();
      final t = LocalConverseTransport(
        avatar: port,
        ggufPath: '/fake/model.gguf',
        systemPrompt: 'test',
      );
      final seen = <TransportStatus>[];
      final sub = t.statusStream.listen(seen.add);

      await t.start();
      expect(port.calls, contains('localAudioStart(/fake/model.gguf)'));

      // The brain reports itself ready; the transport must open the turn with
      // the welcome-on-connect greeting and hold the "thinking" rim until the
      // greeting has played.
      port.events.add(<String, Object>{'kind': 'ready'});
      await Future<void>.delayed(Duration.zero);
      expect(port.pushedText, hasLength(1));
      expect(port.pushedText.single, contains('Greet them'));

      // A typed turn barges: the caption is flushed and the rim comes back on.
      var interrupts = 0;
      final isub = t.interruptStream.listen((_) => interrupts++);
      t.sendText('hello');
      await Future<void>.delayed(Duration.zero);
      expect(interrupts, 1);
      expect(port.pushedText.last, 'hello');

      // The brain's own transcript reaches the caption stream.
      final captions = <String>[];
      final csub = t.botTranscriptStream.listen(captions.add);
      port.events.add(<String, Object>{'kind': 'bot', 'text': 'hi there'});
      await Future<void>.delayed(Duration.zero);
      expect(captions, <String>['hi there']);

      expect(seen, contains(TransportStatus.connecting));
      expect(seen, contains(TransportStatus.listening));
      expect(seen, contains(TransportStatus.thinking));

      await sub.cancel();
      await isub.cancel();
      await csub.cancel();
      await t.stop();
      expect(port.calls, contains('localAudioStop'));
    });

    test('a mute set before start is re-applied after it', () async {
      final port = FakeVoicePort();
      final t = LocalConverseTransport(
        avatar: port,
        ggufPath: '/fake/model.gguf',
      );
      t.muted = true;
      await t.start();
      // Once when the UI asked (before there was a native mic), once after
      // start() built one — the control must not lie about a restart-while-muted.
      expect(port.muteCalls, <bool>[true, true]);
      expect(t.muted, isTrue);
      await t.stop();
    });
  });
}

/// True for a line that imports or exports the render entry point. Matches the
/// package form and the relative form; a comment mentioning the file is not an
/// import and must not trip this.
bool _isRenderImport(String line) {
  final t = line.trim();
  if (!t.startsWith('import ') && !t.startsWith('export ')) return false;
  return t.contains("'package:bithuman/bithuman.dart'") ||
      t.contains("'bithuman.dart'");
}
