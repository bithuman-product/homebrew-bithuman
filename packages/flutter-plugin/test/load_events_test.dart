// BithumanAvatar.loadEvents / cancelLoad — the Dart half of the Android load
// progress channel (android/…/LoadEvents.kt).
//
// These arms pin:
//
//   * ADDITIVE: nothing is installed on `ai.bithuman.avatar/load` until someone
//     listens — not by importing the package, not by reading the getter, not by
//     `load` — so an app that never listens (or keeps its own handler on that
//     channel) sees no change;
//   * the wire the native side sends, `event {code, stage, done?, total?,
//     cached?, ms}`, decodes into typed events in order, and every event is
//     ANSWERED (the native queue sends the next one only after an answer);
//   * an unknown stage from a newer native side is dropped but still answered;
//   * the handler stays after the last listener leaves, so answers keep coming;
//   * `cancelLoad` sends `cancel {code}` and reads its bool, and is false where
//     there is nothing to cancel (no native handler: iOS, macOS, older Android);
//   * a cancelled load reaches the caller as PlatformException `load_cancelled`.
//
// The first test must stay first: the handler is installed once per isolate.
// No device, no engine: both channels are mocked. Apache-2.0; (c) bitHuman.

import 'package:bithuman/bithuman.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _load = MethodChannel('ai.bithuman.avatar/load');
const _avatar = MethodChannel('ai.bithuman.avatar');

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// The native side invokes [method] on the load channel. Returns Dart's raw
/// answer: null when no handler is installed.
Future<ByteData?> _fromNative(String method, Object? args) => _messenger
    .handlePlatformMessage(_load.name, _load.codec.encodeMethodCall(MethodCall(method, args)), null);

/// One event exactly as LoadEvents.kt builds it.
Map<String, Object> _event(String code, String stage, int ms, [Map<String, Object> extra = const {}]) =>
    {'code': code, 'stage': stage, 'ms': ms, ...extra};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nothing is installed on the load channel until someone listens', () async {
    _messenger.setMockMethodCallHandler(_avatar, (call) async {
      switch (call.method) {
        case 'load':
          return 7;
        case 'frameSize':
          return {'width': 416, 'height': 720};
        case 'isReady':
          return true;
      }
      return null;
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_avatar, null));

    final stream = BithumanAvatar.loadEvents; // reading the getter installs nothing
    expect(stream.isBroadcast, isTrue);
    final avatar = await BithumanAvatar.load('A01TEST001', engine: 'expression2', apiSecret: 's');
    expect(avatar.textureId, 7);

    expect(await _fromNative('event', _event('A01TEST001', 'fetch', 5, {'done': 1, 'total': 2})), isNull,
        reason: 'no Dart handler yet: the message is left unanswered, exactly as before this API');
    await avatar.dispose();
  });

  test('a listener gets typed events in order, and every event is answered', () async {
    final got = <BithumanLoadEvent>[];
    final sub = BithumanAvatar.loadEvents.listen(got.add);
    addTearDown(sub.cancel);

    final wire = [
      _event('A68HQB7720', 'fetch', 310, {'done': 262144, 'total': 160400000}),
      _event('A68HQB7720', 'fetch', 435, {'done': 3407872, 'total': 160400000}),
      _event('A68HQB7720', 'fetch', 29120, {'done': 160400000, 'total': 160400000}),
      _event('A68HQB7720', 'fetched', 29131, {'cached': false}),
      _event('A68HQB7720', 'prepare', 29131),
      _event('A68HQB7720', 'prepared', 43050),
    ];
    for (final e in wire) {
      final answer = await _fromNative('event', e);
      expect(answer, isNotNull, reason: 'the native side sends the next event only after an answer');
      expect(_load.codec.decodeEnvelope(answer!), isNull);
    }
    await pumpEventQueue();

    expect(got.map((e) => e.stage), [
      BithumanLoadStage.fetch,
      BithumanLoadStage.fetch,
      BithumanLoadStage.fetch,
      BithumanLoadStage.fetched,
      BithumanLoadStage.prepare,
      BithumanLoadStage.prepared,
    ]);
    expect(got.every((e) => e.code == 'A68HQB7720'), isTrue);
    expect(got[1].done, 3407872);
    expect(got[1].total, 160400000);
    expect(got[2].fraction, 1.0);
    expect(got[3].cached, isFalse);
    expect(got[3].done, isNull);
    expect(got[5].elapsed, const Duration(milliseconds: 43050));
  });

  test('a cached open, and two codes interleaved: filtering on code is the caller\'s', () async {
    final got = <BithumanLoadEvent>[];
    final sub = BithumanAvatar.loadEvents.where((e) => e.code == 'B').listen(got.add);
    addTearDown(sub.cancel);

    await _fromNative('event', _event('A', 'fetch', 100, {'done': 10, 'total': 100}));
    await _fromNative('event', _event('B', 'fetched', 12, {'cached': true}));
    await _fromNative('event', _event('A', 'fetch', 225, {'done': 20, 'total': 100}));
    await _fromNative('event', _event('B', 'prepare', 12));
    await pumpEventQueue();

    expect(got.map((e) => '${e.code} ${e.stage.name} ${e.cached}'), ['B fetched true', 'B prepare false']);
  });

  test('an unknown stage or a malformed event is dropped, and still answered', () async {
    final got = <BithumanLoadEvent>[];
    final sub = BithumanAvatar.loadEvents.listen(got.add);
    addTearDown(sub.cancel);

    for (final bad in <Object?>[
      _event('A', 'unpack', 3), // a stage a newer native side might add
      {'stage': 'fetch', 'done': 1, 'total': 2}, // no code
      {'code': '', 'stage': 'fetch'},
      {'code': 'A'},
      'not a map',
      null,
    ]) {
      expect(await _fromNative('event', bad), isNotNull);
    }
    expect(await _fromNative('somethingElse', null), isNotNull);
    await pumpEventQueue();
    expect(got, isEmpty);
  });

  test('the handler stays when the last listener leaves, so answers keep coming', () async {
    final sub = BithumanAvatar.loadEvents.listen((_) {});
    await sub.cancel();
    expect(await _fromNative('event', _event('A', 'prepared', 900)), isNotNull);

    final got = <BithumanLoadEvent>[];
    final again = BithumanAvatar.loadEvents.listen(got.add);
    addTearDown(again.cancel);
    await _fromNative('event', _event('A', 'prepare', 10));
    await pumpEventQueue();
    expect(got.single.stage, BithumanLoadStage.prepare);
  });

  group('cancelLoad', () {
    tearDown(() => _messenger.setMockMethodCallHandler(_load, null));

    test('sends cancel {code} and reads the answer', () async {
      final calls = <MethodCall>[];
      var answer = true;
      _messenger.setMockMethodCallHandler(_load, (call) async {
        calls.add(call);
        return answer;
      });
      expect(await BithumanAvatar.cancelLoad('A68HQB7720'), isTrue);
      answer = false;
      expect(await BithumanAvatar.cancelLoad('A68HQB7720'), isFalse);
      expect(calls.map((c) => c.method), ['cancel', 'cancel']);
      expect(calls.first.arguments, {'code': 'A68HQB7720'});
    });

    test('a null answer reads as false', () async {
      _messenger.setMockMethodCallHandler(_load, (call) async => null);
      expect(await BithumanAvatar.cancelLoad('A'), isFalse);
    });

    test('is false where nothing can be cancelled (no native handler: iOS, macOS, older Android)', () async {
      _messenger.setMockMethodCallHandler(_load, null);
      expect(await BithumanAvatar.cancelLoad('A'), isFalse);
    });

    test('an empty code cancels nothing and calls nothing', () async {
      var called = false;
      _messenger.setMockMethodCallHandler(_load, (call) async => called = true);
      expect(await BithumanAvatar.cancelLoad(''), isFalse);
      expect(called, isFalse);
    });
  });

  test('a cancelled load reaches the caller as PlatformException load_cancelled', () async {
    _messenger.setMockMethodCallHandler(_avatar, (call) async {
      if (call.method == 'load') {
        throw PlatformException(code: 'load_cancelled', message: 'fetch of A68HQB7720 cancelled');
      }
      return null;
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_avatar, null));
    await expectLater(
      BithumanAvatar.load('A68HQB7720', engine: 'expression2', apiSecret: 's'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'load_cancelled')),
    );
  });

  group('BithumanLoadEvent.fromMap', () {
    test('decodes every field', () {
      final e = BithumanLoadEvent.fromMap(
          {'code': 'A', 'stage': 'fetch', 'done': 50, 'total': 200, 'ms': 1500})!;
      expect(e.code, 'A');
      expect(e.stage, BithumanLoadStage.fetch);
      expect(e.done, 50);
      expect(e.total, 200);
      expect(e.fraction, 0.25);
      expect(e.cached, isFalse);
      expect(e.elapsed, const Duration(milliseconds: 1500));
      expect(e.toString(), 'BithumanLoadEvent(A fetch 50/200 +1500 ms)');
    });

    test('every stage name the native side sends', () {
      for (final s in ['fetch', 'fetched', 'prepare', 'prepared']) {
        expect(BithumanLoadEvent.fromMap({'code': 'A', 'stage': s})?.stage.name, s);
      }
    });

    test('fraction: clamped, and null without an exact total', () {
      BithumanLoadEvent at(Object? done, Object? total) =>
          BithumanLoadEvent.fromMap({'code': 'A', 'stage': 'fetch', 'done': done, 'total': total})!;
      expect(at(300, 200).fraction, 1.0);
      expect(at(0, 200).fraction, 0.0);
      expect(at(10, 0).fraction, isNull);
      expect(at(10, null).fraction, isNull);
      expect(at(null, 200).fraction, isNull);
      expect(at(10.0, 40.0).fraction, 0.25); // any num decodes
    });

    test('cached only when the native side says true', () {
      expect(BithumanLoadEvent.fromMap({'code': 'A', 'stage': 'fetched', 'cached': true})!.cached, isTrue);
      expect(BithumanLoadEvent.fromMap({'code': 'A', 'stage': 'fetched', 'cached': 'yes'})!.cached, isFalse);
      expect(BithumanLoadEvent.fromMap({'code': 'A', 'stage': 'fetched'})!.elapsed, Duration.zero);
    });

    test('not an event: null', () {
      expect(BithumanLoadEvent.fromMap(null), isNull);
      expect(BithumanLoadEvent.fromMap(const []), isNull);
      expect(BithumanLoadEvent.fromMap({'code': 7, 'stage': 'fetch'}), isNull);
      expect(BithumanLoadEvent.fromMap({'code': 'A', 'stage': 3}), isNull);
      expect(BithumanLoadEvent.fromMap({'code': 'A', 'stage': 'Fetch'}), isNull);
    });
  });
}
