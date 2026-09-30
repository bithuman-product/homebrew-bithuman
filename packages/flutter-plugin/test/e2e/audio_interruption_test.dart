// A phone call taking the session's sound (2.6.25): the session ends itself, so nothing more
// is billed, and says why. Until 2.6.25 an iPhone call answered from its banner paused the
// audio while the realtime session stayed open, billed, under the call.
//
// Arms:
//   * `began` → the event is on interruptionStream, then the session stops: the audio unit
//     is stopped, the relay socket closes, status `closed`, endedByInterruption says why;
//   * endOnAudioInterruption: false → forwarded only, the session stays open;
//   * `ended` never stops a session;
//   * a call that already holds the audio as the unit starts → no dial at all (and on iOS, where
//     the unit then refuses to start, no error either);
//   * BithumanAvatar routes the native push `audioInterruption` to the avatar it names.
//
// The session arms run against the hermetic mock relay with a VoiceHost that has no render;
// the channel arm mocks `ai.bithuman.avatar`. Apache-2.0; (c) bitHuman.

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart';

import 'recording_voice_host.dart';

const _call = BithumanAudioInterruption(began: true, reason: 'call');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('session', () {
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

    test('a phone call ends the session: event first, then closed, socket gone', () async {
      final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
      final seen = <String>[];
      s.interruptionStream.listen((e) => seen.add('interruption:${e.reason}'));
      s.statusStream.listen((st) => seen.add('status:${st.name}'));
      final conn = await dial(s);
      expect(host.count('audioStop'), 0);

      host.emitInterruption(_call);
      await conn.done.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(host.count('audioStop'), 1, reason: 'the audio unit is stopped');
      expect(host.calls, contains('interrupt:stop'));
      expect(s.endedByInterruption?.isCall, isTrue);
      final i = seen.indexOf('interruption:call');
      final c = seen.lastIndexOf('status:closed');
      expect(i, greaterThanOrEqualTo(0));
      expect(c, greaterThan(i), reason: 'the app hears why before it hears closed: $seen');
      expect(host.log.any((l) => l.contains('[bhinterrupt] BEGAN reason=call')), isTrue);
    });

    test('endOnAudioInterruption: false forwards the event and keeps the session', () async {
      final s = BithumanRealtimeSession(
          apiKey: 'test-secret', avatar: host, endOnAudioInterruption: false);
      final got = <BithumanAudioInterruption>[];
      s.interruptionStream.listen(got.add);
      final conn = await dial(s);

      host.emitInterruption(_call);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(got.single.began, isTrue);
      expect(host.count('audioStop'), 0);
      expect(conn.isClosed, isFalse);
      expect(s.endedByInterruption, isNull);
      await s.stop();
    });

    test('an end of an interruption never stops a session', () async {
      final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
      final conn = await dial(s);
      host.emitInterruption(
          const BithumanAudioInterruption(began: false, reason: 'call', shouldResume: true));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.count('audioStop'), 0);
      expect(conn.isClosed, isFalse);
      await s.stop();
    });

    test('a call already holding the audio as the unit starts: no dial', () async {
      host.onAudioStart = () => host.emitInterruption(_call);
      final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
      final statuses = <RealtimeStatus>[];
      s.statusStream.listen(statuses.add);
      await s.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(server.connections, isEmpty, reason: 'the relay was never dialled');
      expect(host.count('audioStop'), 1);
      expect(statuses, isNot(contains(RealtimeStatus.open)));
      expect(s.endedByInterruption?.isCall, isTrue);
    });
  });

  test('iOS refuses the unit during a call after reporting it: the start ends quietly', () async {
    final server = await MockRealtimeServer.start();
    final host = RecordingVoiceHost()
      ..audioStartError = PlatformException(code: 'AUDIO_START_FAILED', message: 'a phone call holds the audio');
    host.onAudioStart = () => host.emitInterruption(_call);
    BithumanRealtimeSession.debugEndpointOverride = server.url;
    addTearDown(() async {
      BithumanRealtimeSession.debugEndpointOverride = null;
      await host.close();
      await server.close();
    });
    final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
    final statuses = <RealtimeStatus>[];
    s.statusStream.listen(statuses.add);
    await s.start(); // must not throw
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(statuses, isNot(contains(RealtimeStatus.error)));
    expect(server.connections, isEmpty);
    expect(s.endedByInterruption?.isCall, isTrue);
  });

  group('channel', () {
    const avatarChannel = MethodChannel('ai.bithuman.avatar');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Future<void> fromNative(Map<String, Object?> args) async {
      await messenger.handlePlatformMessage(avatarChannel.name,
          avatarChannel.codec.encodeMethodCall(MethodCall('audioInterruption', args)), null);
    }

    test('the native push reaches the avatar it names, and only that one', () async {
      messenger.setMockMethodCallHandler(avatarChannel, (call) async {
        switch (call.method) {
          case 'load':
            return 41;
          case 'frameSize':
            return {'width': 416, 'height': 720};
          case 'isReady':
            return true;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(avatarChannel, null));

      final avatar = await BithumanAvatar.load('A01TEST001', engine: 'expression2', apiSecret: 's');
      final got = <BithumanAudioInterruption>[];
      final sub = avatar.audioInterruptions.listen(got.add);

      await fromNative({'textureId': 41, 'state': 'began', 'reason': 'call', 'shouldResume': false});
      await fromNative({'textureId': 99, 'state': 'began', 'reason': 'call'}); // another avatar
      await fromNative({'textureId': 41, 'state': 'paused'}); // not an interruption
      await fromNative({'textureId': 41, 'state': 'ended', 'reason': 'call', 'shouldResume': true});
      await Future<void>.delayed(Duration.zero);

      expect(got.length, 2);
      expect(got[0].began && got[0].isCall, isTrue);
      expect(got[1].began, isFalse);
      expect(got[1].shouldResume, isTrue);

      await sub.cancel();
      await avatar.dispose();
      // After dispose a late push is dropped, never thrown.
      await fromNative({'textureId': 41, 'state': 'began', 'reason': 'system'});
    });
  });
}
