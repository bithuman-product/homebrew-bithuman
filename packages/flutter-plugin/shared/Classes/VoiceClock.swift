// VoiceClock.swift — Essence 2's two presenters on Apple: the voice-gated default with its stall guard
// (2.6.31), and the voice on its own clock (2.6.30, opt-in since 2.6.31: `BithumanAvatar.load(voiceClock: true)`).
//
// ★THE DEFAULT IS VOICE-GATED (2.6.31), BY DATA. The shipped Live app on 2.6.29's voice-gated presenter, on the
// iPhone 18 Pro (7 Sofia replies, 27.4 s voiced, 3 after barge-ins): 0 voice gaps of 40 ms or more (the largest
// shortfall 16 ms, at cut boundaries only), a frame on every one of 689 display ticks in speech, lip-sync ~18 ms,
// onset 161–503 ms. The voice on its own clock needs a 200 ms cushion there (no cushion: 160–200 ms gaps after a
// barge-in, from the 320 ms cadence of the engine's motion blocks), so on a fast device it only adds latency.
// The voice-gated presenter gets a STALL GUARD instead (StallGuard below): a tick with no frame while the
// reply's voice is waiting releases that tick's voice anyway, so the voice never waits more than one tick; the
// frames whose voice went ahead are then dropped (or shown without voice) until the picture is back in step.
// On a fast phone it never fires.
//
// THE VOICE ON ITS OWN CLOCK (opt-in). The voice-gated presenter releases each frame's 40 ms of voice
// only when that frame is shown, so it cannot lead the picture (in the engine's own 1x-arrival test on an
// M4: 2–4 gaps per 16 s reply without the guard, the worst 160 ms). Android plays the voice on its own clock
// and shows frames against it; with `voiceClock: true` Apple does the same:
//
//   - A reply's voice opens a CUSHION after its first speech frame is ready. Essence 2's motion
//     arrives in 8-frame blocks of ~320 ms, so the engine gets a head start before the voice runs.
//   - The voice is then scheduled a short lead ahead of the speaker, tick by tick, whatever the
//     picture does. Its clock is what the speaker has played: the HEARD position.
//   - Each 40 ms tick shows the frame whose audio is being heard. A frame whose audio has already
//     gone by is dropped while a newer frame is ready (pulled in the same tick); the newest frame is
//     shown even when late, so a slow engine is a late face, never a frozen one. A frame whose audio
//     is still ahead is held until the voice reaches it.
//
// No AVFoundation and no Flutter here, so it is tested on its own (test/swift/voice_clock_test.swift,
// scripts/test_swift_unit.sh). AvatarTexture (BithumanAvatarPlugin.swift) does the pulls, the
// publishing and the scheduling.
import Foundation

enum VoiceClockPolicy {
  /// ★SET BY DATA, NOT BY TASTE (the release gate's rule, 2026-10-02): the SMALLEST cushion that grades
  /// 0 voice gaps over 80 ms on the iPhone 18 Pro across a cold greeting, a barge-in and a burst
  /// arrival. Measured on that phone (2.6.31): 200 ms grades 0 on all three; with no cushion a
  /// barge-in's reply had gaps of 160–200 ms. The cause is the 320 ms cadence of the engine's motion
  /// blocks, not the engine's speed — so the number of frames ready at a reply's start does not
  /// predict the gap, and the cushion is a constant, the same on iOS and macOS. (Android plays the
  /// voice with no cushion: 0 gaps and 0 underruns on the Galaxy Z Flip5 with essence2-android 0.9.1.)
  static let cushionSeconds: Double = 0.200
  /// A/V offset (when a frame's audio starts being heard minus when the frame is shown): a frame whose
  /// audio started more than this before it could be shown is LATE (the lip-sync bound, ±40 ms).
  static let lateMs: Double = 40
  /// A frame is held while its audio starts more than this after now: half a 40 ms tick, so the frames
  /// shown land within ±20 ms of their audio.
  static let holdAheadMs: Double = 20
  /// A frame whose audio is further ahead than this is not held: the frame's stamp and the voice
  /// disagree (nothing in a working stream puts a frame this far ahead of what is heard — the engine
  /// keeps 8 frames, 320 ms), and holding it would freeze the face. It is shown in turn instead.
  static let maxHoldMs: Double = 600
  /// How far ahead of the speaker the voice is scheduled. The render tick is 40 ms; four of them
  /// absorb a late tick without the speaker running dry.
  static let leadSeconds: Double = 0.160
  /// The voice unit's rate (the realtime transport's PCM16) and the engine's coordinate.
  static let voiceRate: Double = 24_000
  static let engineRate: Double = 16_000
  /// One frame of engine audio: 640 samples at 16 kHz (25 fps).
  static let hop16: Int64 = 640
  /// A voice that stays dry this long ends the reply's open voice: the next reply waits for its own
  /// first frame (and the cushion) again. A shorter dry spell keeps the voice open, so audio that
  /// arrives late plays at once instead of waiting on a picture.
  static let closeAfterDrySeconds: Double = 1.0
}

/// Where the voice of the engine's open stream is, as HEARD. Its coordinate is the engine's own —
/// the audio pushed since the last `be_essence2_reset` — counted at the voice's rate.
final class VoiceClock {
  private struct Piece { let at: Double; let from: Int64; let count: Int64 }
  private var pieces: [Piece] = []
  /// Samples of this stream handed to the speaker.
  private(set) var scheduled: Int64 = 0
  /// Host time the last scheduled sample is heard; 0 while nothing is scheduled in this stream.
  private(set) var heardEnd: Double = 0
  let rate: Double

  init(rate: Double = VoiceClockPolicy.voiceRate) { self.rate = rate }

  /// A new stream (the engine was reset): the coordinate starts again at 0.
  func reset() {
    pieces.removeAll(keepingCapacity: true)
    scheduled = 0
    heardEnd = 0
  }

  /// [count] samples of the stream went to the speaker and are heard from host time [heardAt].
  /// Returns how long the speaker had been dry before them, in seconds (0: none, or the first piece).
  @discardableResult
  func add(_ count: Int64, heardAt: Double) -> Double {
    guard count > 0 else { return 0 }
    let start = max(heardAt, heardEnd)
    let dry = heardEnd > 0 ? max(0, start - heardEnd) : 0
    pieces.append(Piece(at: start, from: scheduled, count: count))
    if pieces.count > 512 { pieces.removeFirst(pieces.count - 512) }
    scheduled += count
    heardEnd = start + Double(count) / rate
    return dry
  }

  /// Samples of the stream heard by host time [t]: negative before the first sample is heard (the
  /// time still to go, at the voice's rate), held across a dry spell, `scheduled` once all is heard.
  /// nil while nothing is scheduled in this stream.
  func heard(at t: Double) -> Double? {
    guard let first = pieces.first else { return nil }
    if t < first.at { return Double(first.from) - (first.at - t) * rate }
    var lo = 0, hi = pieces.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if pieces[mid].at <= t { lo = mid } else { hi = mid - 1 }
    }
    let p = pieces[lo]
    return Double(p.from) + min(Double(p.count), (t - p.at) * rate)
  }

  /// [heard(at:)] in the engine's 16 kHz coordinate.
  func heard16(at t: Double) -> Double? {
    heard(at: t).map { $0 * VoiceClockPolicy.engineRate / rate }
  }

  /// [scheduled] in the engine's 16 kHz coordinate.
  var scheduled16: Double { Double(scheduled) * VoiceClockPolicy.engineRate / rate }
}

/// What a tick does with the speech frame at the head of the line.
enum FrameVerdict: Equatable {
  /// In step with the voice: show it.
  case show
  /// Its audio has gone by and a newer frame is ready: drop it and look at the next one, this tick.
  case dropLate
  /// Its audio has gone by and nothing newer is ready: show it anyway (a late face, not a frozen one).
  case showLate
  /// Its audio is still ahead: keep it for a later tick.
  case hold
  /// Its audio is not in the voice at all (the engine's padding past a reply's end), or so far ahead
  /// of it that the two disagree: show it in turn (never hold a face still for it).
  case showBeyondVoice
}

enum VoiceClockedPresenter {
  /// [avMs]: the frame's A/V offset if shown now — when its audio starts being heard minus now, in ms
  /// (negative: its audio already started). [newerReady]: the engine has another frame now.
  /// [beyondVoice]: the frame starts at or past the end of all the voice this stream has (scheduled +
  /// still queued).
  static func verdict(avMs: Double, newerReady: Bool, beyondVoice: Bool) -> FrameVerdict {
    if beyondVoice { return .showBeyondVoice }
    if avMs < -VoiceClockPolicy.lateMs { return newerReady ? .dropLate : .showLate }
    if avMs > VoiceClockPolicy.maxHoldMs { return .showBeyondVoice }
    if avMs > VoiceClockPolicy.holdAheadMs { return .hold }
    return .show
  }

  /// The A/V offset of the speech frame starting at engine sample [start16] with the voice heard up to
  /// [heard16] (16 kHz) now: when the frame's audio starts being heard minus now, in ms.
  static func avMs(heard16: Double, start16: Int64) -> Double {
    (Double(start16) - heard16) * 1000 / VoiceClockPolicy.engineRate
  }

  /// How much voice to hand the speaker now: enough to keep [lead] seconds scheduled past [now],
  /// rounded down to whole frames of voice (40 ms), at most [queued].
  static func pumpCount(now: Double, heardEnd: Double, queued: Int, lead: Double = VoiceClockPolicy.leadSeconds,
                        rate: Double = VoiceClockPolicy.voiceRate) -> Int {
    let ahead = max(0, heardEnd - now)
    let want = lead - ahead
    guard want > 0, queued > 0 else { return 0 }
    let unit = Int(rate * 0.04)
    let n = max(unit, Int(want * rate) / unit * unit)
    return min(queued, n)
  }
}

/// The voice-gated presenter's STALL GUARD (2.6.31). The voice-gated presenter releases a speech frame's
/// 40 ms of voice when the frame is shown, so an engine that falls behind would hold the voice. Each display
/// tick asks this guard:
///  - a speech frame was pulled: `speechFrame` says show it and release its voice (the normal case), or —
///    when the guard already released that frame's voice — drop it while a newer frame is ready, else show it
///    without voice (the picture catches up, the voice is never released twice);
///  - no voice released this tick (no speech frame, or only one whose voice the guard already released):
///    `noVoiceReleased` says release one tick of voice anyway when the reply's voice is playing (a frame was
///    shown since the voice last ran dry), voice is waiting, and a tick has passed since the last release. So the voice waits at most one tick (40 ms), and only after a reply has begun: the
///    reply's first frame still opens its voice, as before.
///  - the voice ran dry (nothing waiting): `voiceDry` — the next voice waits for its own frame again.
/// Platform-free, tested on its own (test/swift/voice_clock_test.swift: a slow fake engine).
final class StallGuard {
  /// A tick without a frame releases the voice once this long has passed since the last release (the tick
  /// is 40 ms; a little under it so a tick that runs a few ms early still counts).
  static let afterSeconds: Double = 0.035
  enum Verdict: Equatable { case showAndRelease, showWithoutVoice, drop }
  /// Ticks of voice released ahead of their frames, not yet matched by a frame.
  private(set) var debt = 0
  /// A frame of the current reply has been shown since the voice last ran dry.
  private(set) var replyPlaying = false
  private(set) var firings = 0
  private var lastReleaseAt: Double = 0

  /// A new stream (an engine reset, a barge-in): nothing owed, nothing playing.
  func reset() { debt = 0; replyPlaying = false; lastReleaseAt = 0 }

  func speechFrame(now: Double, newerReady: Bool) -> Verdict {
    if debt > 0 {
      debt -= 1
      return newerReady ? .drop : .showWithoutVoice
    }
    replyPlaying = true
    lastReleaseAt = now
    return .showAndRelease
  }

  /// This tick released no voice. True = release one tick of voice now (the caller does, and logs it).
  func noVoiceReleased(now: Double, voiceWaiting: Bool) -> Bool {
    guard replyPlaying, voiceWaiting, now - lastReleaseAt >= Self.afterSeconds else { return false }
    debt += 1
    firings += 1
    lastReleaseAt = now
    return true
  }

  /// Nothing of the voice is waiting: the next voice waits for its own frame (a reply's onset, as before).
  func voiceDry() { replyPlaying = false }
}

/// One reply's voice and picture, summarised in ONE log line per reply (`[bhvoice] REPLY ...`, which
/// the release gate reads): the voice's dry spells (count of 40 ms or more, how many over 80 ms, the
/// worst), first sound (the reply's first audio in -> its first sample heard), and the A/V offset of
/// every speech frame shown (when its audio starts being heard minus when it is shown, ms: positive =
/// the sound after the picture).
final class VoiceReplyMeter {
  let reply: Int
  let mode: String
  let cushionMs: Int
  var firstAudioAt: Double = 0
  var firstFrameAt: Double = 0
  private(set) var firstHeardAt: Double = 0
  private var lastEnd: Double = 0
  private(set) var gapsMs: [Double] = []
  private(set) var offsetsMs: [Double] = []
  private(set) var voiceSeconds: Double = 0
  var dropped = 0, lateShown = 0, beyond = 0, skipped: Int64 = 0, stallGuard = 0
  var bargedIn = false

  init(reply: Int, mode: String, cushionMs: Int) {
    self.reply = reply; self.mode = mode; self.cushionMs = cushionMs
  }

  /// [count] samples at [rate] were scheduled, heard from [heardAt].
  func voice(count: Int, heardAt: Double, rate: Double) {
    guard count > 0 else { return }
    if firstHeardAt == 0 { firstHeardAt = heardAt }
    if lastEnd > 0, heardAt > lastEnd { gapsMs.append((heardAt - lastEnd) * 1000) }
    let d = Double(count) / rate
    lastEnd = max(lastEnd, heardAt) + d
    voiceSeconds += d
  }

  func shown(avMs: Double) { offsetsMs.append(avMs) }

  var hasContent: Bool { voiceSeconds > 0 || !offsetsMs.isEmpty }

  /// Gaps of at least one frame (40 ms), and of more than 80 ms (the release gate's line).
  var gapCount: Int { gapsMs.filter { $0 >= 40 }.count }
  var over80: Int { gapsMs.filter { $0 > 80 }.count }

  func line() -> String {
    func pct(_ v: [Double], _ q: Double) -> Double {
      guard !v.isEmpty else { return 0 }
      let s = v.sorted(); return s[min(s.count - 1, Int(q * Double(s.count - 1) + 0.5))]
    }
    let absOff = offsetsMs.map { abs($0) }
    let first = firstAudioAt > 0 && firstHeardAt > 0 ? Int(((firstHeardAt - firstAudioAt) * 1000).rounded()) : -1
    let frame = firstAudioAt > 0 && firstFrameAt > 0 ? Int(((firstFrameAt - firstAudioAt) * 1000).rounded()) : -1
    return String(format: "[bhvoice] REPLY %ld mode=%@ cushionMs=%ld voiceMs=%ld firstSoundMs=%ld firstFrameMs=%ld "
                  + "gaps=%ld over80=%ld maxGapMs=%ld microGaps=%ld shown=%ld dropped=%ld lateShown=%ld beyond=%ld skipped=%lld "
                  + "avMs p50=%+.0f p95|%.0f| max|%.0f| over40=%ld stallGuard=%ld barged=%@",
                  reply, mode, cushionMs, Int((voiceSeconds * 1000).rounded()), first, frame,
                  gapCount, over80, Int((gapsMs.max() ?? 0).rounded()), gapsMs.filter { $0 < 40 }.count,
                  offsetsMs.count, dropped, lateShown, beyond, skipped,
                  pct(offsetsMs, 0.5), pct(absOff, 0.95), absOff.max() ?? 0,
                  absOff.filter { $0 > VoiceClockPolicy.lateMs }.count, stallGuard, bargedIn ? "yes" : "no")
  }
}
