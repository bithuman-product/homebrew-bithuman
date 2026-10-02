// Captions in step with the voice (2.6.27): SpokenCaptioner on a FAKE clock.
//
// The model of a reply: its text and audio arrive in one burst (the relay streams a several-
// second reply in about a second), and the voice is then heard at 1x after the host's output
// latency. Each word's audio is proportional to its length (a uniform speaking rate), so the
// words heard at any instant are known exactly and the caption can be graded against them.

import 'package:bithuman/bithuman_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

const int kRate = 24000;

/// One scripted reply: [text] spoken at [cps] characters per second of audio.
class Script {
  Script(this.text, {this.cps = 15});
  final String text;
  final double cps;
  int get samples => (text.length / cps * kRate).round();

  /// Words fully heard once [heard] samples of this reply have played.
  int wordsHeard(int heard) {
    final chars = heard * text.length ~/ samples;
    var n = 0;
    var end = 0;
    for (final w in text.split(' ')) {
      end += w.length;
      if (end <= chars) n++;
      end += 1;
    }
    return n;
  }

  /// Chars fully heard (for scripts without spaces: one char is one word).
  int charsHeard(int heard) => heard * text.length ~/ samples;
}

int words(String s) => s.trim().isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

/// A host that plays at 1x after [latencyMs], reports every 100 ms while it plays, and at once
/// when it has played everything handed to it; drives a fake clock in 10 ms steps.
class Rig {
  Rig({this.latencyMs = 300, this.reports = true}) {
    cap = SpokenCaptioner(clock: () => now, onCaption: events.add);
  }
  final int latencyMs;
  final bool reports;
  DateTime now = DateTime(2026, 10, 1, 12);
  late final SpokenCaptioner cap;
  final events = <BithumanSpokenText>[];
  int fed = 0, played = 0;
  DateTime? _playFrom;
  DateTime _lastReport = DateTime(2000);
  int _lastReported = -1;
  bool cut = false;

  String get caption => events.isEmpty ? '' : events.last.text;

  void hand(int samples, [String? id]) {
    cap.audio(samples, id);
    fed += samples;
    _playFrom ??= now.add(Duration(milliseconds: latencyMs));
    if (reports && _lastReported < 0) _report(); // the first chunk: a source exists
  }

  void _report() {
    _lastReported = played;
    _lastReport = now;
    cap.playout(BithumanPlayout(played: played, fed: fed));
  }

  /// Advances the clock by [ms], playing at 1x and reporting as a host does.
  void step([int ms = 10]) {
    now = now.add(Duration(milliseconds: ms));
    final from = _playFrom;
    if (from != null && now.isAfter(from) && played < fed) {
      played = (played + ms * kRate ~/ 1000).clamp(0, fed);
    }
    if (reports && _lastReported >= 0) {
      final caughtUp = played >= fed && _lastReported < fed;
      if (caughtUp || (played != _lastReported && now.difference(_lastReport).inMilliseconds >= 100)) _report();
    }
    cap.tick();
  }

  /// The host's interrupt: everything handed over is discarded (played jumps to fed).
  void interrupt() {
    played = fed;
    if (reports) _report();
  }
}

/// Streams [s] in a burst: text in word deltas and audio in 100 ms deltas, all within
/// [burstMs], starting now. Returns the steps to run (each 10 ms).
void burst(Rig r, Script s, {int burstMs = 800, String? id, bool done = true, int textEndMs = -1}) {
  r.cap.replyStarted(id);
  final ws = s.text.split(' ');
  final chunk = kRate ~/ 10;
  final nAudio = (s.samples / chunk).ceil();
  final textEnd = textEndMs < 0 ? burstMs : textEndMs;
  var handedA = 0, handedW = 0;
  final steps = (textEnd > burstMs ? textEnd : burstMs) ~/ 10;
  for (var i = 1; i <= steps; i++) {
    final t = i * 10;
    while (handedA < nAudio && handedA * burstMs <= t * nAudio) {
      final n = handedA == nAudio - 1 ? s.samples - chunk * (nAudio - 1) : chunk;
      r.hand(n, id);
      handedA++;
    }
    while (handedW < ws.length && handedW * textEnd <= t * ws.length) {
      r.cap.text(handedW == 0 ? ws[0] : ' ${ws[handedW]}', id);
      handedW++;
    }
    if (handedA == nAudio) r.cap.audioDone(id);
    r.step();
  }
  if (done) r.cap.replyDone(id);
}

void main() {
  final long = Script('The quick brown fox jumps over the lazy dog and then it runs far '
      'away into the quiet woods where nobody can find it again until the morning comes.');

  test('a burst reply: the caption never leads the heard words by more than one, and is '
      'complete within 100 ms of the end of playout', () {
    final r = Rig();
    final t0 = r.now;
    burst(r, long);
    var worst = -99;
    DateTime? playoutEnd, finalAt;
    for (var i = 0; i < 1500 && finalAt == null; i++) {
      final heard = r.played;
      final lead = words(r.caption) - long.wordsHeard(heard);
      if (lead > worst) worst = lead;
      if (playoutEnd == null && r.played >= long.samples) playoutEnd = r.now;
      if (r.events.isNotEmpty && r.events.last.isFinal) finalAt = r.now;
      r.step();
    }
    expect(worst, lessThanOrEqualTo(1), reason: 'caption led the voice by $worst words');
    expect(finalAt, isNotNull);
    expect(r.events.last.text, long.text);
    expect(r.events.last.interrupted, isFalse);
    expect(finalAt!.difference(playoutEnd!).inMilliseconds, lessThanOrEqualTo(100));
    // It did not simply show everything on arrival: half way through, about half is shown.
    final mid = r.events.where((e) => e.text.isNotEmpty).toList();
    expect(mid.length, greaterThan(5), reason: 'released word by word, not in one piece');
    expect(playoutEnd.difference(t0).inMilliseconds, greaterThan(long.samples * 1000 ~/ kRate));
  });

  test('released words are monotonic: every event extends the previous one', () {
    final r = Rig();
    burst(r, long);
    for (var i = 0; i < 1500; i++) {
      r.step();
    }
    for (var i = 1; i < r.events.length; i++) {
      expect(r.events[i].text.startsWith(r.events[i - 1].text), isTrue,
          reason: '"${r.events[i - 1].text}" -> "${r.events[i].text}"');
      expect(r.events[i].reply, r.events[0].reply);
    }
    expect(r.events.where((e) => e.isFinal).length, 1);
  });

  test('barge-in mid-reply: a final interrupted event with only the heard words', () {
    final r = Rig();
    burst(r, long);
    // 2.5 s into the reply's playout.
    while (r.played < (2.5 * kRate).round()) {
      r.step();
    }
    final heard = r.played;
    r.cap.cut(); // the session cuts BEFORE it interrupts the host
    r.interrupt();
    for (var i = 0; i < 50; i++) {
      r.step();
    }
    final last = r.events.last;
    expect(last.isFinal, isTrue);
    expect(last.interrupted, isTrue);
    final heardWords = long.wordsHeard(heard);
    expect(words(last.text), lessThanOrEqualTo(heardWords + 1));
    expect(words(last.text), greaterThanOrEqualTo(heardWords - 1));
    expect(long.text.startsWith(last.text), isTrue);
    expect(last.text.length, lessThan(long.text.length));
    // The host's jump to `fed` after the interrupt released nothing more.
    expect(r.events.where((e) => e.isFinal).length, 1);
    expect(r.cap.busy, isFalse);
  });

  test('a reply whose text finishes after its audio: shown as heard, complete when the text is', () {
    final s = Script('Short audio but the transcript keeps arriving long after the voice has ended.');
    final r = Rig();
    // Audio in 300 ms; text trickles in over 7 s (the voice is ~5.2 s long).
    burst(r, s, burstMs: 300, textEndMs: 7000, done: false);
    var worst = -99;
    for (var i = 0; i < 300; i++) {
      final lead = words(r.caption) - s.wordsHeard(r.played);
      if (lead > worst) worst = lead;
      r.step();
    }
    expect(worst, lessThanOrEqualTo(1));
    expect(r.played, s.samples, reason: 'the voice has ended');
    expect(r.events.last.isFinal, isFalse, reason: 'the text is not complete yet');
    final textDoneAt = r.now;
    r.cap.textDone(null, s.text);
    r.cap.replyDone();
    r.step();
    expect(r.events.last.isFinal, isTrue);
    expect(r.events.last.text, s.text);
    expect(r.now.difference(textDoneAt).inMilliseconds, lessThanOrEqualTo(100));
  });

  test('a CJK reply (no spaces) is released character by character, never ahead', () {
    final s = Script('今天天气很好我们一起去公园散步吧然后去吃午饭', cps: 5);
    final r = Rig();
    burst(r, s);
    var worst = -99;
    for (var i = 0; i < 1000 && !(r.events.isNotEmpty && r.events.last.isFinal); i++) {
      final lead = r.caption.length - s.charsHeard(r.played);
      if (lead > worst) worst = lead;
      r.step();
    }
    expect(worst, lessThanOrEqualTo(1));
    expect(r.events.last.text, s.text);
    expect(r.events.length, greaterThan(5));
  });

  test('no playout reports: estimated from the handover after 1 s, still complete at the end', () {
    final r = Rig(reports: false);
    burst(r, long);
    expect(r.events, isEmpty, reason: 'nothing before the estimate starts');
    for (var i = 0; i < 1500 && !(r.events.isNotEmpty && r.events.last.isFinal); i++) {
      r.step();
    }
    expect(r.cap.hasPlayoutReports, isFalse);
    expect(r.events.last.isFinal, isTrue);
    expect(r.events.last.text, long.text);
    expect(r.events.length, greaterThan(5));
  });

  test('two replies in a row: reply numbers, each final, the second starts empty', () {
    final r = Rig();
    final a = Script('First answer is here.');
    final b = Script('And a second one follows it.');
    burst(r, a, id: 'r1');
    for (var i = 0; i < 400; i++) {
      r.step();
    }
    burst(r, b, id: 'r2');
    for (var i = 0; i < 400; i++) {
      r.step();
    }
    final finals = r.events.where((e) => e.isFinal).toList();
    expect(finals.map((e) => e.reply), [1, 2]);
    expect(finals.map((e) => e.text), [a.text, b.text]);
    final firstOfTwo = r.events.firstWhere((e) => e.reply == 2);
    expect(b.text.startsWith(firstOfTwo.text), isTrue);
  });

  test('a cancelled reply\'s late text (another id) never reaches the next caption', () {
    final r = Rig();
    burst(r, Script('One two three four five six seven.'), id: 'old', done: false);
    r.cap.cut();
    r.interrupt();
    r.cap.text(' eight nine', 'old');
    r.cap.replyStarted('new');
    r.cap.text('Fresh', 'new');
    r.cap.textDone('new');
    r.cap.replyDone('new'); // no audio at all: released whole
    expect(r.events.last.reply, 2);
    expect(r.events.last.text, 'Fresh');
    expect(r.events.where((e) => e.reply == 1 && e.text.contains('eight')), isEmpty);
  });

  // ★2.6.28: a reply that stopped part-way (response.done cancelled/incomplete, or superseded by
  // the next reply after a reconnect) has ALL its transcript but only some of its audio. The
  // proportional mapping used to release the whole transcript once the received audio was heard.
  /// Hands [frac] of [s]'s audio and ALL of its text (the transcript runs ahead), then stops.
  void partialBurst(Rig r, Script s, double frac, {String? id}) {
    r.cap.replyStarted(id);
    final chunk = kRate ~/ 10;
    final total = (s.samples * frac).round();
    var handed = 0;
    final ws = s.text.split(' ');
    for (var i = 0; i < ws.length; i++) {
      r.cap.text(i == 0 ? ws[i] : ' ${ws[i]}', id);
    }
    while (handed < total) {
      final n = (total - handed).clamp(0, chunk);
      r.hand(n, id);
      handed += n;
      r.step();
    }
  }

  Script calib() => Script('Calibration words spoken whole at the voice rate.');
  final partialText = Script('Alpha bravo charlie delta echo foxtrot golf hotel india juliet '
      'kilo lima mike november oscar papa quebec romeo sierra tango.');

  void calibrate(Rig r) {
    burst(r, calib(), id: 'c');
    for (var i = 0; i < 600; i++) {
      r.step();
    }
    expect(r.events.last.isFinal, isTrue);
  }

  test('a reply cancelled part-way releases only the words its audio carried', () {
    final r = Rig();
    calibrate(r);
    final heardFrac = 0.4;
    partialBurst(r, partialText, heardFrac, id: 'p');
    r.cap.replyDone('p', false); // response.done status=cancelled
    for (var i = 0; i < 800; i++) {
      r.step();
    }
    final fin = r.events.lastWhere((e) => e.reply == 2);
    expect(fin.isFinal, isTrue);
    expect(fin.interrupted, isTrue, reason: 'it ended short of its transcript');
    final voiced = partialText.wordsHeard((partialText.samples * heardFrac).round());
    expect(words(fin.text), lessThanOrEqualTo(voiced),
        reason: 'never a word whose audio did not arrive (${fin.text})');
    expect(words(fin.text), greaterThanOrEqualTo(voiced - 2), reason: 'and not far behind it');
  });

  test('a reply superseded mid-way (a reconnect lost its done) is capped the same way', () {
    final r = Rig();
    calibrate(r);
    partialBurst(r, partialText, 0.5, id: 'p');
    r.cap.replyStarted('next'); // the server's next reply: no done for 'p' ever comes
    for (var i = 0; i < 800; i++) {
      r.step();
    }
    final fin = r.events.lastWhere((e) => e.reply == 2);
    expect(fin.isFinal, isTrue);
    expect(words(fin.text), lessThanOrEqualTo(partialText.wordsHeard((partialText.samples * 0.5).round())));
    expect(fin.text.contains('tango'), isFalse);
  });

  test('a cancelled reply with no audio at all releases nothing; a whole one superseded stays whole',
      () {
    final r = Rig();
    r.cap.replyStarted('a');
    r.cap.text('Words that were never voiced.', 'a');
    r.cap.replyDone('a', false);
    expect(r.events.last.reply, 1);
    expect(r.events.last.text, '');
    expect(r.events.last.isFinal, isTrue);
    // A reply whose text and audio both completed is whole even if its done event was lost.
    final b = Script('Complete before the next one started.');
    burst(r, b, id: 'b', done: false);
    r.cap.textDone('b');
    r.cap.replyStarted('c');
    for (var i = 0; i < 600; i++) {
      r.step();
    }
    final fin = r.events.lastWhere((e) => e.reply == 2);
    expect(fin.text, b.text);
    expect(fin.interrupted, isFalse);
  });

  test('BithumanPlayout.fromMap: played is clamped to fed; malformed pushes are refused', () {
    expect(BithumanPlayout.fromMap({'played': 10, 'fed': 5})!.played, 5);
    expect(BithumanPlayout.fromMap({'played': 3, 'fed': 5})!.caughtUp, isFalse);
    expect(BithumanPlayout.fromMap({'played': 5, 'fed': 5})!.caughtUp, isTrue);
    expect(BithumanPlayout.fromMap({'played': -1, 'fed': 5}), isNull);
    expect(BithumanPlayout.fromMap({'fed': 5}), isNull);
    expect(BithumanPlayout.fromMap(null), isNull);
  });
}
