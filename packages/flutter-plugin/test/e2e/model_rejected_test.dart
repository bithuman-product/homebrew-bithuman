// MODEL_REJECTED (2.6.29): the on-device engine refusing the model file is ONE typed, terminal
// error on every platform, never a still face and a session that talks on behind it.
//
//   * `BithumanAvatar.load` throws [BithumanModelRejected] when the native load refuses with
//     `MODEL_REJECTED` (Android: the engine refused at create, after one fresh fetch; Apple:
//     Essence 2's be_essence2_create -2 / -4) — the native code and the engine's sentence kept.
//   * A refusal after load (Apple Expression 2: the warm-up could not load the files) arrives
//     as the native push `modelRejected`: [BithumanAvatar.ready] completes, isReady stays
//     false, [BithumanAvatar.modelRejections] emits — and replays to a later listener.
//   * A `BithumanRealtimeSession` on a host that refuses ends with `MODEL_REJECTED` on its
//     errorStream and the paywall's teardown: audio off, streams closed, no restart.
import 'dart:async';

import 'package:bithuman/bithuman.dart';
import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart';

import 'recording_voice_host.dart';

const _outdated = BithumanModelRejected(
  engine: 'essence2',
  nativeCode: -4,
  message: "Essence 2 refused the model file (be_essence2_create -4): Renderer: REFUSED for identity "
      "'A52DHS2219' (b1_fp32): published before the mouth-corner fix; download it again",
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('channel', () {
    const avatarChannel = MethodChannel('ai.bithuman.avatar');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var ready = false;

    Future<void> fromNative(String method, Map<String, Object?> args) async {
      await messenger.handlePlatformMessage(
          avatarChannel.name, avatarChannel.codec.encodeMethodCall(MethodCall(method, args)), null);
    }

    void install({PlatformException? loadError}) {
      messenger.setMockMethodCallHandler(avatarChannel, (call) async {
        switch (call.method) {
          case 'load':
            if (loadError != null) throw loadError;
            return 51;
          case 'frameSize':
            return {'width': 1248, 'height': 704};
          case 'isReady':
            return ready;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(avatarChannel, null));
    }

    test('load throws BithumanModelRejected with the native code and the engine sentence', () async {
      install(loadError: PlatformException(
        code: 'MODEL_REJECTED',
        message: _outdated.message,
        details: {'engine': 'essence2', 'nativeCode': -4},
      ));
      final err = await BithumanAvatar.load('A52DHS2219', engine: 'essence2', apiSecret: 's')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, isA<BithumanModelRejected>());
      final r = err! as BithumanModelRejected;
      expect(r.code, 'MODEL_REJECTED');
      expect(r.engine, 'essence2');
      expect(r.nativeCode, -4);
      expect(r.message, contains('-4'));
      expect(r.message, contains("REFUSED for identity 'A52DHS2219'"));
      expect(r.toString(), startsWith('MODEL_REJECTED: '));
    });

    test('any other load failure is still the platform error it was', () async {
      install(loadError: PlatformException(code: 'load_failed', message: 'UnknownHostException'));
      final err = await BithumanAvatar.load('A52DHS2219', engine: 'essence2', apiSecret: 's')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, isA<PlatformException>());
      expect((err! as PlatformException).code, 'load_failed');
    });

    test('a refusal after load completes ready, keeps isReady false, and replays to late listeners',
        () async {
      ready = false;
      install();
      final avatar = await BithumanAvatar.load('A23WJF0199', engine: 'expression2', apiSecret: 's');
      final early = <BithumanModelRejected>[];
      final sub = avatar.modelRejections.listen(early.add);
      var readyDone = false;
      unawaited(avatar.ready.then((_) => readyDone = true));

      await fromNative('modelRejected', {'textureId': 99, 'engine': 'expression2', 'message': 'not ours'});
      await fromNative('modelRejected', {'textureId': 51, 'engine': 'expression2'}); // no message: not one
      await Future<void>.delayed(Duration.zero);
      expect(early, isEmpty);
      expect(avatar.modelRejection, isNull);

      await fromNative('modelRejected', {
        'textureId': 51,
        'engine': 'expression2',
        'message': 'Expression 2 refused the model files (warm-up): dec_p2 missing',
      });
      await fromNative('modelRejected', {'textureId': 51, 'engine': 'expression2', 'message': 'a second one'});
      await Future<void>.delayed(Duration.zero);
      expect(early.map((r) => r.message), ['Expression 2 refused the model files (warm-up): dec_p2 missing']);
      expect(early.single.nativeCode, isNull);
      expect(readyDone, isTrue, reason: 'nothing waits on an engine that will not start');
      expect(avatar.isReady, isFalse);
      expect(avatar.modelRejection?.engine, 'expression2');

      final late = await avatar.modelRejections.first.timeout(const Duration(seconds: 1));
      expect(late.message, early.single.message, reason: 'a listener after the refusal still hears it');

      await sub.cancel();
      await avatar.dispose();
      await fromNative('modelRejected', {'textureId': 51, 'engine': 'expression2', 'message': 'late'});
      ready = true;
    });
  });

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

    test('MODEL_REJECTED mid-session is terminal: the paywall teardown, whole', () async {
      final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
      final errors = <RealtimeSessionError>[];
      final statuses = <RealtimeStatus>[];
      var errorsDone = false, statusDone = false, spokenDone = false;
      s.errorStream.listen(errors.add, onDone: () => errorsDone = true);
      s.statusStream.listen(statuses.add, onDone: () => statusDone = true);
      s.spokenTranscriptStream.listen((_) {}, onDone: () => spokenDone = true);
      final conn = await dial(s);
      expect(host.count('audioStop'), 0);

      host.rejectModel(_outdated);
      await conn.done.timeout(const Duration(seconds: 3));
      await _waitFor(() => errorsDone && statusDone && spokenDone);

      expect(errors.map((e) => e.code), ['MODEL_REJECTED']);
      expect(errors.single.message, _outdated.message, reason: 'the native code reaches the app');
      expect(s.lastError?.code, 'MODEL_REJECTED');
      expect(statuses.last, RealtimeStatus.error, reason: 'the error is the last status');
      expect(host.count('audioStop'), 1, reason: 'the microphone and speaker are off');
      expect(host.calls.where((c) => c.startsWith('interrupt')), isNotEmpty, reason: 'the reply in flight is cut');
      await s.stop();
      expect(host.count('audioStop'), 1, reason: 'stop() afterwards is a no-op');
      expect(() => s.start(), throwsStateError);
    });

    test('a host that already refused ends a new session at once, before it dials', () async {
      host.rejectModel(_outdated);
      final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
      final errors = <RealtimeSessionError>[];
      s.errorStream.listen(errors.add);
      await s.start();
      await _waitFor(() => errors.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(errors.map((e) => e.code), ['MODEL_REJECTED']);
      expect(server.connections, isEmpty, reason: 'nothing is dialled for an avatar that cannot render');
    });

    test('the relay saying MODEL_REJECTED is terminal too', () async {
      final s = BithumanRealtimeSession(apiKey: 'test-secret', avatar: host);
      final errors = <RealtimeSessionError>[];
      s.errorStream.listen(errors.add);
      final conn = await dial(s);
      conn.send({
        'type': 'error',
        'error': {'code': 'MODEL_REJECTED', 'message': 'the avatar file is out of date'},
      });
      await conn.close(1008);
      await _waitFor(() => errors.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(errors.map((e) => e.code), ['MODEL_REJECTED']);
      expect(server.connections.length, 1, reason: 'no reconnect after a terminal error');
    });
  });
}

Future<void> _waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
