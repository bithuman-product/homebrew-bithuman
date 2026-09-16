package ai.bithuman.flutter

import ai.bithuman.expression2.Expression2Avatar
import ai.bithuman.expression2.Expression2IdleLoop
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import android.view.Choreographer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.LinkedBlockingQueue

/**
 * The agent's voice and the frames generated from it, presented as ONE unit.
 *
 * The engine generates video from audio, so a frame and the samples it came from are
 * one object. `Expression2Frame.presentationTimeUs` is what binds them: it places each
 * frame on the timeline of the audio that was fed in, so we can cut that frame's own
 * samples out of the pending audio.
 *
 * Three rules from the A/V sync contract, and they are different rules:
 *
 *  - ADMISSION (4a). A unit is released only when complete — never a frame without
 *    its samples, never samples without their frame. Without this the speaker runs
 *    ahead at start-up: measured on a Galaxy S25+, 2.8 s of voice before the engine
 *    had produced its first frame.
 *
 *  - WRITE-AHEAD (4b). A unit is an atom of presentation, not of production. The
 *    writer stays [LEAD] whole units ahead of the device and the presenter is
 *    decoupled from it. Deriving "may I produce the next unit" from "has the current
 *    unit been presented" is circular and hangs before a sound is made: every audio
 *    device has a start threshold. Measured — `head` stuck at 0 with the track
 *    reporting PLAYING.
 *
 *  - PRESENTATION (4). A frame is shown when P — the samples the DEVICE has actually
 *    consumed — reaches it. P is the clock. No timer participates. The presenter
 *    runs once per vsync on the main looper and shows the NEWEST due unit; older
 *    units due in the same vsync are counted (`coalesced`), never shown late.
 *
 * IDLE (6) is the same machinery, not a second one. Between turns the producer emits
 * idle units — a frame of the identity's own idle clip plus a frame's worth of
 * silence — admitted and presented exactly like speech. So there is one clock, one
 * state machine, and no frozen frame. `pts` is the session's own monotonic sample
 * count and spans both, so idle and speech cannot disagree about where they are.
 * The idle frame is decoded IN PLACE by the SDK (`Expression2IdleLoop.next` fills a
 * slot of the same bitmap ring speech uses): every frame of the clip, in order, with
 * the wrap where the clip ends — the SDK logs each wrap with its index. Nothing here
 * holds the clip and nothing here decides where it loops.
 */
class AvatarPlayer(
    private val avatar: Expression2Avatar,
    /** The identity's idle clip, the SDK's own cursor over it. Null if the model has none. */
    private val idleLoop: Expression2IdleLoop?,
    /**
     * ★ Whether the HOST APP is a debuggable build (`ApplicationInfo.FLAG_DEBUGGABLE`).
     * Every dev lever below is gated on this, so a release APK on a customer's phone
     * cannot be steered by a system property. On 2026-09-15 a measurement script set
     * `debug.bh.marker.every=40` on the test Galaxy and never reset it; the property
     * is persistent, so every build installed afterwards — release builds included —
     * shipped a WHITE frame and a 12 ms 2 kHz click every 40th speech unit (2.0 s)
     * while the agent talked. The owner reported it as "a screen flash at every chunk
     * and a weird 'do' sound every second". A dev lever that a release build honours
     * is not a dev lever; it is a latent customer defect switched on by whoever last held
     * the phone.
     */
    private val debuggable: Boolean = false,
    /**
     * ★ MEASUREMENT ONLY, AND IT CHANGES THE AUDIO PATH — say so wherever a number from
     * such a build is quoted. A chat app plays through `USAGE_VOICE_COMMUNICATION`: that
     * is the stream the platform runs its echo canceller on, and a conversation needs it.
     * Android also refuses to let anything capture that stream, so a screen recording of
     * the device cannot contain the voice the avatar spoke and an A/V offset has nothing
     * to measure against — the microphone hears the room instead (measured 2026-09-15:
     * envelope correlation -0.033 against the known drive; the grader refused the number,
     * correctly). With the file drive there is no microphone and no echo to cancel, so
     * the track is `USAGE_MEDIA` and the recording contains the app's own audio.
     */
    private val capturable: Boolean = false,
    private val onFrame: (Bitmap) -> Unit,
) {
    /** Live health of the pipeline — surfaced by the app's debug overlay. */
    val stats = AvatarStats()

    // Is a starved presenter BLOCKED IN pull (the SDK's lock, behind a render) or is it
    // getting null and having nothing to emit? Different defects, different fixes.
    @Volatile private var pullCalls = 0L
    @Volatile private var pullNanos = 0L
    @Volatile private var pullMaxMs = 0L
    @Volatile private var pullOver50 = 0L
    @Volatile private var nullPulls = 0L
    @Volatile private var nIdle = 0
    @Volatile private var nSpeech = 0
    @Volatile private var where = "init"

    private object Reset
    private object Tail

    /** A complete unit, already admitted to the device. */
    private class AvUnit(val ptsSamples: Long, val frame: Bitmap, val epoch: Int,
                         val speech: Boolean, val turnGen: Int, val audio: ByteArray, val seq: Long = 0,
                         /** S = a frame with its own audio, C = catch-up, H = held frame + silence, T = tail, I = idle. */
                         val kind: Char = 'S')

    private val inbox = LinkedBlockingQueue<Any>()
    private val toWrite = ArrayBlockingQueue<AvUnit>(LEAD)     // producer -> writer
    private val toPresent = ArrayBlockingQueue<AvUnit>(PRESENT_QUEUE)  // writer -> presenter
    @Volatile private var running = true
    @Volatile private var epoch = 0

    /**
     * THE AGENT'S AUDIO, AS FED — one byte stream, and the engine says where each
     * frame falls on it.
     *
     * `Expression2Frame.audioSample` (expression2-android 0.4.5) is the first 16 kHz
     * sample of the audio a frame was generated from, counted over everything fed
     * since the last reset. Feeding is 24 kHz PCM16 in and 16 kHz float out, three
     * bytes of stream per fed sample, so a frame's own audio is exactly
     * `[3 * audioSample, 3 * audioSample + BYTES_PER_FRAME)` — the app does arithmetic
     * where it used to keep a model of the engine's segments. What that deletes:
     * utterance marks, an origin per utterance, detecting the frame-index restart,
     * the "reply ended but the engine joined the audio anyway" case, and a 120 ms
     * per-frame grace timer. All of it was inference about a boundary the app cannot
     * see from outside, and it guessed wrong once in twelve replies (log `bhutt`,
     * 2026-09-15: 209 units admitted against the wrong audio).
     *
     * Two facts remain, and each is a comparison rather than a guess:
     *  - HEAD. Since 0.4.6 (#681) frame n IS audio-frame n: an utterance's first
     *    frame is index 0 and carries its first 40 ms. A unit still carries everything
     *    from `head` up to the end of its frame's window, so a remainder with no frame
     *    of its own (a joined segment) goes out under the frame that follows it.
     *  - TAIL. A chunk's frames stop up to 0.4 s short of the audio. When the engine
     *    says the utterance is closed, what is left plays under the last frame.
     *  - LATE. Between chunks the audio in hand plays under the last frame rather than
     *    waiting for its frame (see the hold in [produce]); a frame that arrives after
     *    its audio has gone out is dropped, counted as `stale`.
     */
    private val audioLock = Any()
    private var audio = ByteArray(1 shl 20)
    private var audioHead = 0L                 // stream offset of audio[0]
    private var audioLen = 0L                  // stream offset one past the last byte fed
    private var head = 0L                      // first stream byte not yet admitted
    /** Bytes of a 24 kHz chunk that did not make a whole 16 kHz sample; fed with the next. */
    private var carry = ByteArray(0)
    /** Stream offsets where the session said a reply's audio stopped; bounds the final drain. */
    private val replyEnds = ArrayDeque<Long>()
    /** How many reply ends `head` has passed — which reply the next byte belongs to. */
    private var replySeq = 0
    /** [replySeq] when the held frame was admitted: audio may ride under it only within that reply. */
    private var heldFrameReply = -1
    @Volatile private var nStale = 0
    @Volatile private var nTailUnits = 0
    @Volatile private var nCatchUp = 0
    @Volatile private var nBackwards = 0
    @Volatile private var nAwait = 0
    @Volatile private var nHold = 0
    @Volatile private var nRingOverrun = 0L
    /** Idle decodes that had no frame ready within a frame's time (the codec runs ahead; this should read 0). */
    @Volatile private var nIdleStall = 0
    @Volatile private var nStarve = 0
    private var starveAt = 0L
    private var holdAtStarve = 0
    @Volatile private var resetGen = 0
    /**
     * A barge-in's Reset is queued behind whatever the feed thread is doing; until it
     * lands, nothing pulled from the engine is admitted. Without this the producer
     * pulled the OLD reply's frames under the NEW epoch for as long as the engine took
     * to reach the reset — its whole unrendered backlog, now that the plugin holds a
     * reply as it arrives rather than at 1x.
     */
    @Volatile private var resetPending = false
    /** Speech units admitted while a Reset was pending — the old reply leaking past a barge-in. */
    @Volatile private var nLeak = 0
    @Volatile private var nBarge = 0
    @Volatile private var cutAtMs = 0L

    /** Session sample count: monotonic, never reset — contract 1. */
    @Volatile private var sessionSamples = 0L
    /** Session sample count that the device's counter reads zero at. */
    @Volatile private var pBase = 0L

    // The speech bitmaps are a ring the engine writes into at pull time. A slot may be
    // rewritten only once its last unit has been PRESENTED, and the producer runs LEAD
    // units ahead of the writer plus the device buffer ahead of the presenter, so the
    // ring is deeper than both together; the check at pull time counts any violation
    // rather than assuming there is none.
    private val speechFrames = Array(RING) { avatar.newFrameBitmap() }
    private val slotSeq = LongArray(RING)
    @Volatile private var presentedSeq = 0L
    private var admittedSeq = 0L
    private val silence = ByteArray(BYTES_PER_FRAME)

    /**
     * SYNC MARKER — a dev lever, off unless `adb shell setprop debug.bh.marker.every N`.
     * Every Nth speech unit goes out WHITE with a 12 ms click mixed into the first 12 ms
     * of its own audio, so a camera or scrcpy+mic capture can read the A/V offset the
     * user actually experiences off the recording: white flash vs click. The unit is
     * marked BEFORE admission, so writer, device and presenter treat it like any other;
     * one `bhmark` line at admission and one when it is shown carry pts, host time and
     * the device's own output latency so the known part can be subtracted.
     */
    private val markerEvery: Int = if (debuggable) devInt("debug.bh.marker.every") else 0
    private val markerFrame: Bitmap? = if (markerEvery > 0) avatar.newFrameBitmap().also { it.eraseColor(Color.WHITE) } else null
    private var nSpeechAdmitted = 0L
    @Volatile private var nMarkers = 0
    private val audioTs = AudioTimestamp()

    private val track: AudioTrack = AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder()
            .setUsage(if (capturable) AudioAttributes.USAGE_MEDIA else AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build())
        .setAudioFormat(AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build())
        // Deep enough to start and to ride out a hiccup. Depth costs end-to-end
        // latency but NOT A/V error: the picture is shown against P, so it tracks
        // what is audible however much is buffered behind it.
        // ★ The device buffer must be SMALLER than the write-ahead bound, in units.
        // With a 0.5 s buffer and LEAD=8 (0.4 s) the producer could never get ahead of
        // the device, so it throttled to half real time and the picture ran at 10 fps.
        .setBufferSizeInBytes(maxOf(
            AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT),
            BYTES_PER_FRAME * DEVICE_UNITS))
        .setTransferMode(AudioTrack.MODE_STREAM)
        .build()

    fun start() {
        val got = track.sampleRate
        val bufFrames = runCatching { track.bufferSizeInFrames }.getOrDefault(-1)
        if (got != RATE) {
            Log.e("bhav", "★ AUDIO CLOCK MISMATCH: asked for $RATE Hz, device gave $got Hz. " +
                "Every pacing number below is computed against $RATE and will be wrong by " +
                "${"%.2f".format(got.toDouble() / RATE)}x.")
        }
        Log.i("bhav", "track: sampleRate=$got (asked $RATE) bufferFrames=$bufFrames " +
            "= ${"%.0f".format(bufFrames * 1000.0 / maxOf(got, 1))} ms")
        track.play()
        Thread(::feed, "bh-feed").start()
        Thread(::produce, "bh-produce").start()
        Thread(::write, "bh-write").start()
        // The presenter is the display's own clock: one callback per vsync on the main
        // looper, which is also where the bitmap is drawn. No thread, no polling loop.
        Handler(Looper.getMainLooper()).post { Choreographer.getInstance().postFrameCallback(vsync) }
    }

    /** One chunk of the agent's voice: PCM16 mono little-endian @ 24 kHz. */
    fun offer(pcm24k: ByteArray) { inbox.offer(pcm24k) }

    // The turn boundary decomposes into WAITING FOR AUDIO and RENDERING. The engine's
    // own counters separate them: wallMs is render time, chunks says whether the first
    // frame needed chunk 0 alone or chunk 1 as well.
    @Volatile private var byteWallMs = -1.0
    @Volatile private var byteChunks = -1L
    @Volatile private var byteFrames = -1L

    /** The agent's first voice byte of a turn reached us. */
    fun noteFirstByte() {
        stats.markFirstByte()
        val st = runCatching { avatar.stats() }.getOrNull() ?: return
        byteWallMs = st.wallMs; byteChunks = st.chunks; byteFrames = st.frames
        Log.i("bhsplit", "AT-FIRST-BYTE wallMs=%.1f chunks=%d frames=%d q=%d"
            .format(st.wallMs, st.chunks, st.frames, avatar.queuedFrames))
    }

    /**
     * The user cut in (contract 7). Bump the epoch and discard every older unit
     * WHOLE — including from the audio device, or the new epoch's mouth moves
     * against the old epoch's tail. `pts` does not reset.
     */
    fun bargeIn() {
        val t0 = System.currentTimeMillis()
        val headBefore = track.playbackHeadPosition
        resetPending = true             // before the epoch moves: see `pending` in produce()
        epoch++
        inbox.clear()
        toWrite.clear()
        toPresent.clear()
        track.pause()
        track.flush()
        track.play()
        nBarge++; cutAtMs = t0
        Log.i("bhbarge", "CUT $nBarge hostMs=$t0 epoch=$epoch headBefore=$headBefore flushedInMs=${System.currentTimeMillis() - t0} " +
            "q=${avatar.queuedFrames} pendingSlices=${runCatching { avatar.pendingAudioSlices }.getOrDefault(-1)}")
        pBase = sessionSamples          // the device counter restarts; the session does not
        tsValid = false; tsReadAt = 0L  // and so does its timestamp
        inbox.offer(Reset)
    }

    /** The agent finished a sentence — let the engine render the padded tail. */
    fun endOfReply() { inbox.offer(Tail) }

    fun stop() {
        running = false
        inbox.offer(Reset)
        toWrite.clear()
        toPresent.clear()
        runCatching { track.stop() }
        runCatching { track.release() }
    }

    private var rateT0 = 0L
    private var rateP0 = 0L

    /** Read the device's under-run counter. Off the audio path on purpose. */
    fun sampleUnderruns() {
        stats.underruns = runCatching { track.underrunCount }.getOrDefault(0)
        // ★ Does the device actually consume at the rate it told us? dP/dt against wall
        // time answers it outright; every pacing number assumes 24000 samples a second.
        val now = System.currentTimeMillis()
        val pos = track.playbackHeadPosition.toLong()
        if (rateT0 == 0L) { rateT0 = now; rateP0 = pos }
        else if (now - rateT0 >= 5000) {
            val hz = (pos - rateP0) * 1000.0 / (now - rateT0)
            Log.i("bhrate", "DEVICE DRAIN %.0f Hz over %.1fs (track says ${track.sampleRate} Hz) underruns=${stats.underruns}"
                .format(hz, (now - rateT0) / 1000.0))
            rateT0 = now; rateP0 = pos
        }
    }

    /**
     * Samples the device has made AUDIBLE, on the session timeline — the clock the
     * picture is shown against.
     *
     * ★ `playbackHeadPosition` is where the device has TAKEN samples to, and the
     * speaker is behind it by the track's output latency. Measured with the sync
     * marker (`debug.bh.marker.every`, scrcpy recording of what the device showed and
     * played, 2026-09-15, ten markers): the white frame led the click by 48-61 ms,
     * mean 54, while `AudioTimestamp` put the DAC 55-62 ms behind the head position.
     * So the picture is clocked on the DAC: the framework's timestamp (a frame
     * position with the nanoTime it was audible at) extrapolated to now. It is
     * re-read every [TS_REFRESH_MS]; between reads the extrapolation is exact to
     * the device clock. Where a device gives no timestamp the head position stands,
     * and the marker says by how much.
     */
    private fun p(): Long {
        val now = System.nanoTime()
        if (now - tsReadAt > TS_REFRESH_MS * 1_000_000L) {
            tsReadAt = now
            tsValid = runCatching { track.getTimestamp(clockTs) }.getOrDefault(false)
        }
        if (!tsValid) return pBase + track.playbackHeadPosition.toLong()
        val dac = clockTs.framePosition + (now - clockTs.nanoTime) * RATE / 1_000_000_000L
        // never ahead of what was taken (a stale timestamp across a flush), never backwards
        return pBase + minOf(dac, track.playbackHeadPosition.toLong())
    }
    private val clockTs = AudioTimestamp()
    private var tsReadAt = 0L
    private var tsValid = false

    // ---------------------------------------------------------------- producer

    /**
     * Copy stream bytes [head, to) out and advance `head`. Caller holds audioLock.
     *
     * `to` behind `head` would mean a frame asked for audio already played. It cannot
     * happen — frames arrive in order and the invented ones consume nothing — so it is
     * counted and refused rather than trusted; a demo does not crash on the audio thread.
     */
    private fun take(to: Long): ByteArray {
        val e = minOf(to, audioLen)
        if (e <= head) { nBackwards++; return silence }
        val out = audio.copyOfRange((head - audioHead).toInt(), (e - audioHead).toInt())
        head = e
        return out
    }

    /** The reply `head` is in, retiring every reply end it has passed. Caller holds audioLock. */
    private fun replyOfHead(): Int {
        while (replyEnds.isNotEmpty() && replyEnds.first() <= head) { replyEnds.removeFirst(); replySeq++ }
        return replySeq
    }

    private fun produce() {
        var slot = 0
        var lastSpeechSlot = -1
        var heldFrom = -1L
        var seenReset = resetGen
        var lastPullOk = false

        while (running) {
            if (resetGen != seenReset) { seenReset = resetGen; heldFrom = -1L; lastSpeechSlot = -1 }
            // ★ A unit belongs to the epoch that was current when its content was
            // obtained, not when it is admitted: `e` is read first, `pending` second,
            // and bargeIn() raises `pending` before it moves the epoch — so a cut at
            // any point of this iteration leaves the unit stamped with the OLD epoch
            // (dropped whole by the writer and presenter) or the iteration skipped.
            // Measured without this: 0-2 old-reply units per cut-in slipped through
            // under the new epoch, 50-100 ms of the old voice after the flush.
            // Between a barge-in and its Reset landing: no pull, no drain — idle only.
            val e = epoch
            val pending = resetPending

            if (heldFrom < 0 && !pending) {
                if (slotSeq[slot] > presentedSeq) nRingOverrun++
                val t0 = System.nanoTime()
                val f = avatar.pull(speechFrames[slot])
                val ms = (System.nanoTime() - t0) / 1_000_000L
                pullCalls++; pullNanos += System.nanoTime() - t0
                if (ms > pullMaxMs) pullMaxMs = ms
                if (ms > 50) pullOver50++
                if (f == null) {
                    nullPulls++
                    // STARVATION: the ready-frame depth reached zero while the engine
                    // still had an utterance to finish. Counted as episodes, not pulls.
                    if (lastPullOk && avatar.hasPendingTail) {
                        nStarve++; starveAt = System.currentTimeMillis(); holdAtStarve = nHold
                        val st = runCatching { avatar.stats() }.getOrNull()
                        val (h, fed) = synchronized(audioLock) { head to audioLen }
                        Log.i("bhstarve", "STARVE $nStarve hostMs=$starveAt headUnits=${h / BYTES_PER_FRAME} inHandUnits=${(fed - h) / BYTES_PER_FRAME} " +
                            "toWrite=${toWrite.size} chunks=${st?.chunks} frames=${st?.frames} wallMs=${"%.0f".format(st?.wallMs ?: -1.0)}")
                    }
                } else {
                    heldFrom = f.audioSample * BYTES_PER_SAMPLE16
                    if (starveAt > 0) {
                        val st = runCatching { avatar.stats() }.getOrNull()
                        val h = synchronized(audioLock) { head }
                        Log.i("bhstarve", "REFILL $nStarve after ${System.currentTimeMillis() - starveAt}ms frameAt=${heldFrom / BYTES_PER_FRAME} headUnits=${h / BYTES_PER_FRAME} " +
                            "toWrite=${toWrite.size} holdsSince=${nHold - holdAtStarve} chunks=${st?.chunks} frames=${st?.frames} wallMs=${"%.0f".format(st?.wallMs ?: -1.0)}")
                        starveAt = 0L
                    }
                }
                lastPullOk = f != null
            }

            if (heldFrom >= 0 && !pending) {
                var body: ByteArray? = null
                var underLast = false
                var stale = false
                synchronized(audioLock) {
                    // Every frame the SDK delivers has audio behind it (0.4.6, tail 0),
                    // so there is no "invented frame" arm here any more. There were two
                    // (play it under silence / drop it when real audio waits), and
                    // between them they inserted 5 s of silence across twelve replies
                    // and ate 0.65 s of the next reply, twice a conversation — measured
                    // 2026-09-15 — before they were ordered right. Gone is better.
                    when {
                        // A whole frame's worth of audio sits before this frame and has no
                        // frame of its own — an utterance's 0.4 s tail, the next one's 0.15 s
                        // head. It goes out under the LAST frame, a frame's worth at a time,
                        // so the cadence never breaks and this frame keeps its own samples.
                        lastSpeechSlot >= 0 && head + BYTES_PER_FRAME <= heldFrom -> {
                            body = take(head + BYTES_PER_FRAME); underLast = true; nCatchUp++
                        }
                        // Its audio already went out under the held frame (below): the
                        // frame is late, not the voice. Dropped, so the picture rejoins in
                        // sync at the first frame whose audio is still ahead.
                        heldFrom + BYTES_PER_FRAME <= head -> { stale = true; nStale++ }
                        else -> {
                            heldFrameReply = replyOfHead()
                            body = take(heldFrom + BYTES_PER_FRAME)      // its own samples, plus any short remainder before them
                        }
                    }
                }
                if (stale) { heldFrom = -1L; continue }
                nSpeech++; stats.speechUnits = nSpeech; stats.markFirstAudio()
                if (underLast) {
                    where = "catch-up"
                    admitSpeech(speechFrames[lastSpeechSlot], lastSpeechSlot, body!!, 'C', e)
                    continue                                   // the frame itself is still held
                }
                where = "speech-admit"
                admitSpeech(speechFrames[slot], slot, body!!, 'S', e)
                where = "speech-done"
                heldFrom = -1L
                lastSpeechSlot = slot
                slot = (slot + 1) % RING
                continue
            }

            if (!pending && drainTail(lastSpeechSlot, e)) continue

            // ★ IDLE IS FOR WHEN THERE IS NOTHING TO SAY — NOT FOR A GAP IN THE RENDER.
            // An idle unit carries a frame's worth of SILENCE, so admitting one while a
            // reply is still arriving inserts that silence into the reply and pushes the
            // rest of the conversation later, with the avatar's mouth flicking to its idle
            // loop mid-sentence. The ready-frame queue empties briefly by construction:
            // the engine renders a 1.6 s chunk at a time and cannot render audio that has
            // not arrived, so with a live 1x source the depth sawtooths to zero once a
            // chunk. Measured 2026-09-15: 15 such moments in 75 s, ~100 idle units, 5 s of
            // silence inserted into twelve replies.
            //
            // So while the engine has an utterance open, or audio waits unadmitted, the
            // producer WAITS — but only while the sink can afford it. Waiting outright
            // starves the device: measured 2026-09-15, 12 under-runs and a 1.5 s hole.
            // The write queue is the budget, and it is a DEPTH and not a timer: while the
            // writer still holds more than [IDLE_FLOOR] units the producer waits for the
            // engine, and only when the device is genuinely about to run dry does it
            // spend a frame of silence. That is the least silence that keeps the stream
            // continuous, and 0 under-runs says it was enough.
            val speaking = !pending && (avatar.hasPendingTail || synchronized(audioLock) { head < audioLen })
            if (speaking && toWrite.size > IDLE_FLOOR) {
                where = "await-frames"; nAwait++; Thread.sleep(2); continue
            }
            // Mid-reply the sink is fed by HOLDING THE LAST FRAME, never by the idle clip:
            // the engine is between chunks, not between turns, and cutting to an idle pose
            // for a single frame — 76 times in 75 s, measured — is a visible flick of the
            // mouth. The idle clip is for a turn with nothing in it.
            //
            // ★ AND THE VOICE DOES NOT STOP FOR A LATE FRAME. What rides under the held
            // frame is the reply's own audio when it is in hand, and silence only when it
            // is not. Until 2026-09-15 it was always silence, and that silence was the
            // owner's "brief pause after the first second": the Dart transport handed the
            // reply over at 1x, chunk 0 is 21 frames (1.05 s), chunk 1 cannot start until
            // 1.15 s more audio has arrived and then takes ~0.8 s to render, so every
            // reply ran out of frames 1.05 s in with 2 s of its audio waiting — and paused
            // for 300-500 ms (10 of 10 scripted replies, `hold` +6..8, under-runs 0: the
            // device was fed, with silence). Now the audio goes out a frame's worth at a
            // time, the late frames are dropped as stale above, and the picture rejoins in
            // sync. ★ This is a jitter net, not the fix: measured with the transport still
            // at 1x it turned the pause into a 300 ms freeze at EVERY chunk boundary and
            // dropped 23% of the frames, because at 1x the first boundary's deficit is
            // structural and playing through it leaves the voice permanently ahead of the
            // engine. The fix is the transport handing the reply over as it arrives
            // (bithuman_realtime.dart), after which no reply starved at all: 11 of 11 as
            // one continuous run, stale 0, and the first word 900 ms sooner.
            // Only THIS reply's audio: a frame held over from the previous reply must not
            // carry the next reply's opening — that is the start-up run-ahead 4a forbids.
            if (speaking && lastSpeechSlot >= 0) {
                val body = synchronized(audioLock) {
                    if (heldFrameReply == replyOfHead() && head + BYTES_PER_FRAME <= audioLen) take(head + BYTES_PER_FRAME) else null
                }
                if (body != null) {
                    where = "catch-up"; nCatchUp++
                    admitSpeech(speechFrames[lastSpeechSlot], lastSpeechSlot, body, 'C', e)
                } else {
                    where = "hold"; nHold++
                    admitSpeech(speechFrames[lastSpeechSlot], lastSpeechSlot, silence, 'H', e)
                }
                continue
            }
            if (idleLoop == null) { where = "no-idle-clip"; Thread.sleep(4); continue }
            // The producer is bounded by toWrite anyway; yielding here keeps it from
            // competing with the writer for the CPU the writer needs on time.
            if (toWrite.remainingCapacity() == 0) { Thread.sleep(2); continue }
            // The idle frame lands in the SAME ring as speech — one ring, one overrun check,
            // and no second set of bitmaps — decoded by the SDK straight into the slot.
            if (slotSeq[slot] > presentedSeq) nRingOverrun++
            where = "idle-decode"
            val idx = idleLoop.next(speechFrames[slot])
            if (idx < 0) { nIdleStall++; Thread.sleep(2); continue }
            where = "idle-admit"
            nIdle++; stats.idleUnits = nIdle
            val seq = ++admittedSeq
            slotSeq[slot] = seq
            admit(AvUnit(sessionSamples, speechFrames[slot], e, false, stats.turnGen, silence, seq, 'I'))
            where = "idle-done"
            sessionSamples += SAMPLES_PER_FRAME
            slot = (slot + 1) % RING
            // Once an idle frame has been shown there is no "last speech frame" to hold or
            // to play a remainder under: holding one would jump back to a mouth from the
            // previous turn. The clip keeps playing until the next reply's first frame lands,
            // and that frame carries its own head remainder — as the first reply's does.
            lastSpeechSlot = -1
            if (idx == 0 && nIdle > 1)
                Log.i("bhav", "IDLE wrap ${idleLoop.wraps}: frame ${idleLoop.frameCount - 1} -> 0 (clip ${idleLoop.frameCount} frames, idle units=$nIdle)")
        }
        // ★ THE PLAYER DOES NOT CLOSE THE ENGINE IT DID NOT CREATE. It used to, here,
        // and it cost the demos lane a crash on the first re-adoption: in an app that
        // HOLDS one avatar across several players (hide/show, idle hold), stopping a
        // player closed the engine and the next player's first pull() threw
        // `this Expression2Avatar is closed`. Whoever calls Expression2Avatar.create
        // calls close — BithumanPlugin, in dispose(), here.
    }

    private fun admitSpeech(frame: Bitmap, slot: Int, body: ByteArray, kind: Char, e: Int) {
        if (resetPending && e == epoch) nLeak++      // a unit of the new epoch admitted before the reset landed
        val seq = ++admittedSeq
        if (slot >= 0) slotSeq[slot] = seq
        var f = frame
        if (markerFrame != null && body !== silence && ++nSpeechAdmitted % markerEvery == 0L) {
            mixClick(body)
            f = markerFrame
            nMarkers++
            Log.i("bhmark", "MARKER $nMarkers ADMIT seq=$seq pts=$sessionSamples hostMs=${System.currentTimeMillis()}")
        }
        admit(AvUnit(sessionSamples, f, e, true, stats.turnGen, body, seq, kind))
        sessionSamples += (body.size / 2).toLong()
    }

    /** 12 ms Hann-windowed 2 kHz tone at -6 dBFS, mixed into the head of [body] in place. */
    private fun mixClick(body: ByteArray) {
        val n = minOf(CLICK_SAMPLES, body.size / 2)
        for (i in 0 until n) {
            val w = 0.5 * (1 - Math.cos(2 * Math.PI * i / (CLICK_SAMPLES - 1)))
            val tone = 16384.0 * w * Math.sin(2 * Math.PI * CLICK_HZ * i / RATE)
            val cur = (((body[2 * i + 1].toInt()) shl 8) or (body[2 * i].toInt() and 0xFF)).toShort().toInt()
            val v = (cur + tone).toInt().coerceIn(-32768, 32767)
            body[2 * i] = (v and 0xFF).toByte(); body[2 * i + 1] = ((v shr 8) and 0xFF).toByte()
        }
    }

    /**
     * The LAST reply's tail, which no later frame will ever carry.
     *
     * A chunk's frames stop up to 0.4 s short of the audio that made them, and normally
     * the next frame's own position sweeps that up (the catch-up above). At the end of a
     * conversation there is no next frame, so when the engine says it is finished — no
     * tail pending, nothing queued, both lock-free reads in 0.4.5 — the remainder plays
     * out under the last frame.
     *
     * Bounded by `replyEnds`: the session told us where each reply's audio stopped, and
     * that is all this uses it for. The next reply's audio can already be in the stream
     * while the engine is briefly between segments, and draining into it would put a
     * reply's opening under the previous reply's mouth. A wrong bound costs at most this
     * 0.4 s of placement; nothing else in the player depends on it.
     */
    private fun drainTail(lastSpeechSlot: Int, e: Int): Boolean {
        if (lastSpeechSlot < 0) return false
        var body: ByteArray? = null
        synchronized(audioLock) {
            val end = replyEnds.firstOrNull()
            if (end != null && head < end && !avatar.hasPendingTail && avatar.queuedFrames == 0) {
                body = take(minOf(head + BYTES_PER_FRAME, end))
                nTailUnits++
            }
            replyOfHead()
        }
        val b = body ?: return false
        where = "tail"
        admitSpeech(speechFrames[lastSpeechSlot], lastSpeechSlot, b, 'T', e)
        return true
    }

    /**
     * Feeding is its own thread because the inbox is a queue the session fills from its
     * socket thread, and a barge-in must reach the engine in order with the audio it
     * cuts. Since expression2-android 0.4.2 (the feed/pull lock split) `pull` never
     * waits on a render, and since 0.4.5 it never performs one, so nothing here can
     * starve the producer.
     */
    private fun feed() {
        while (running) {
            when (val item = inbox.poll() ?: run { Thread.sleep(4); null } ?: continue) {
                is Reset -> {
                    synchronized(audioLock) {
                        audioHead = 0L; audioLen = 0L; head = 0L; carry = ByteArray(0); replyEnds.clear()
                    }
                    val t0 = System.currentTimeMillis()
                    avatar.resetState(true)      // also restarts the engine's audioSample count
                    resetGen++
                    resetPending = false
                    if (cutAtMs > 0) Log.i("bhbarge", "RESET landed sinceCutMs=${t0 - cutAtMs} resetMs=${System.currentTimeMillis() - t0} leaks=$nLeak")
                }
                is Tail -> {
                    // Where this reply's audio stops. Used for one thing only: bounding the
                    // end-of-conversation drain above. Never to place a frame in time.
                    synchronized(audioLock) { if (replyEnds.lastOrNull() != audioLen) replyEnds.addLast(audioLen) }
                    avatar.flushTail()
                }
                is ByteArray -> {
                    // ★ THE STREAM AND THE ENGINE MUST AGREE SAMPLE FOR SAMPLE, because
                    // `audioSample * 3` indexes this buffer. The 24->16 kHz conversion
                    // consumes three samples for every two, so a chunk whose sample count
                    // is not a multiple of three leaves a remainder: it is CARRIED to the
                    // next chunk rather than dropped, and the buffer holds exactly the
                    // bytes that were fed. Buffer first, so a frame can never arrive
                    // before its audio is findable.
                    val joined = if (carry.isEmpty()) item else carry + item
                    val usable = joined.size / 6 * 6
                    carry = joined.copyOfRange(usable, joined.size)
                    if (usable > 0) {
                        val whole = if (usable == joined.size) joined else joined.copyOfRange(0, usable)
                        synchronized(audioLock) { append(whole) }
                        avatar.feed(toFloat16k(whole))
                    }
                }
            }
        }
    }

    /** Append to the stream, growing or compacting only when the tail actually runs out. */
    private fun append(item: ByteArray) {
        val used = (audioLen - audioHead).toInt()
        if (used + item.size > audio.size) {
            val live = (audioLen - head).toInt()
            if (live + item.size > audio.size) {
                nGrow++
                val bigger = ByteArray(maxOf(audio.size * 2, (live + item.size) * 2))
                System.arraycopy(audio, (head - audioHead).toInt(), bigger, 0, live)
                audio = bigger
            } else {
                nCompact++
                System.arraycopy(audio, (head - audioHead).toInt(), audio, 0, live)
            }
            audioHead = head
        }
        System.arraycopy(item, 0, audio, (audioLen - audioHead).toInt(), item.size)
        audioLen += item.size
    }

    @Volatile private var nCreated = 0L
    @Volatile private var nWritten = 0L
    @Volatile private var nPresented = 0L
    @Volatile private var nPresSpeech = 0L
    @Volatile private var nPresDropStale = 0L
    @Volatile private var nPresDropLate = 0L
    @Volatile private var nWriteSpeech = 0L
    @Volatile private var lastSpeechWriteMs = 0L

    /**
     * Is the SPEAKER playing the agent's voice right now (plus [hangoverMs] after)?
     *
     * The microphone needs this. Measured on a Galaxy S25+ with nobody in the room: the
     * agent's own voice came out of the speaker, the platform echo canceller did not hold
     * at speakerphone volume, the uplink transcribed it as the USER ("you: If you're here
     * to help, just let me know what you'd like to talk about." — the agent's own words),
     * the server's turn detection answered it, and the session talked to itself
     * indefinitely. The avatar then animates that chatter and never reaches its idle loop,
     * which is what a person sees as "it never rests".
     *
     * The writer is the right place to read it from: `track.write` blocks until the device
     * takes the samples, so the last speech write is within a buffer of what is audible.
     */
    fun speakingRecently(hangoverMs: Long = 400): Boolean {
        val t = lastSpeechWriteMs
        return t > 0 && System.currentTimeMillis() - t < hangoverMs
    }

    /** created -> handed to write() -> presented. If they disagree, units are being lost. */
    fun census(): String = "created=$nCreated written=$nWritten presented=$nPresented " +
        "| COVERAGE speechWritten=$nWriteSpeech speechPresented=$nPresSpeech " +
        "cov=${if (nWriteSpeech > 0) (100 * nPresSpeech / nWriteSpeech) else 0}% " +
        "presDropStale=$nPresDropStale presDropLate=$nPresDropLate"

    private fun admit(u: AvUnit) {
        nCreated++
        while (running && !toWrite.offer(u)) Thread.sleep(2)
    }

    /**
     * The only thing that paces audio: a blocking write and nothing else. Keeping this
     * out of the producer is what makes the stream continuous — the device is fed at
     * exactly 1x regardless of how long a producer iteration takes.
     */
    private var writes = 0L
    private var writeUs = 0L
    private var writeMaxUs = 0L
    private var lastWriteMs = 0L
    private var runKind = 'I'
    private var runStartMs = 0L
    private var runStartHead = 0L
    private var runUnits = 0
    private var turnGenSeen = -1
    private var turnUnderrunStart = 0
    private var turnEpochAtStart = -1
    private var turnSpeechWrites = 0
    private var prevFrames = -1L
    private var prevWallMs = -1.0
    private val urByIndex = IntArray(12)
    private var lastUnderrunSeen = 0
    @Volatile private var nCompact = 0
    @Volatile private var nGrow = 0

    private fun write() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        while (running) {
            var u = toWrite.poll()
            if (u == null) { Thread.sleep(1); continue }
            // Tight inner loop: keep handing units to the device until it pushes back.
            // Blocking inside track.write IS the pacing, and it only happens once the
            // device buffer is genuinely full — which is the lead we could never build.
            while (running && u != null) {
                if (u.epoch == epoch) {
                    val writeT0 = System.nanoTime()
                    runCatching { track.write(u.audio, 0, u.audio.size) }
                    val wus = (System.nanoTime() - writeT0) / 1000L
                    writeUs += wus; if (wus > writeMaxUs) writeMaxUs = wus
                    nWritten++
                    if (u.speech) { nWriteSpeech++; lastSpeechWriteMs = System.currentTimeMillis() }
                    val nowMs = System.currentTimeMillis()
                    if (lastWriteMs > 0 && nowMs - lastWriteMs >= 120) {
                        Log.i("bhgap", "WRITE GAP ${nowMs - lastWriteMs}ms speech=${u.speech} " +
                            "underruns=${runCatching { track.underrunCount }.getOrDefault(0)} " +
                            "toWrite=${toWrite.size}")
                    }
                    lastWriteMs = nowMs
                    val ur = runCatching { track.underrunCount }.getOrDefault(0)
                    if (ur != lastUnderrunSeen)
                        Log.i("bhur", "UNDERRUN +${ur - lastUnderrunSeen} total=$ur hostMs=$nowMs head=${track.playbackHeadPosition} kind=${u.kind} toWrite=${toWrite.size}")
                    if (u.kind != runKind) {
                        val headNow = track.playbackHeadPosition.toLong()
                        if (runStartMs > 0) {
                            val dur = nowMs - runStartMs
                            // Every run of held or caught-up units is logged whole; idle and
                            // speech only when they are long enough to mean something.
                            if (dur >= 100 || runKind == 'H' || runKind == 'C' || runKind == 'T')
                                Log.i("bhrun", "RUN ${runKind} ${dur}ms units=$runUnits head=$runStartHead..$headNow " +
                                    "endHostMs=$nowMs next=${u.kind} underruns=$ur")
                        }
                        runKind = u.kind; runStartMs = nowMs; runStartHead = headNow; runUnits = 0
                    }
                    runUnits++
                    stats.onAudioWrite()
                    if (u.speech) {
                        if (u.turnGen != turnGenSeen) {
                            if (turnGenSeen >= 0 && turnSpeechWrites > 0) {
                                val d = runCatching { track.underrunCount }.getOrDefault(0) - turnUnderrunStart
                                val st = runCatching { avatar.stats() }.getOrNull()
                                var engine = "engine=?"
                                if (st != null) {
                                    if (prevFrames >= 0 && st.wallMs > prevWallMs) {
                                        val dF = st.frames - prevFrames
                                        val dW = st.wallMs - prevWallMs
                                        engine = "engineDeltaFps=%.1f (dFrames=%d dWallMs=%.0f)".format(
                                            dF * 1000.0 / dW, dF, dW)
                                    }
                                    prevFrames = st.frames; prevWallMs = st.wallMs
                                }
                                val fl = synchronized(audioLock) { audioLen - head }
                                val fcap = synchronized(audioLock) { audio.size }
                                Log.i("bhturn", "TURN $turnGenSeen speechWrites=$turnSpeechWrites " +
                                    "underrunDelta=$d bargeDuringTurn=${epoch != turnEpochAtStart} $engine " +
                                    "| SIZES inbox=${inbox.size} toWrite=${toWrite.size} toPresent=${toPresent.size} " +
                                    "pendingBytes=$fl bufCap=$fcap compactions=$nCompact grows=$nGrow " +
                                    "| UNDERRUNS BY WRITE-INDEX-IN-TURN " + urByIndex.joinToString(",") +
                                    " (index 11 = all later writes)")
                            }
                            turnGenSeen = u.turnGen
                            turnUnderrunStart = runCatching { track.underrunCount }.getOrDefault(0)
                            turnEpochAtStart = u.epoch
                            turnSpeechWrites = 0
                        }
                        turnSpeechWrites++
                        val step = ur - lastUnderrunSeen
                        if (step > 0) urByIndex[minOf(turnSpeechWrites - 1, urByIndex.size - 1)] += step
                    }
                    if (++writes % 200 == 0L)
                        Log.i("bhwrite", ("writes=%d inWriteAvg=%.1fms max=%.1fms | toWrite=%d toPresent=%d underruns=%d")
                            .format(writes, writeUs / 1000.0 / writes, writeMaxUs / 1000.0,
                                toWrite.size, toPresent.size, stats.underruns))
                    lastUnderrunSeen = ur
                    while (running && !toPresent.offer(u)) Thread.sleep(1)
                }
                u = toWrite.poll()
            }
        }
    }

    // --------------------------------------------------------------- presenter

    @Volatile private var nCoalesced = 0L
    private var shown = 0L
    private var beat = 0L

    private val vsync = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            presentDue(frameTimeNanos)
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    /**
     * One vsync: show the NEWEST unit whose audio the device has reached, and count every
     * older due unit it superseded as `coalesced`. Two units due in one vsync means the
     * presenter had fallen behind its own audio; before this it showed each of them in
     * turn, ever later, and the overlay's `off` read that backlog as A/V drift
     * (measured 2026-09-15: +460-480 ms with nobody talking and 34-57 units queued).
     * Now `late` is what it says — the shown frame's distance past its own audio, bounded
     * by one vsync plus one unit — and the backlog is `inFlight`.
     */
    private fun presentDue(frameTimeNanos: Long) {
        val now = System.currentTimeMillis()
        if (now - beat > 1000) {
            beat = now
            sampleUnderruns()
            stats.refresh()
            val avg = if (pullCalls > 0) pullNanos / pullCalls / 1_000_000.0 else 0.0
            Log.i("bhav", "PROD where=$where idle=$nIdle speech=$nSpeech tailUnits=$nTailUnits " +
                "catchUp=$nCatchUp await=$nAwait hold=$nHold stale=$nStale back=$nBackwards ringOverrun=$nRingOverrun starve=$nStarve barges=$nBarge leaks=$nLeak " +
                "idleStall=$nIdleStall idleAt=${idleLoop?.lastIndex ?: -1}/${idleLoop?.frameCount ?: 0} idleWraps=${idleLoop?.wraps ?: 0} " +
                "coalesced=$nCoalesced markers=$nMarkers q=${avatar.queuedFrames} inFlight=${toPresent.size} | " +
                String.format("pull avg %.1fms max %dms over50=%d null=%d calls=%d", avg, pullMaxMs, pullOver50, nullPulls, pullCalls) +
                " | " + stats.line().replace("\n", " "))
        }
        val pos = p()
        var u: AvUnit? = null
        while (true) {
            val c = toPresent.peek() ?: break
            if (c.epoch != epoch) {                       // stale: drop whole
                toPresent.poll()
                if (c.speech) { nPresDropStale++; stats.dropped = (nPresDropStale + nPresDropLate).toInt() }
                presentedSeq = maxOf(presentedSeq, c.seq)
                continue
            }
            if (pos < c.ptsSamples) break
            toPresent.poll()
            if (u != null) nCoalesced++
            u = c
        }
        if (u == null) return
        presentedSeq = maxOf(presentedSeq, u.seq)
        if (u.speech) nPresSpeech++
        if (cutAtMs > 0 && u.speech && u.kind != 'H') {
            Log.i("bhbarge", "NEW-MOUTH sinceCutMs=${now - cutAtMs} epoch=${u.epoch} kind=${u.kind} leaks=$nLeak")
            cutAtMs = 0L
        }
        if (++shown % 100 == 1L)
            Log.i("bhav", "AV shown=$shown pts=${u.ptsSamples} P=$pos lateSamples=${pos - u.ptsSamples}")
        val wasFirst = u.speech && stats.ttffMs < 0 && u.turnGen == stats.turnGen
        nPresented++
        stats.onPresented(u.speech, u.turnGen)
        if (wasFirst && stats.ttffMs >= 0 && byteChunks >= 0) {
            val st = runCatching { avatar.stats() }.getOrNull()
            if (st != null) {
                val render = st.wallMs - byteWallMs
                val wall = (stats.ttffMs - stats.ttfbMs).toDouble()
                Log.i("bhsplit", ("AT-FIRST-FRAME ttfb=%dms ttff=%dms ours=%.0fms | " +
                    "renderMs=%.0f waitingForAudioMs=%.0f | chunksDelta=%d (%d->%d) framesDelta=%d q=%d")
                    .format(stats.ttfbMs, stats.ttffMs, wall, render, wall - render,
                        st.chunks - byteChunks, byteChunks, st.chunks,
                        st.frames - byteFrames, avatar.queuedFrames))
            }
        }
        if (u.frame === markerFrame) {
            // Where is the DAC relative to the head position the picture is clocked on?
            var latencyMs = Double.NaN
            if (runCatching { track.getTimestamp(audioTs) }.getOrDefault(false)) {
                val dac = audioTs.framePosition + (System.nanoTime() - audioTs.nanoTime) * RATE / 1e9
                latencyMs = (track.playbackHeadPosition.toLong() - dac) * 1000.0 / RATE
            }
            Log.i("bhmark", "MARKER SHOWN seq=${u.seq} pts=${u.ptsSamples} P=$pos hostMs=${System.currentTimeMillis()} " +
                "vsyncMs=${frameTimeNanos / 1_000_000} trackLatencyMs=%.1f dacClock=$tsValid".format(latencyMs) +
                " (white frame shown when the DAC clock reached pts; the click sits in that unit's first 12 ms, " +
                "so an external capture of the speaker should see white and click together)")
        }
        stats.offsetMs = (pos - u.ptsSamples) * 1000.0 / RATE
        stats.engineQueue = avatar.queuedFrames
        stats.inFlight = toPresent.size
        onFrame(u.frame)
    }

    companion object {
        const val RATE = 24_000   // the wire rate: the realtime session speaks 24 kHz PCM16 both ways
        /** Whole units the writer may run ahead of the device — contract 4b requires this be stated. */
        const val LEAD = 12
        /** Deep enough that the writer is never blocked by the presenter — only by the device. */
        private const val PRESENT_QUEUE = 256
        /** Idle units emitted per pass, so supply outruns the device and the writer paces. */
        private const val IDLE_BURST = 4
        /** Chunks fed per unit produced. Unbounded feeding starves the sink. */
        /** Stop feeding once the engine holds this many frames — about two seconds. */
        /** contract 1: samples_per_frame == sample_rate / fps */
        val SAMPLES_PER_FRAME = RATE / Expression2Avatar.FRAMES_PER_SECOND
        val BYTES_PER_FRAME = SAMPLES_PER_FRAME * 2
        /** Bytes of 24 kHz PCM16 per 16 kHz sample fed: 1.5 samples, two bytes each. */
        const val BYTES_PER_SAMPLE16 = 3L
        const val US_PER_FRAME = 1_000_000L / Expression2Avatar.FRAMES_PER_SECOND
        /** Device buffer, in units (AudioTrack below asks for 4). */
        private const val DEVICE_UNITS = 4
        /** Write-queue depth below which the sink is fed silence rather than waited on. */
        private const val IDLE_FLOOR = 3
        /** Speech bitmaps in flight: producer ahead of writer (LEAD) + writer ahead of presenter (device) + slack. */
        private const val RING = LEAD + DEVICE_UNITS + 4
        /** How often the DAC timestamp is re-read; between reads it is extrapolated. */
        private const val TS_REFRESH_MS = 250L
        /** The sync marker's click: 12 ms of 2 kHz. */
        private const val CLICK_HZ = 2000.0
        private val CLICK_SAMPLES = RATE * 12 / 1000

        /** A `debug.*` system property as an int, 0 when unset — settable from `adb shell setprop`. */
        private fun devInt(key: String): Int = runCatching {
            val c = Class.forName("android.os.SystemProperties")
            (c.getMethod("get", String::class.java, String::class.java).invoke(null, key, "0") as String).trim().toInt()
        }.getOrDefault(0)

        /**
         * PCM16 @ 24 kHz -> float in [-1,1] @ 16 kHz, which is what `feed` takes.
         * Three samples in, two out, linear between them.
         */
        fun toFloat16k(pcm24k: ByteArray): FloatArray {
            val n = pcm24k.size / 2
            if (n < 2) return FloatArray(0)
            val out = FloatArray(n * 2 / 3)
            for (i in out.indices) {
                val x = i * 1.5f
                val a = x.toInt()
                val b = minOf(a + 1, n - 1)
                val t = x - a
                val sa = sample(pcm24k, a)
                val sb = sample(pcm24k, b)
                out[i] = (sa + (sb - sa) * t) / 32768f
            }
            return out
        }

        private fun sample(b: ByteArray, i: Int): Float {
            val lo = b[i * 2].toInt() and 0xFF
            val hi = b[i * 2 + 1].toInt()
            return ((hi shl 8) or lo).toShort().toFloat()
        }
    }
}
