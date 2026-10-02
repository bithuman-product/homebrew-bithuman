// The barge gate (2.6.28) on a FAKE clock: while the agent is heard (the host's playout), the
// canceller's residual goes up as silence, and a voice reaches the server once it has held.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bithuman/src/barge_gate.dart';
import 'package:flutter_test/flutter_test.dart';

const int kRate = 24000;

/// [ms] of 24 kHz PCM16 at a constant RMS of [dbfs] (a square wave: RMS = amplitude).
Uint8List tone(double dbfs, {int ms = 100}) {
  final n = kRate * ms ~/ 1000;
  final a = dbfs <= -120 ? 0 : (32768 * math.pow(10, dbfs / 20)).round().clamp(0, 32767);
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, i.isEven ? a : -a, Endian.little);
  }
  return b.buffer.asUint8List();
}

bool silent(Uint8List c) => c.every((x) => x == 0);

class Rig {
  Rig({double offsetDb = -8}) {
    gate = BargeGate(offsetDb: offsetDb, clock: () => now, calibrateFor: Duration.zero);
  }
  DateTime now = DateTime(2026, 10, 1, 12);
  late final BargeGate gate;
  int fed = 0, played = 0;

  /// Hands [ms] of agent voice at [dbfs] to the host.
  void hand(double dbfs, int ms) {
    gate.far(tone(dbfs, ms: ms));
    fed += kRate * ms ~/ 1000;
    gate.playout(played, fed);
  }

  /// [ms] pass; the host plays at 1x and reports every 100 ms.
  void play(int ms) {
    for (var t = 0; t < ms; t += 100) {
      now = now.add(const Duration(milliseconds: 100));
      played = math.min(fed, played + kRate ~/ 10);
      gate.playout(played, fed);
    }
  }

  BargeGateOutput mic(double dbfs) => gate.mic(tone(dbfs));
}

void main() {
  test('the agent not heard (handed over, not yet playing): every chunk goes up as captured', () {
    final r = Rig();
    r.hand(-20, 3000); // a reply arrived in a burst; the presenter has not started it
    final o = r.mic(-30);
    expect(o.chunks.length, 1);
    expect(silent(o.chunks.single), isFalse);
  });

  test('while heard: the residual is silenced, a voice is held for the sustain then released in order',
      () {
    final r = Rig();
    r.hand(-20, 5000);
    r.play(500);
    // -35 dBFS under a -20 dBFS voice: 15 dB under it, under the -8 dB floor.
    final echo = r.mic(-35);
    expect(echo.chunks.length, 1);
    expect(silent(echo.chunks.single), isTrue);
    // A person at -24 dBFS (4 dB under the voice): held for 200 ms, then both chunks go up.
    r.play(100);
    final first = r.mic(-24);
    expect(first.chunks, isEmpty, reason: 'held, not dropped');
    r.play(100);
    final second = r.mic(-24);
    expect(second.opened, isTrue);
    expect(second.chunks.length, 2);
    expect(second.chunks.every((c) => !silent(c)), isTrue, reason: 'the onset reaches the server');
    expect(r.gate.opens, 1);
  });

  test('a burst over the floor that does not hold goes up as silence', () {
    final r = Rig();
    r.hand(-20, 5000);
    r.play(500);
    expect(r.mic(-22).chunks, isEmpty);
    r.play(100);
    final o = r.mic(-40);
    expect(o.chunks.length, 2);
    expect(o.chunks.every(silent), isTrue);
    expect(r.gate.rejectedBursts, 1);
  });

  test('open: stays open through short dips (hangover), closes after it', () {
    final r = Rig();
    r.hand(-20, 8000);
    r.play(500);
    r.mic(-22);
    r.play(100);
    expect(r.mic(-22).opened, isTrue);
    r.play(100);
    expect(silent(r.mic(-50).chunks.single), isFalse, reason: 'a dip inside the hangover');
    r.play(300);
    r.mic(-50);
    r.play(200);
    expect(silent(r.mic(-50).chunks.single), isTrue, reason: 'closed after 400 ms under the floor');
  });

  test('a cut: the discarded audio is never heard, the uplink is open', () {
    final r = Rig();
    r.hand(-20, 5000);
    r.play(500);
    r.gate.cut();
    r.played = r.fed; // the host discards everything handed over
    r.gate.playout(r.played, r.fed);
    expect(silent(r.mic(-35).chunks.single), isFalse);
  });

  test('the echo tail: gated 500 ms past the last heard voice, open after', () {
    final r = Rig();
    r.hand(-20, 1000);
    r.play(1000); // heard to the end
    r.now = r.now.add(const Duration(milliseconds: 300));
    expect(silent(r.mic(-35).chunks.single), isTrue, reason: 'inside the tail');
    r.now = r.now.add(const Duration(milliseconds: 400));
    expect(silent(r.mic(-35).chunks.single), isFalse, reason: 'past the tail');
  });

  test('the floor follows the voice heard: a quiet passage lowers it', () {
    final r = Rig();
    r.hand(-40, 3000); // a soft voice
    r.play(1000);
    r.mic(-36);
    r.play(100);
    expect(r.mic(-36).opened, isTrue, reason: '-36 dBFS is a voice over a -40 dBFS agent');
  });

  test('per-call calibration: a leakier canceller raises the floor, never above -10 dB', () {
    var now = DateTime(2026, 10, 1, 12);
    var fed = 0, played = 0;
    BargeGate mk() {
      now = DateTime(2026, 10, 1, 12);
      played = 0;
      final g = BargeGate(offsetDb: -16, clock: () => now, calibrateFor: const Duration(seconds: 1));
      g.far(tone(-20, ms: 5000));
      fed = kRate * 5;
      return g;
    }

    void play(BargeGate g) {
      now = now.add(const Duration(milliseconds: 100));
      played += kRate ~/ 10;
      g.playout(played, fed);
    }

    // The residual sits at -37 dBFS, 17 dB under a -20 dBFS voice: under the row's -16 floor.
    final g = mk();
    play(g);
    for (var i = 0; i < 12; i++) {
      expect(silent(g.mic(tone(-37)).chunks.single), isTrue);
      play(g);
    }
    expect(g.floorOffsetDb, closeTo(-14, 0.1), reason: 'p90 -17 + 3 = -14: raised from the row');
    // Now -35 dBFS (15 dB under the voice) is residual on THIS phone; the row alone let it in.
    expect(silent(g.mic(tone(-35)).chunks.single), isTrue);
    // A leakier one stops at the -10 cap (row -12, residual 12.5 dB under: p90 + 3 = -9.5); a
    // quiet one (-60) keeps the row's floor.
    BargeGate mk12() {
      now = DateTime(2026, 10, 1, 12);
      played = 0;
      final g = BargeGate(offsetDb: -12, clock: () => now, calibrateFor: const Duration(seconds: 1));
      g.far(tone(-20, ms: 5000));
      fed = kRate * 5;
      return g;
    }

    final l = mk12();
    play(l);
    for (var i = 0; i < 12; i++) {
      expect(silent(l.mic(tone(-32.5)).chunks.single), isTrue);
      play(l);
    }
    expect(l.floorOffsetDb, -10);
    final q = mk();
    play(q);
    for (var i = 0; i < 12; i++) {
      q.mic(tone(-60));
      play(q);
    }
    expect(q.floorOffsetDb, -16);
  });

  test('a host that reports no playout: the handover estimate decides', () {
    var now = DateTime(2026, 10, 1, 12);
    final g = BargeGate(offsetDb: -8, clock: () => now);
    g.far(tone(-20, ms: 1000));
    now = now.add(const Duration(milliseconds: 300));
    expect(silent(g.mic(tone(-35)).chunks.single), isTrue);
    now = now.add(const Duration(milliseconds: 1300));
    expect(silent(g.mic(tone(-35)).chunks.single), isFalse);
  });
}
