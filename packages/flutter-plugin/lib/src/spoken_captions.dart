// spoken_captions.dart — the agent's words, released as they are HEARD.
//
// ★WHY (2.6.27). A reply's text and its audio reach the app in one burst: the relay streams a
// several-second reply in about a second, and the transcript deltas come with it. A caption
// built from `botTranscriptStream` therefore showed the END of the reply while the character
// was still on its first sentence (bitHuman Live on a Galaxy S24, 2026-09-30: 1 to 10 s ahead).
//
// The voice host knows what has actually been heard: Android presents each unit of the
// agent's voice on the audio device's own clock, and the Apple player releases it frame by
// frame. It reports that as `speechPlayout` (see [BithumanPlayout]): of the agent audio handed
// to it since the audio unit started (`fed`), how much has been heard or discarded (`played`).
// [SpokenCaptioner] lines that position up with each reply's text and releases the words in
// step with it: once a reply's text and audio are both complete, in exact proportion (the
// share of the reply's audio heard is the share of its text shown); before that, at a
// conservative speaking rate, never past the text that has arrived. Words are released whole,
// never retracted. A cut (barge-in, a typed turn, hang-up) ends every open reply with only the
// words already heard.
//
// A host that never reports playout (a third-party VoiceHost) is not left blank: after
// [SpokenCaptioner.noPlayoutAfter] without a report the position is estimated from the handover
// (the audio handed over, played at 1x from when it was handed).
//
// Everything here is pure Dart with an injectable clock, so the release rules run in tests
// on a fake clock (test/spoken_captions_test.dart). Apache-2.0; (c) bitHuman.

import 'dart:math' as math;

import 'voice_host.dart' show BithumanPlayout;

/// The agent's words for one reply, released as they are heard.
///
/// [text] is CUMULATIVE for [reply] (replace the caption, do not append). A new [reply]
/// number starts a new caption. [isFinal]: nothing more comes for this reply — it was heard
/// to the end, or it was cut ([interrupted]), in which case [text] holds only the words heard
/// before the cut.
class BithumanSpokenText {
  const BithumanSpokenText({
    required this.reply,
    required this.text,
    this.isFinal = false,
    this.interrupted = false,
  });

  /// The reply's ordinal in this session, from 1.
  final int reply;

  /// The words released so far for this reply (cumulative).
  final String text;

  /// No more events for this reply.
  final bool isFinal;

  /// The reply was cut before it was heard to the end; [text] is what was heard.
  final bool interrupted;

  @override
  String toString() => 'BithumanSpokenText(reply: $reply, ${text.length} chars'
      '${isFinal ? ', final' : ''}${interrupted ? ', interrupted' : ''})';
}

/// Lines the voice host's playout position up with each reply's text. Not thread-bound; the
/// owner calls it from one isolate. Pure: no timers of its own — the owner calls [tick] while
/// [busy] (every 50 ms is plenty), and every input re-evaluates at once.
class SpokenCaptioner {
  SpokenCaptioner({
    required this.onCaption,
    DateTime Function()? clock,
    this.noPlayoutAfter = const Duration(seconds: 1),
    this.onLog,
  }) : _clock = clock ?? DateTime.now;

  /// Each release: a longer [BithumanSpokenText.text], or a reply's final event.
  final void Function(BithumanSpokenText) onCaption;

  /// One line per release, for the native log: positions and counts, never the words.
  final void Function(String line)? onLog;

  /// How long after the first audio of a session the captioner waits for a playout report
  /// before it estimates the position from the handover instead.
  final Duration noPlayoutAfter;

  final DateTime Function() _clock;

  /// Samples per second of the coordinate (the realtime wire rate).
  static const int rate = 24000;

  /// Speaking rate used before a reply's text and audio are both complete, in characters per
  /// second of audio: a little under a typical voice's, so the caption errs behind.
  static const double charsPerSecond = 13;

  /// The same for text in a script written without spaces (Chinese, Japanese, Thai, ...).
  static const double charsPerSecondCjk = 5;

  /// Between two reports the voice plays on at 1x; the position is carried forward this far.
  static const int _extrapolateMs = 150;

  // The coordinate: 24 kHz samples of agent audio handed to the host since its audio unit
  // started (the host's `fed`).
  int _handed = 0;
  int _played = 0;
  int _reportedFed = 0;
  DateTime? _reportedAt;
  bool _haveReports = false;
  bool _advancing = false;
  DateTime? _firstAudioAt;
  // The handover estimate: when the audio handed so far would end, played at 1x from handover.
  DateTime _estEnd = DateTime.fromMillisecondsSinceEpoch(0);

  final List<_Reply> _open = [];
  _Reply? _current;
  int _replyN = 0;

  /// Whether a reply still has words to release: the owner keeps calling [tick].
  bool get busy => _open.isNotEmpty;

  /// Whether positions come from the host's reports (false: the handover estimate).
  bool get hasPlayoutReports => _haveReports;

  /// The host's audio unit (re)started: its counts restart at zero. Open replies end where
  /// they were (a new audio unit means the old one's sound is gone).
  void reset() {
    cut();
    _handed = 0;
    _played = 0;
    _reportedFed = 0;
    _reportedAt = null;
    _haveReports = false;
    _advancing = false;
    _firstAudioAt = null;
    _estEnd = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// A new reply begins (`response.created`). [id] keys later events when they carry one.
  void replyStarted([String? id]) {
    // The server generates one reply at a time: an earlier reply still open (its done event
    // was lost to a reconnect) has all the text and audio it will get, and plays out.
    for (final o in _open) {
      o.textDone = true;
      o.audioDone = true;
    }
    final r = _Reply(++_replyN, id);
    _open.add(r);
    _current = r;
  }

  /// A piece of the reply's transcript arrived.
  void text(String delta, [String? id]) {
    final r = _find(id);
    if (r == null || delta.isEmpty) return;
    r.text += delta;
    _evaluate();
  }

  /// The reply's transcript is complete. [full], when given, replaces what the deltas built.
  void textDone([String? id, String? full]) {
    final r = _find(id);
    if (r == null) return;
    if (full != null && full.length >= r.text.length) r.text = full;
    r.textDone = true;
    _evaluate();
  }

  /// [samples] of the reply's audio (24 kHz) are being handed to the host, in order.
  void audio(int samples, [String? id]) {
    if (samples <= 0) return;
    final now = _clock();
    _firstAudioAt ??= now;
    final r = _find(id);
    if (r != null) {
      r.audioStart ??= _handed;
      r.audioLen += samples;
    }
    _handed += samples;
    final start = _estEnd.isAfter(now) ? _estEnd : now;
    _estEnd = start.add(Duration(microseconds: samples * 1000000 ~/ rate));
    _evaluate();
  }

  /// The reply's audio is complete.
  void audioDone([String? id]) {
    final r = _find(id);
    if (r == null) return;
    r.audioDone = true;
    _evaluate();
  }

  /// The reply is over at the server (`response.done`, any status): its text and audio are
  /// complete. What was handed over still plays; only [cut] ends a reply early.
  void replyDone([String? id]) {
    final r = _find(id);
    if (r == null) return;
    r.textDone = true;
    r.audioDone = true;
    if (identical(r, _current)) _current = null;
    _evaluate();
  }

  /// The host reported its playout position.
  void playout(BithumanPlayout p) {
    // A count from before the audio unit restarted, or out of order: positions only move forward.
    if (p.fed < _reportedFed) return;
    _haveReports = true;
    _reportedFed = p.fed;
    final played = math.min(p.played, p.fed);
    _advancing = played > _played;
    if (played > _played) _played = played;
    _reportedAt = _clock();
    _evaluate();
  }

  /// Everything still open ends NOW with the words already heard (a barge-in, a typed turn,
  /// a hang-up). Later events for those replies are ignored.
  void cut() {
    if (_open.isEmpty) {
      _current = null;
      return;
    }
    final heard = _heard(_clock());
    for (final r in List<_Reply>.of(_open)) {
      _release(r, heard, cutting: true);
    }
    _open.clear();
    _current = null;
  }

  /// Re-evaluates against the clock: the handover estimate, and the carry between reports.
  void tick() => _evaluate();

  // ---------------------------------------------------------------- internals

  _Reply? _find(String? id) {
    if (id != null) {
      // Newest first: a relay that reuses one id for every reply still lands on the current one.
      for (final r in _open.reversed) {
        if (r.id == id) return r;
      }
      // An id never announced (no response.created seen): the current reply takes it.
      final c = _current;
      if (c != null && c.id == null) {
        c.id = id;
        return c;
      }
      return null;
    }
    return _current;
  }

  /// The heard position on the coordinate, now.
  int _heard(DateTime now) {
    if (_haveReports) {
      var p = _played;
      final at = _reportedAt;
      // Only while the voice is playing: before its first sound (a host still waiting for its
      // first frame) the position stands where it was reported.
      if (at != null && _advancing && p < _reportedFed) {
        final ms = now.difference(at).inMilliseconds.clamp(0, _extrapolateMs);
        p = math.min(_reportedFed, p + ms * rate ~/ 1000);
      }
      return math.min(p, _handed);
    }
    final first = _firstAudioAt;
    if (first == null || now.difference(first) < noPlayoutAfter) return 0;
    // No host report: the audio handed over, played at 1x from when it was handed.
    final ahead = _estEnd.difference(now).inMicroseconds;
    final unheard = ahead > 0 ? ahead * rate ~/ 1000000 : 0;
    return math.max(0, _handed - unheard);
  }

  void _evaluate() {
    if (_open.isEmpty) return;
    final heard = _heard(_clock());
    for (final r in List<_Reply>.of(_open)) {
      if (_release(r, heard)) _open.remove(r);
    }
  }

  /// Releases what [heard] allows for [r]; true when [r] is final.
  bool _release(_Reply r, int heard, {bool cutting = false}) {
    final text = r.text;
    final start = r.audioStart;
    final inReply = start == null ? 0 : (heard - start).clamp(0, r.audioLen);
    final heardAll = r.audioDone && start != null && inReply >= r.audioLen;
    final noAudio = r.audioDone && start == null;
    int target;
    if (r.textDone && r.audioDone) {
      target = (noAudio || heardAll || r.audioLen == 0)
          ? text.length
          : text.length * inReply ~/ r.audioLen;
    } else {
      final cjk = _cjk.hasMatch(text);
      final cps = cjk ? charsPerSecondCjk : charsPerSecond;
      var t = (inReply * cps / rate).floor();
      // Text and audio streaming side by side: the text's share of the audio so far. The
      // transcript tends to run ahead of the audio, so this errs ahead too — the smaller of
      // the two estimates wins.
      if (r.audioLen > 0) t = math.min(t, text.length * inReply ~/ r.audioLen);
      if (heardAll) t = text.length; // every sound heard; text that comes later shows at once
      target = math.min(text.length, t);
    }
    final whole = target >= text.length && r.textDone;
    final cutAt = whole ? text.length : _wordBoundary(text, target);
    if (cutAt > r.released) r.released = cutAt;
    final isFinal = cutting || (r.textDone && r.audioDone && (heardAll || noAudio) && r.released >= text.length);
    if (r.released > r.emitted || isFinal) {
      r.emitted = r.released;
      final shown = text.substring(0, r.released).trimRight();
      onCaption(BithumanSpokenText(
          reply: r.n, text: shown, isFinal: isFinal, interrupted: cutting && !(heardAll || noAudio && r.textDone)));
      final log = onLog;
      if (log != null) {
        log('[bhcaption] reply=${r.n} heard=$inReply/${r.audioLen}${r.audioDone ? '' : '+'} '
            'chars=${shown.length}/${text.length}${r.textDone ? '' : '+'}'
            '${isFinal ? (cutting ? ' final interrupted' : ' final') : ''} '
            'src=${_haveReports ? 'playout' : 'estimate'} hostMs=${_clock().millisecondsSinceEpoch}');
      }
    }
    return isFinal;
  }

  static final RegExp _cjk = RegExp(r'[぀-ヿ㐀-䶿一-鿿가-힯฀-๿]');

  /// The largest index <= [i] that ends a whole word of [s]: just before whitespace, or just
  /// after a character of a script written without spaces (each is a word of its own).
  static int _wordBoundary(String s, int i) {
    if (i <= 0) return 0;
    if (i >= s.length) i = s.length;
    for (var k = i; k > 0; k--) {
      if (k < s.length && _space(s.codeUnitAt(k))) return k;
      if (_cjk.hasMatch(s[k - 1])) return k;
    }
    return 0;
  }

  static bool _space(int c) => c == 0x20 || c == 0x0a || c == 0x09 || c == 0x0d || c == 0x3000;
}

class _Reply {
  _Reply(this.n, this.id);
  final int n;
  String? id;
  String text = '';
  bool textDone = false;
  bool audioDone = false;
  int? audioStart;
  int audioLen = 0;
  int released = 0;
  int emitted = 0;
}
