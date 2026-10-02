// Essence 2 on Apple (shared/Classes/VoiceClock.swift): the voice on its own clock (2.6.30, opt-in): the heard
// position, the per-tick verdict on a frame, how much voice goes to the speaker, and the per-reply line.
// Then a 16 s reply through a SLOW engine (20 fps against a 25 fps reply), presented both ways: the
// pre-2.6.30 voice-gated presenter (each frame's 40 ms of voice released when it is shown) and the
// voice on its own clock, with the same frame-arrival schedule. Plain Swift: scripts/test_swift_unit.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failures += 1; print("  FAIL (line \(line)) \(what)") } else { print("  PASS \(what)") }
}
func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

// ── VoiceClock ───────────────────────────────────────────────────────────────────────────────────
let c = VoiceClock()
check(c.heard(at: 10) == nil, "nothing scheduled: no position")
check(c.add(2400, heardAt: 10.0) == 0, "the stream's first piece is not a gap")
check(near(c.heard(at: 9.9), -2400), "before the first sample is heard the position runs negative (0.1 s to go)")
check(near(c.heard(at: 10.05), 1200), "half of a 0.1 s piece heard 50 ms in")
check(c.add(2400, heardAt: 10.02) == 0, "a piece scheduled while the speaker is busy queues behind it (no gap)")
check(near(c.heard(at: 10.15), 3600), "the queued piece starts where the first ends (10.1 s)")
check(near(c.heard(at: 10.5), 4800), "everything heard: the position holds at what was scheduled")
check(near(c.heardEnd, 10.2), "heardEnd = 10.0 + 0.2 s")
let dry = c.add(2400, heardAt: 10.3)
check(abs(dry - 0.1) < 1e-9, "a piece after the speaker ran dry reports the dry spell (100 ms)")
check(near(c.heard(at: 10.25), 4800), "during the dry spell the position holds")
check(near(c.heard16(at: 10.35), (4800 + 1200) * 2.0 / 3.0), "the engine's 16 kHz coordinate is 2/3 of the voice's")
check(near(c.scheduled16, 7200 * 2.0 / 3.0), "scheduled16")
c.reset()
check(c.heard(at: 11) == nil && c.scheduled == 0 && c.heardEnd == 0, "reset: a new stream from 0")

// ── the verdict ──────────────────────────────────────────────────────────────────────────────────
typealias P = VoiceClockedPresenter
check(P.verdict(avMs: 0, newerReady: true, beyondVoice: false) == .show, "its audio starts now: show")
check(P.verdict(avMs: -39, newerReady: true, beyondVoice: false) == .show, "its audio started 39 ms ago: show")
check(P.verdict(avMs: 20, newerReady: true, beyondVoice: false) == .show, "its audio starts within half a tick: show")
check(P.verdict(avMs: -41, newerReady: true, beyondVoice: false) == .dropLate, "late with a newer frame ready: drop it this tick")
check(P.verdict(avMs: -300, newerReady: false, beyondVoice: false) == .showLate, "late with nothing newer: show it (never a frozen face)")
check(P.verdict(avMs: 21, newerReady: true, beyondVoice: false) == .hold, "early: hold it")
check(P.verdict(avMs: 601, newerReady: true, beyondVoice: false) == .showBeyondVoice,
      "far ahead of the voice (stamp and voice disagree): shown in turn, never a frozen face")
check(P.verdict(avMs: 500, newerReady: false, beyondVoice: true) == .showBeyondVoice, "past the voice's end (padding): show in turn")
check(abs(P.avMs(heard16: 640, start16: 640)) < 1e-9, "a frame whose audio starts being heard now: 0 ms")
check(abs(P.avMs(heard16: 1280, start16: 640) - -40) < 1e-9, "a frame whose audio has just gone by: -40 ms")

// ── how much voice goes to the speaker ───────────────────────────────────────────────────────────
check(P.pumpCount(now: 0, heardEnd: 0, queued: 100_000) == 3840, "dry speaker: the whole lead (160 ms = 3840 at 24 kHz)")
check(P.pumpCount(now: 0, heardEnd: 0.1, queued: 100_000) == 960, "100 ms already scheduled: one more 40 ms frame of voice")
check(P.pumpCount(now: 0, heardEnd: 0.2, queued: 100_000) == 0, "more than the lead scheduled: nothing")
check(P.pumpCount(now: 0, heardEnd: 0, queued: 500) == 500, "never more than is queued")
check(P.pumpCount(now: 0, heardEnd: 0, queued: 0) == 0, "nothing queued: nothing")

// ── the per-reply line ───────────────────────────────────────────────────────────────────────────
let m = VoiceReplyMeter(reply: 3, mode: "clock", cushionMs: 200)
m.firstAudioAt = 1.0
m.voice(count: 2400, heardAt: 1.5, rate: 24_000)        // 1.5 .. 1.6
m.voice(count: 2400, heardAt: 1.6, rate: 24_000)        // no gap
m.voice(count: 2400, heardAt: 1.75, rate: 24_000)       // 50 ms gap
m.voice(count: 2400, heardAt: 1.95, rate: 24_000)       // 100 ms gap
m.voice(count: 2400, heardAt: 2.06, rate: 24_000)       // 10 ms micro gap
for o in [-10.0, 5, 12, 60] { m.shown(avMs: o) }
check(m.gapCount == 2 && m.over80 == 1, "gaps of 40 ms or more: 2, over 80 ms: 1")
let ln = m.line()
check(ln.hasPrefix("[bhvoice] REPLY 3 mode=clock cushionMs=200 voiceMs=500 firstSoundMs=500 "), "the line: reply, mode, cushion, voice, first sound")
check(ln.contains("gaps=2 over80=1 maxGapMs=100 microGaps=1 shown=4"), "the line: gaps, worst, micro gaps, frames shown")
check(ln.contains("over40=1 stallGuard=0 barged=no"), "the line: frames shown more than 40 ms off, stall-guard releases")

// ── a 16 s reply through the engine, both presenters ─────────────────────────────────────────────
// The reply's audio arrives at once (a burst: the realtime transport). The engine renders frames in
// 8-frame blocks (frame k carries audio [k*640, (k+1)*640) at 16 kHz), the first block 0.4 s after the
// audio, then one block every [block] seconds, holding at most 16 ready. The display ticks every
// 40 ms; the speaker hears what was scheduled after 20 ms of output latency.
struct Sim { var gaps: [Double] = []; var off: [Double] = []; var dropped = 0; var late = 0 }
func simulate(block: Double, gated: Bool, frames: Int = 400) -> Sim {
  var r = Sim()
  var rendered = 0, pulled = 0, nextBlock = 0.4
  func advance(_ now: Double) {
    while nextBlock <= now && rendered < frames {
      if rendered - pulled >= 16 { nextBlock = now + block; break }
      rendered = min(frames, rendered + 8); nextBlock += block
    }
  }
  let lat = 0.020
  var tick = 0.0
  if gated {
    var lastEnd = 0.0
    while pulled < frames && tick < 60 {
      advance(tick)
      if rendered > pulled {
        pulled += 1
        let start = max(lastEnd, tick + lat)
        if lastEnd > 0, start - lastEnd > 1e-9 { r.gaps.append((start - lastEnd) * 1000) }
        r.off.append((start - tick) * 1000)
        lastEnd = start + 0.04
      }
      tick += 0.04
    }
    return r
  }
  let clock = VoiceClock()
  var queued = frames * 960, open = false, firstAt = -1.0
  var held: Int? = nil
  while tick < 60 {
    advance(tick)
    if open {
      let n = P.pumpCount(now: tick, heardEnd: clock.heardEnd, queued: queued)
      if n > 0 {
        let d = clock.add(Int64(n), heardAt: max(clock.heardEnd, tick + lat))
        if d > 0 { r.gaps.append(d * 1000) }
        queued -= n
      }
    }
    var h16 = open ? clock.heard16(at: tick) : nil
    loop: while true {
      if held == nil { guard rendered > pulled else { break loop }; held = pulled; pulled += 1 }
      guard let k = held else { break loop }
      if !open {
        if firstAt < 0 { firstAt = tick }
        guard tick - firstAt + 0.001 >= VoiceClockPolicy.cushionSeconds else { break loop }
        open = true
        let n = P.pumpCount(now: tick, heardEnd: clock.heardEnd, queued: queued)
        clock.add(Int64(n), heardAt: tick + lat); queued -= n
        h16 = clock.heard16(at: tick)
      }
      let off = P.avMs(heard16: h16!, start16: Int64(k) * 640)
      switch P.verdict(avMs: off, newerReady: rendered > pulled, beyondVoice: false) {
      case .dropLate: r.dropped += 1; held = nil; continue loop
      case .hold: break loop
      case .show: r.off.append(off); held = nil; break loop
      case .showLate: r.off.append(off); r.late += 1; held = nil; break loop
      case .showBeyondVoice: held = nil; break loop
      }
    }
    if queued == 0 && tick > clock.heardEnd && held == nil && pulled >= frames { break }
    tick += 0.04
  }
  return r
}
// A slow engine (16 fps: 8 frames every 0.5 s).
let gs = simulate(block: 0.5, gated: true), cs = simulate(block: 0.5, gated: false)
let gsOver80 = gs.gaps.filter { $0 > 80 }.count
check(gsOver80 > 10, "voice-gated, slow engine: a choppy voice (\(gs.gaps.filter { $0 >= 40 }.count) gaps >= 40 ms, \(gsOver80) over 80 ms, worst \(Int(gs.gaps.max() ?? 0)) ms)")
check(cs.gaps.filter { $0 >= 40 }.isEmpty, "voice on its own clock, the same slow engine: no voice gap")
check(cs.off.count + cs.dropped == 400, "every frame is shown or dropped (\(cs.off.count) shown, \(cs.dropped) dropped, \(cs.late) shown late): the face keeps moving")
// An engine at real time, in blocks (25 fps: 8 frames every 0.32 s).
let gr = simulate(block: 0.32, gated: true), cr = simulate(block: 0.32, gated: false)
check(gr.gaps.filter { $0 > 80 }.isEmpty, "voice-gated, real-time engine: no gap over 80 ms")
check(cr.gaps.filter { $0 >= 40 }.isEmpty, "voice on its own clock, real-time engine: no voice gap")
check(cr.dropped == 0 && cr.late == 0 && cr.off.count == 400, "real-time engine: every frame shown, none late or dropped")
check(cr.off.allSatisfy { abs($0) <= 40 }, "real-time engine: every frame within 40 ms of its voice (worst \(Int(cr.off.map { abs($0) }.max() ?? 0)) ms)")

// ── the voice-gated default's STALL GUARD (2.6.31) ───────────────────────────────────────────────
let g = StallGuard()
check(g.noVoiceReleased(now: 1.0, voiceWaiting: true) == false, "before a reply's first frame the guard never releases (the onset waits for its frame)")
check(g.speechFrame(now: 1.0, newerReady: false) == .showAndRelease, "a frame: show it and release its voice")
check(g.noVoiceReleased(now: 1.02, voiceWaiting: true) == false, "less than a tick since the last release: wait")
check(g.noVoiceReleased(now: 1.04, voiceWaiting: true) == true && g.debt == 1, "a tick without a frame: release the voice, one frame owed")
check(g.speechFrame(now: 1.08, newerReady: true) == .drop && g.debt == 0, "the owed frame, a newer one ready: drop it")
check(g.speechFrame(now: 1.08, newerReady: true) == .showAndRelease, "the next frame is in step again")
check(g.noVoiceReleased(now: 1.12, voiceWaiting: true) && g.speechFrame(now: 1.16, newerReady: false) == .showWithoutVoice,
      "the owed frame with nothing newer: shown without voice (its voice already went)")
g.voiceDry()
check(g.noVoiceReleased(now: 2.0, voiceWaiting: true) == false, "after the voice ran dry the next voice waits for its frame again")
g.reset(); check(g.debt == 0 && !g.replyPlaying, "reset: nothing owed, nothing playing")

// The release gate (10x Production): through a SLOW engine the guard never holds the voice more than ~40 ms.
// A 16 s reply, all audio arrived, frames rendered in 8-frame blocks; display ticks every 40 ms with a little
// jitter; each release = 40 ms of voice heard from max(end of the voice so far, now + 20 ms).
struct GatedRun { var gaps: [Double] = []; var maxHold = 0.0; var firings = 0; var shown = 0; var dropped = 0
                  var noVoice = 0; var av: [Double] = [] }
func gated(block: Double, guardOn: Bool, frames: Int = 400, firstBlockAt: Double = 0.4) -> GatedRun {
  var r = GatedRun()
  let sg = StallGuard()
  var rendered = 0, pulled = 0, nextBlock = firstBlockAt
  var released = 0, heardEnd = 0.0, lastRelease = -1.0, tick = 0.0, n = 0
  func release(_ now: Double) {
    let start = max(heardEnd, now + 0.020)
    if heardEnd > 0, start - heardEnd > 1e-9 { r.gaps.append((start - heardEnd) * 1000) }
    if lastRelease >= 0 { r.maxHold = max(r.maxHold, now - lastRelease) }
    lastRelease = now; heardEnd = start + 0.04; released += 1
  }
  while released < frames && tick < 90 {
    while nextBlock <= tick && rendered < frames { rendered = min(frames, rendered + 8); nextBlock += block }
    var releasedVoice = false
    var pulls = 0
    pull: while rendered > pulled {
      pulled += 1; pulls += 1
      if !guardOn { r.shown += 1; release(tick); releasedVoice = true; break pull }
      switch sg.speechFrame(now: tick, newerReady: pulls < 8 && rendered > pulled) {
      case .drop: r.dropped += 1; continue pull
      case .showWithoutVoice: r.shown += 1; r.noVoice += 1
      case .showAndRelease: r.shown += 1; r.av.append((max(heardEnd, tick + 0.020) - tick) * 1000); release(tick); releasedVoice = true
      }
      break pull
    }
    let waiting = released < frames
    if !waiting { sg.voiceDry() }
    else if guardOn, !releasedVoice, sg.noVoiceReleased(now: tick, voiceWaiting: true) { release(tick); r.firings += 1 }
    n += 1
    tick = Double(n) * 0.04 + (n % 3 == 0 ? 0.003 : 0)   // a tick now and then 3 ms late
  }
  return r
}
let slowOff = gated(block: 0.5, guardOn: false), slowOn = gated(block: 0.5, guardOn: true)
let slowerOn = gated(block: 1.0, guardOn: true)
check(slowOff.gaps.filter { $0 > 80 }.count > 10, "voice-gated with NO guard, slow engine (16 fps): the voice is held (\(slowOff.gaps.filter { $0 > 80 }.count) gaps over 80 ms, worst \(Int(slowOff.gaps.max() ?? 0)) ms)")
check(slowOn.maxHold <= 0.0435, "with the guard, slow engine: the voice is never held more than one tick (longest wait between releases \(Int((slowOn.maxHold * 1000).rounded())) ms)")
check(slowOn.gaps.filter { $0 >= 40 }.isEmpty, "with the guard, slow engine: no voice gap of 40 ms or more (worst \(Int((slowOn.gaps.max() ?? 0).rounded())) ms, \(slowOn.firings) guard releases)")
check(slowerOn.maxHold <= 0.0435 && slowerOn.gaps.filter { $0 >= 40 }.isEmpty, "with the guard, an engine at 8 fps: still never held more than one tick (\(Int((slowerOn.maxHold * 1000).rounded())) ms)")
check(slowOn.dropped > 0 && slowOn.shown > 0, "the frames whose voice went ahead are dropped or shown without voice; the face keeps moving (\(slowOn.shown) shown, \(slowOn.dropped) dropped, \(slowOn.noVoice) without voice, \(slowOn.firings) guard releases)")
let fastOn = gated(block: 0.32, guardOn: true, firstBlockAt: 0.1), fastOff = gated(block: 0.32, guardOn: false, firstBlockAt: 0.1)
check(fastOn.firings == 0 && fastOn.dropped == 0 && fastOn.noVoice == 0, "a real-time engine: the guard never fires; every frame releases its own voice")
check(fastOn.gaps == fastOff.gaps && fastOn.shown == fastOff.shown, "a real-time engine: the guard changes nothing (the same releases and frames as without it)")

print(failures == 0 ? "voice_clock_test: ALL PASS" : "voice_clock_test: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
