// Tier 1 — THE HEADLESS HALF OF `integration_test/engine_smoke_test.dart`.
//
// ★ WHY THIS FILE EXISTS. The app repo's engine smoke test drives the render
// side of the plugin end to end: load a staged bundle with `engine: 'elevate'`,
// wait out the warm-up, read the frame size, inject 2 s of synthesized 16 kHz
// PCM in 100 ms chunks (Apple) or flip the mouth gate (Android), dispose. It
// needs a device, a booted app, and engine bytes, so it cannot join the push
// gate — and it lives in bithuman-jarvis-app, which has no `.github/`
// directory, so in practice it runs when a human runs it on the owner's Mac.
//
// That test is TWO tests wearing one hat:
//   • does the NATIVE engine load, compile and produce frames?  — device only.
//   • does DART hand the native side the right call, in the right order, with
//     the right bytes?                                          — needs nothing.
//
// The second half is split out here and runs on every push. It drives the
// SAME sequence, with the same `synthPcm` bytes from `e2e/mock_realtime`,
// against `FakeAvatarPlatform` — no engine, no texture, no bundle, no device.
//
// ★ WHAT IT ADDS, MEASURED (2026-09-16, against `test/` at cb500d4). Before
// this file, the strings `pushAudio`, `isReady`, `setSpeaking`, `frameSize`
// and `refreshFrameSize` appeared in this package's tests ONLY inside
// `fake_avatar_platform.dart` — the double ANSWERED those verbs and no arm
// ever ASKED one. The voice harness reaches `BithumanAvatar` through the
// realtime session (load with defaults, audioStart, playSpeakerPCM, interrupt,
// audioStop), which is the speaker path; the injected-PCM path, the warm-up
// gate, the frame-size report and the Android mouth gate had no CI arm at all.
//
// ★ WHAT STILL CANNOT RUN HERE, and is not pretended: whether `le_core` JNI or
// `libessence2` loads, whether the CoreML/ANE compile finishes inside the
// budget, and whether any pixel changes. Those stay in
// `<app repo>/integration_test/engine_smoke_test.dart`, reached by
// `BITHUMAN_APP_DIR=<checkout> e2e/run_all.sh`. A green run here says the Dart
// contract is intact; it does not say the engine works.
//
// Run: flutter test test/e2e/engine_smoke_headless_test.dart
// CI: .github/workflows/flutter-plugin-tests.yml, every push and PR that
// touches packages/flutter-plugin/**.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:typed_data';

import 'package:bithuman/bithuman.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_realtime/mock_realtime.dart' show synthPcm;

import 'fake_avatar_platform.dart';

/// The bundle path the device test passes. Never opened here: `load` is a
/// method-channel call and the fake answers it, which is the point — the Dart
/// side does not stat the path, the native side does.
const _bundle = '/staged/A23WJF0199.elevatedir';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAvatarPlatform fake;
  var nextTextureId = 41;

  setUp(() {
    fake = FakeAvatarPlatform(textureId: nextTextureId++);
    fake.install();
  });

  tearDown(() => fake.uninstall());

  Map<Object?, Object?> argsOf(MethodCall c) => c.arguments as Map<Object?, Object?>;

  MethodCall onlyCall(String method) {
    final matches = fake.calls.where((c) => c.method == method).toList();
    expect(matches, hasLength(1), reason: 'expected exactly one `$method`');
    return matches.single;
  }

  // ARM 1 — the Tier-2 invocation as the device test spells it.
  // `BithumanAvatar.load(bundle, engine: 'elevate', chunk: 2)` is a marshalling
  // contract with the Kotlin/Swift `load` handler: a renamed or dropped key is
  // silently ignored by the native side (it reads defaults), so the engine runs
  // with the WRONG chunk and nothing says so. The optional keys are
  // conditional — `apiSecret` and `motionDir` must be ABSENT when not given,
  // not present-and-empty, because the native side branches on presence.
  test('load carries engine + chunk; optional keys are absent when unset', () async {
    final avatar = await BithumanAvatar.load(_bundle, engine: 'elevate', chunk: 2);

    expect(avatar.textureId, greaterThanOrEqualTo(0));
    final args = argsOf(onlyCall('load'));
    expect(args['path'], _bundle);
    expect(args['engine'], 'elevate');
    expect(args['chunk'], 2);
    expect(args.containsKey('apiSecret'), isFalse,
        reason: 'no secret was passed — the key must not appear at all');
    expect(args.containsKey('motionDir'), isFalse);
    expect(args.keys.toSet(), {'path', 'engine', 'chunk'});

    await avatar.dispose();

    // The metered Android door: the secret and the teacher-onnx dir DO appear
    // when given (the essence-2 path; see BithumanAvatar.load's doc comment).
    fake.calls.clear();
    final metered = await BithumanAvatar.load(
      _bundle,
      engine: 'essence2',
      apiSecret: 'not-a-secret-a-fixture',
      motionDir: '/staged/motion',
      chunk: 16,
    );
    final meteredArgs = argsOf(onlyCall('load'));
    expect(meteredArgs['apiSecret'], 'not-a-secret-a-fixture');
    expect(meteredArgs['motionDir'], '/staged/motion');
    expect(meteredArgs['chunk'], 16);
    await metered.dispose();
  });

  // ARM 2 — the warm-up the device test spends up to 300 s waiting out
  // ("engine not ready within ${budget}s"). Essence2 does not report ready at
  // load: the first run on a machine pays an ANE/CoreML compile. The native
  // side DROPS audio pushed before the flip, so a poll that never fires is a
  // session that never speaks — and it looks like a dead engine, not a dead
  // timer.
  test('warm-up: isReady polls until the engine flips, and `ready` completes', () async {
    fake.ready = false;
    final avatar = await BithumanAvatar.load(_bundle, engine: 'elevate', chunk: 2);

    expect(avatar.isReady, isFalse, reason: 'the fake engine is still warming');
    var readyFired = false;
    unawaited(avatar.ready.then((_) => readyFired = true));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(readyFired, isFalse, reason: 'the ready future must not complete early');

    final pollsBefore = fake.callCount('isReady');
    fake.ready = true;
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(avatar.isReady, isTrue, reason: 'the 500 ms poll must pick the flip up');
    expect(fake.callCount('isReady'), greaterThan(pollsBefore),
        reason: 'readiness is POLLED, not asked once at load');
    await avatar.ready; // completes, or this test times out
    expect(readyFired, isTrue);

    await avatar.dispose();
  });

  // ARM 3 — "engine must report its frame size" (the device test's assertion).
  // The canvas is laid out from these numbers; width/height crossed is a
  // stretched avatar on every platform. refreshFrameSize is the HEAD/FULL
  // switch's re-read and had no arm at all.
  test('frame size is seeded at load, re-read on demand, and tolerated when absent',
      () async {
    final avatar = await BithumanAvatar.load(_bundle, engine: 'elevate', chunk: 2);
    expect(avatar.frameWidth, 720);
    expect(avatar.frameHeight, 1280);

    // HEAD mode: the native stream re-sizes to the actor's square frames.
    fake.frameSize = const {'width': 512, 'height': 512};
    expect(await avatar.refreshFrameSize(), isTrue);
    expect(avatar.frameWidth, 512);
    expect(avatar.frameHeight, 512);
    expect(await avatar.refreshFrameSize(), isFalse,
        reason: 'unchanged dims are not a change');
    await avatar.dispose();

    // An older native side has no `frameSize`: load must still resolve, with a
    // 0 the caller replaces with a layout fallback.
    fake.frameSize = null;
    final old = await BithumanAvatar.load(_bundle, engine: 'elevate', chunk: 2);
    expect(old.frameWidth, 0);
    expect(old.frameHeight, 0);
    await old.dispose();
  });

  // ARM 4 — the Apple leg of the device test, byte for byte.
  //
  // ★THE DEFECT THIS CATCHES AND A DEVICE CANNOT: `pushAudio` sends a VIEW of a
  // typed-data buffer. The chunk loop hands it `Int16List.sublistView`, whose
  // `offsetInBytes` is non-zero from the second chunk on. Send
  // `pcm.buffer.asUint8List()` instead of the offset+length window and every
  // call ships the WHOLE two seconds — 20x the audio, still valid PCM, still
  // lipsync-shaped. On a device the mouth keeps moving and the log keeps
  // printing frames; here it is one failed equality.
  test('injected PCM: 20 chunks of 100 ms reach the native side byte-exact',
      () async {
    final avatar = await BithumanAvatar.load(_bundle, engine: 'elevate', chunk: 2);

    final pcmBytes = synthPcm(2000, sampleRate: 16000);
    expect(pcmBytes.length, 64000, reason: '2 s of 16 kHz mono int16');
    final pcm = pcmBytes.buffer
        .asInt16List(pcmBytes.offsetInBytes, pcmBytes.length ~/ 2);
    const chunkSamples = 1600; // 100 ms @ 16 kHz

    for (var off = 0; off < pcm.length; off += chunkSamples) {
      final end = (off + chunkSamples).clamp(0, pcm.length);
      await avatar.pushAudio(Int16List.sublistView(pcm, off, end));
    }

    final pushes = fake.calls.where((c) => c.method == 'pushAudio').toList();
    expect(pushes, hasLength(20));

    final seen = BytesBuilder();
    for (final p in pushes) {
      final bytes = argsOf(p)['pcm'] as Uint8List;
      expect(bytes.length, 3200, reason: '100 ms @ 16 kHz mono int16');
      expect(argsOf(p)['textureId'], avatar.textureId);
      seen.add(bytes);
    }
    expect(seen.toBytes(), orderedEquals(pcmBytes),
        reason: 'the native side must receive exactly what was injected, in order');

    await avatar.dispose();
  });

  // ARM 5 — the Android leg of the device test. The mouth gate maps the
  // bundle's TALKING / IDLE frame ranges; the device test can only assert "did
  // not throw" in-process and leaves the real check to a logcat grep in
  // run_all.sh. The payload it depends on is gradeable here.
  test('mouth gate: setSpeaking carries the flag and the texture', () async {
    final avatar = await BithumanAvatar.load(_bundle, engine: 'essence2', chunk: 16);

    await avatar.setSpeaking(true);
    await avatar.setSpeaking(false);

    final gates = fake.calls.where((c) => c.method == 'setSpeaking').toList();
    expect(gates, hasLength(2));
    expect(argsOf(gates[0])['speaking'], isTrue);
    expect(argsOf(gates[0])['textureId'], avatar.textureId);
    expect(argsOf(gates[1])['speaking'], isFalse);

    await avatar.dispose();
  });

  // ARM 6 — dispose. The soak tests load and drop avatars in a loop; the
  // contract they lean on is that a dropped avatar is inert (a late push is an
  // exception, not a call to a freed native handle), that dispose is
  // idempotent (a double tear-down must not tell the native side to free
  // twice), and that anyone awaiting `ready` on an engine that never warmed is
  // released rather than hung forever.
  test('dispose: inert, idempotent, and releases a waiter on ready', () async {
    fake.ready = false; // never warms — the waiter must still be released
    final avatar = await BithumanAvatar.load(_bundle, engine: 'elevate', chunk: 2);

    await avatar.dispose();
    await avatar.ready; // completes on dispose, or this test times out
    expect(avatar.isReady, isFalse, reason: 'released is not ready');

    await expectLater(avatar.pushAudio(Int16List(160)),
        throwsA(isA<BithumanAvatarException>()));

    final disposesAfterFirst = fake.callCount('dispose');
    await avatar.dispose();
    expect(fake.callCount('dispose'), disposesAfterFirst,
        reason: 'the second dispose must not reach the native side');
  });
}
