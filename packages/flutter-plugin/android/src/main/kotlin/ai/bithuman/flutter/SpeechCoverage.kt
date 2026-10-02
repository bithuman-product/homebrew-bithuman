// Speech coverage, measured the way a viewer sees it (2.6.29): UNIQUE speech frames shown ÷ speech
// frames DUE for the audio played.
//
// The COVERAGE line used to divide speech units presented by speech units written, and a unit that
// re-shows the held frame under its audio (a catch-up `C`, a tail `T`) counted as presented — so a
// face frozen for seconds on a phone that rendered 10 fps read "cov=86-93%" (Galaxy Z Flip5, bitHuman
// Live, Sofia, 2026-10-01). Here every presented unit that carries reply audio is one frame DUE (40 ms
// of voice at 25 fps, 50 ms at 20); only a NEW frame (`S`) that reached the glass counts as shown.
// A unit coalesced away in a vsync (its audio played, its frame never shown) is due and not shown.
//
// One line per utterance (`UTT`), and a `FROZEN` line when coverage over the newest second of voice has
// stayed below half for more than a second (with `FROZEN-END` and how long), so a device run — and later
// telemetry — names a frozen face instead of averaging it away; a dip shorter than that is not flagged.
// Free of Android: SpeechCoverageTest.
package ai.bithuman.flutter

class SpeechCoverage(
    /** Due units in one second of voice (the engine's frame rate). */
    private val unitsPerSecond: Int,
    /** A second of voice below this share of unique frames is a frozen face. */
    private val frozenBelow: Double = 0.5,
    private val log: (String) -> Unit,
) {
    /** Since the session began. */
    var uniqueTotal = 0L; private set
    var dueTotal = 0L; private set
    var frozenEpisodes = 0; private set
    var frozenUnitsTotal = 0L; private set
    /** Utterances summarised so far. */
    var utterances = 0; private set
    val coveragePct: Int get() = if (dueTotal > 0) (100 * uniqueTotal / dueTotal).toInt() else 100

    private var open = false
    private var turn = Int.MIN_VALUE
    private var uttUnique = 0
    private var uttDue = 0
    private var uttFrozenUnits = 0
    private var uttEpisodes = 0
    /** The newest second of due units: true = a unique frame was shown for it. */
    private val window = ArrayDeque<Boolean>()
    private var windowUnique = 0
    private var frozen = false
    private var frozenAtDue = 0
    /** Due index where the 1 s window first went below [frozenBelow]; -1 while it is not below. */
    private var lowSince = -1

    /**
     * A presented (or coalesced) unit of the current epoch. [carriesAudio]: it plays reply audio
     * (S, C, T); [newFrame]: its frame is a new speech frame that reached the glass (an S unit
     * shown, not coalesced). [turn] is the reply it belongs to.
     */
    fun onSpeechUnit(turn: Int, carriesAudio: Boolean, newFrame: Boolean) {
        if (!carriesAudio) return
        if (open && turn != this.turn) endUtterance()
        if (!open) { open = true; this.turn = turn; uttUnique = 0; uttDue = 0; uttFrozenUnits = 0; uttEpisodes = 0 }
        uttDue++; dueTotal++
        if (newFrame) { uttUnique++; uniqueTotal++ }
        window.addLast(newFrame); if (newFrame) windowUnique++
        if (window.size > unitsPerSecond) { if (window.removeFirst()) windowUnique-- }
        val full = window.size >= unitsPerSecond
        val low = full && windowUnique < frozenBelow * window.size
        if (low) {
            if (lowSince < 0) lowSince = uttDue
            if (!frozen && uttDue - lowSince >= unitsPerSecond) {
                frozen = true; frozenAtDue = lowSince; uttEpisodes++; frozenEpisodes++
                log("FROZEN utterance=${utterances + 1} at=${ms(lowSince)}ms: under ${(frozenBelow * 100).toInt()}% unique frames " +
                    "for ${ms(uttDue - lowSince)}ms (now $windowUnique of ${window.size} due over the last 1 s)")
            }
        } else if (lowSince >= 0) {
            if (frozen) {
                endEpisode()
                log("FROZEN-END utterance=${utterances + 1} after ${ms(uttDue - frozenAtDue)}ms: $windowUnique unique of ${window.size} over the last 1 s")
            }
            lowSince = -1
        }
    }

    private fun endEpisode() {
        frozen = false
        val n = uttDue - frozenAtDue
        uttFrozenUnits += n; frozenUnitsTotal += n
    }

    /** The reply's voice ended (idle on the glass) or was cut (a barge-in): summarise it. */
    fun endUtterance() {
        if (!open) return
        open = false
        utterances++
        if (frozen) {
            endEpisode()
            log("FROZEN-END utterance=$utterances after ${ms(uttDue - frozenAtDue)}ms: the utterance ended frozen")
        }
        lowSince = -1
        window.clear(); windowUnique = 0
        log("UTT $utterances unique=$uttUnique due=$uttDue cov=${if (uttDue > 0) 100 * uttUnique / uttDue else 100}% " +
            "frozen=${ms(uttFrozenUnits)}ms episodes=$uttEpisodes")
    }

    private fun ms(units: Int): Long = units * 1000L / unitsPerSecond
}
