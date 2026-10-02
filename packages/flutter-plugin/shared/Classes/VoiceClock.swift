// VoiceClock.swift — Essence 2's presenter on Apple plays the voice on its own clock (2.6.30).
//
// Until 2.6.29 the Apple presenter released each frame's 40 ms of voice only when that frame was
// shown ("voice-gated"). The voice could never lead the picture, so a slow or bursty engine was
// HEARD: on an M4 Mac, 2–4 gaps per 16 s reply, the worst 160 ms. Android has played the voice on
// its own clock and shown frames against it since 2.6.x; Apple now does the same:
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
  /// arrival. PROVISIONAL until that phone's run: on an M4 Mac both 200 and 400 ms graded 0 gaps
  /// (no cushion: 1–2 gaps of 160–200 ms per reply), so 200 ms is the value until the phone says.
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
  var dropped = 0, lateShown = 0, beyond = 0, skipped: Int64 = 0
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
                  + "avMs p50=%+.0f p95|%.0f| max|%.0f| over40=%ld barged=%@",
                  reply, mode, cushionMs, Int((voiceSeconds * 1000).rounded()), first, frame,
                  gapCount, over80, Int((gapsMs.max() ?? 0).rounded()), gapsMs.filter { $0 < 40 }.count,
                  offsetsMs.count, dropped, lateShown, beyond, skipped,
                  pct(offsetsMs, 0.5), pct(absOff, 0.95), absOff.max() ?? 0,
                  absOff.filter { $0 > VoiceClockPolicy.lateMs }.count, bargedIn ? "yes" : "no")
  }
}
