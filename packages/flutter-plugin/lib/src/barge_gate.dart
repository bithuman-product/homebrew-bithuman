// barge_gate.dart — while the character is HEARD, the microphone reaches the server's turn
// detector only when it is a voice, not the character's own echo.
//
// ★WHY (2.6.28). Barge-in on the relay path is the server's VAD (`server_vad`, interrupt_response):
// anything on the uplink that it takes for speech cuts the reply, and the model then answers it.
// The platform's echo canceller (VP-IO on Apple, the communication path's AEC on Android) removes
// most of the character's voice from the microphone, but not all of it: its onset before the
// canceller converges, the reverberant tail after a phrase, and on a phone at full call volume the
// residual of a loudspeaker driven hard. Until 2.6.28 the session's only defence was an onset
// guard — mic chunks under a fixed -18 dBFS peak sent as silence for the first 8 s of the call —
// and it ran on a clock of its own that was wrong on Android: it counted the agent "audible" from
// when the reply ARRIVED (a 4 s greeting lands in 0.3 s), while the presenter starts the voice
// ~1.7 s later, so the guard lapsed while the greeting was still playing (Galaxy Z Fold5, call
// volume 15/15, 2026-10-01: a server `speech_started` 4.8 s into the greeting with `audible=false`).
//
// This gate knows when the character is heard and how loud: the host reports its playout
// (`VoiceHost.speechPlayout`: what of the agent audio handed to it has been heard), and the
// session hands the gate the same audio, so the gate keeps the level of every 20 ms of it on the
// same coordinate. While the voice is heard (and for [tail] after it stops — the room's echo),
// a microphone chunk counts as the person only if its level comes within [offsetDb] of the
// loudest voice heard in the last [tail] (the echo of a voice is always well under the voice
// itself; a person talking over it is not), and only once that has held for [sustain]: until
// then the chunks are HELD (a voice's onset is not lost — the server still sees it, [sustain]
// later), and a burst that does not hold goes up as silence. Once open, the uplink stays open
// until the mic has been under the floor for [hangover]. When the character is silent the gate
// does nothing at all.
//
// The offset is per device class ([EchoProfile.bargeFloorDb]), and calibrated per call: the
// residual the canceller leaves during the first seconds the character is heard (the greeting)
// is measured, and a phone that leaks more raises its own floor (never above [maxOffsetDb]: a
// floor closer to the voice than that delays a person's cut-in by most of a second).
//
// Pure Dart with an injectable clock (test/barge_gate_test.dart). Apache-2.0; (c) bitHuman.

import 'dart:math' as math;
import 'dart:typed_data';

/// What the gate did with one microphone chunk: the chunks to send now, in order (the held
/// chunks it released, then this one; each either as captured or as digital silence). Empty
/// while a burst is being held.
class BargeGateOutput {
  BargeGateOutput(this.chunks, {this.opened = false, this.silenced = 0});
  final List<Uint8List> chunks;

  /// This chunk opened the uplink (a voice held for the sustain window while the agent was heard).
  final bool opened;

  /// How many of [chunks] are silence in place of what was captured.
  final int silenced;
}

class BargeGate {
  BargeGate({
    required this.offsetDb,
    this.maxOffsetDb = -10,
    this.sustain = const Duration(milliseconds: 200),
    this.hangover = const Duration(milliseconds: 400),
    this.tail = const Duration(milliseconds: 500),
    this.calibrateFor = const Duration(seconds: 3),
    DateTime Function()? clock,
    this.onLog,
  }) : _clock = clock ?? DateTime.now {
    _ring.fillRange(0, _ringBlocks, _silentDb);
  }

  /// The floor, in dB relative to the loudest agent voice heard in the last [tail]: a mic chunk
  /// whose RMS is below it is the agent's echo. Negative.
  final double offsetDb;

  /// The highest the per-call calibration may raise the floor to (relative, dB).
  final double maxOffsetDb;

  /// How long a voice must hold over the floor, while the agent is heard, before it reaches
  /// the server. It adds this much to a cut-in's latency.
  final Duration sustain;

  /// Once open, how long the mic may stay under the floor before the gate closes again.
  final Duration hangover;

  /// How long after the agent's voice was last heard its echo is still in the room.
  final Duration tail;

  /// The audible time over which the canceller's residual is measured (the greeting).
  final Duration calibrateFor;

  final void Function(String line)? onLog;
  final DateTime Function() _clock;

  static const int rate = 24000;
  static const int _block = 480; // 20 ms
  static const int _ringBlocks = 3000; // 60 s of agent audio
  static const double _silentDb = -120;

  // Agent audio handed over, as 20 ms block levels (dBFS) on the fed coordinate.
  final Float32List _ring = Float32List(_ringBlocks);
  int _fed = 0;
  double _blockSq = 0;
  int _blockN = 0;

  // The host's playout.
  bool _haveReports = false;
  int _played = 0;
  int _reportedFed = 0;
  DateTime? _reportAt;
  DateTime? _lastAdvanceAt;
  int _minPlayed = 0; // audio before this was discarded by a cut: never "heard"
  DateTime _estEnd = DateTime.fromMillisecondsSinceEpoch(0);

  // The uplink.
  bool _open = false;
  DateTime? _belowSince;
  final List<Uint8List> _held = [];
  int _heldSamples = 0;

  // Per-call calibration of the residual (mic RMS minus the voice heard, dB).
  final List<double> _residual = [];
  int _calibratedMs = 0;
  double? _calibratedOffset;

  // Counters, for the log and the tests.
  int opens = 0;
  int rejectedBursts = 0;
  int silencedChunks = 0;

  /// The floor in use (relative dB): the device row's, raised by the call's calibration.
  double get floorOffsetDb => math.max(offsetDb, _calibratedOffset ?? offsetDb);

  /// The host's audio unit (re)started: everything restarts at zero (the calibration too:
  /// a new unit is a new canceller).
  void reset() {
    _fed = 0;
    _blockSq = 0;
    _blockN = 0;
    _ring.fillRange(0, _ringBlocks, _silentDb);
    _haveReports = false;
    _played = 0;
    _reportedFed = 0;
    _reportAt = null;
    _lastAdvanceAt = null;
    _minPlayed = 0;
    _estEnd = DateTime.fromMillisecondsSinceEpoch(0);
    _open = false;
    _belowSince = null;
    _held.clear();
    _heldSamples = 0;
    _residual.clear();
    _calibratedMs = 0;
    _calibratedOffset = null;
  }

  /// Agent audio (24 kHz PCM16 LE) handed to the host, in the order it is handed.
  void far(Uint8List pcm) {
    final n = pcm.length & ~1;
    if (n == 0) return;
    final now = _clock();
    final bd = ByteData.sublistView(pcm, 0, n);
    for (var i = 0; i < n; i += 2) {
      final v = bd.getInt16(i, Endian.little).toDouble();
      _blockSq += v * v;
      _blockN++;
      if (_blockN == _block) {
        _ring[(_fed ~/ _block) % _ringBlocks] = _db(_blockSq / _block);
        _fed += _block;
        _blockSq = 0;
        _blockN = 0;
      }
    }
    final start = _estEnd.isAfter(now) ? _estEnd : now;
    _estEnd = start.add(Duration(microseconds: (n ~/ 2) * 1000000 ~/ rate));
  }

  /// The host's playout report: of the agent audio handed over since its audio unit started
  /// ([fed]), how much has been heard or discarded ([played]).
  void playout(int played, int fed) {
    if (fed < _reportedFed) return; // an older unit's count, or out of order
    _haveReports = true;
    _reportedFed = fed;
    final now = _clock();
    final p = math.min(played, fed);
    if (p > _played && p > _minPlayed) _lastAdvanceAt = now;
    if (p > _played) _played = p;
    _reportAt = now;
  }

  /// A cut (a barge-in, a typed turn, a stop): everything handed over so far is discarded, so
  /// none of it will be heard; the gate is open until the next reply is heard.
  void cut() {
    _minPlayed = _fedPlusPartial;
    _lastAdvanceAt = null;
    _estEnd = DateTime.fromMillisecondsSinceEpoch(0);
  }

  int get _fedPlusPartial => _fed + _blockN;

  /// Where the listener is in the agent audio now, on the fed coordinate; null when the agent
  /// has not been heard within [tail].
  int? _heardPos(DateTime now) {
    if (_haveReports) {
      final adv = _lastAdvanceAt;
      if (adv == null || now.difference(adv) > tail) return null;
      var p = _played;
      final at = _reportAt;
      // Between reports the voice plays on at 1x (reports come every ~100 ms while it moves).
      if (at != null && p < _reportedFed) {
        final ms = now.difference(at).inMilliseconds.clamp(0, 150);
        p = math.min(_reportedFed, p + ms * rate ~/ 1000);
      }
      return p;
    }
    // A host that reports no playout: the handover estimate (played at 1x from when handed).
    if (!_estEnd.add(tail).isAfter(now)) return null;
    final ahead = _estEnd.difference(now).inMicroseconds;
    final unheard = ahead > 0 ? ahead * rate ~/ 1000000 : 0;
    final p = _fedPlusPartial - unheard;
    return p > _minPlayed ? p : null;
  }

  /// The loudest 20 ms of agent voice heard in the last [tail] (dBFS), or null when the agent
  /// is not being heard.
  double? heardLevelDb() {
    final now = _clock();
    final pos = _heardPos(now);
    if (pos == null) return null;
    final from = math.max(_minPlayed, pos - tail.inMicroseconds * rate ~/ 1000000);
    final hi = math.min(pos, _fed);
    if (hi <= from) return null;
    var best = _silentDb;
    for (var b = from ~/ _block; b * _block < hi; b++) {
      if (_fed - b * _block > _ringBlocks * _block) continue; // older than the ring
      final v = _ring[b % _ringBlocks];
      if (v > best) best = v;
    }
    return best <= -90 ? null : best;
  }

  /// Whether the agent is being heard now (or its echo can still be in the room).
  bool get agentHeard => heardLevelDb() != null;

  /// One microphone chunk (24 kHz PCM16 LE, after any test injection). Returns what to send.
  BargeGateOutput mic(Uint8List pcm) {
    final now = _clock();
    final lf = heardLevelDb();
    final n = pcm.length & ~1;
    final samples = n ~/ 2;
    if (lf == null) {
      // The agent is not heard: the gate is not in the way. A burst held when the voice stopped
      // goes up as it was.
      _open = false;
      _belowSince = null;
      final out = <Uint8List>[..._held, pcm];
      _held.clear();
      _heldSamples = 0;
      return BargeGateOutput(out);
    }
    final micDb = _rmsDb(pcm, n);
    // The residual is measured on what is not (yet) a voice: never while the uplink is open.
    if (!_open && _held.isEmpty) _calibrate(micDb - lf, samples);
    final floor = lf + floorOffsetDb;
    final above = micDb >= floor;
    if (_open) {
      if (above) {
        _belowSince = null;
        return BargeGateOutput([pcm]);
      }
      _belowSince ??= now;
      if (now.difference(_belowSince!) < hangover) return BargeGateOutput([pcm]);
      // Under the floor for the whole hangover: closed again, and this chunk is residual.
      _open = false;
      _belowSince = null;
    }
    if (above) {
      _held.add(pcm);
      _heldSamples += samples;
      if (_heldSamples * 1000000 ~/ rate >= sustain.inMicroseconds) {
        _open = true;
        opens++;
        _belowSince = null;
        final out = List<Uint8List>.of(_held);
        _held.clear();
        _heldSamples = 0;
        onLog?.call('[bhgate] OPEN mic=${micDb.toStringAsFixed(1)} dBFS floor=${floor.toStringAsFixed(1)} '
            '(heard ${lf.toStringAsFixed(1)} ${floorOffsetDb.toStringAsFixed(1)} dB) after ${sustain.inMilliseconds} ms '
            'hostMs=${now.millisecondsSinceEpoch}');
        return BargeGateOutput(out, opened: true);
      }
      return BargeGateOutput(const []);
    }
    // Under the floor: the echo. A held burst that did not last goes up as silence with it.
    final out = <Uint8List>[];
    var silenced = 0;
    if (_held.isNotEmpty) {
      rejectedBursts++;
      for (final h in _held) {
        out.add(Uint8List(h.length));
        silenced++;
      }
      _held.clear();
      _heldSamples = 0;
    }
    out.add(Uint8List(pcm.length));
    silenced++;
    silencedChunks += silenced;
    return BargeGateOutput(out, silenced: silenced);
  }

  /// Everything still held, as captured (the session is stopping or the gate is bypassed).
  List<Uint8List> drain() {
    final out = List<Uint8List>.of(_held);
    _held.clear();
    _heldSamples = 0;
    return out;
  }

  void _calibrate(double residualDb, int samples) {
    if (_calibratedMs >= calibrateFor.inMilliseconds) return;
    _calibratedMs += samples * 1000 ~/ rate;
    _residual.add(math.max(-60.0, residualDb));
    if (_residual.length < 3) return;
    final s = List<double>.of(_residual)..sort();
    final p90 = s[(s.length * 9 ~/ 10).clamp(0, s.length - 1)];
    // The floor sits 3 dB over the loud end of what the canceller leaves (digital silence counts
    // at -60), never lower than the row's and never above [maxOffsetDb]. Updated as the
    // residual is measured; fixed once [calibrateFor] of the voice has been heard.
    final c = math.min(maxOffsetDb, p90 + 3);
    _calibratedOffset = c > offsetDb ? c : null;
    if (_calibratedMs >= calibrateFor.inMilliseconds) {
      onLog?.call('[bhgate] calibrated over $_calibratedMs ms: residual p90 ${p90.toStringAsFixed(1)} dB '
          '(${_residual.length} chunks) -> floor ${floorOffsetDb.toStringAsFixed(1)} dB under the voice heard');
    }
  }

  static double _rmsDb(Uint8List pcm, int n) {
    if (n == 0) return _silentDb;
    final bd = ByteData.sublistView(pcm, 0, n);
    var sq = 0.0;
    for (var i = 0; i < n; i += 2) {
      final v = bd.getInt16(i, Endian.little).toDouble();
      sq += v * v;
    }
    return _db(sq / (n ~/ 2));
  }

  static double _db(double meanSq) =>
      meanSq <= 0 ? _silentDb : 10 * math.log(meanSq / (32768.0 * 32768.0)) / math.ln10;
}
