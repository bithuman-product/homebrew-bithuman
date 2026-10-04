// The hybrid brain's reply stage (`localAudioStart(replyMode: 'host')`): speech in (Apple's
// on-device recognizer) and the voice out (Supertonic) stay on the device, and the REPLY TEXT
// comes from the app — typically a cheap cloud text model behind the app's own server, so no
// model key ever sits on the phone and no realtime speech-to-speech minute is paid for.
//
// Same contract as Android's (one Dart API on both platforms; lib/src/voice_host.dart):
//   the brain needs a reply  → event {"kind":"reply_request","id":Int,"messages":[{role,content}],
//                                      "text":String,"continuation":Bool,"maxTokens":Int}
//   the app streams it back  → localReplyText {id, text, done, result}
//   the user cut in          → event {"kind":"reply_cancel","id":Int,"heardChars":Int?} — while the
//                              reply streams AND after its text is done but the voice is still
//                              speaking it; heardChars = the characters the person actually heard
//                              (the relay keeps only those in its memory).
// Nothing the app sends for an old id is ever spoken.
//
// libconverse keeps everything around the model (bc_session_create_with_llm, >= 2.5.0): the
// crisis guard (a crisis turn never reaches the host), the bounded history, clause chunking,
// the speakable filter, Supertonic, barge-in and the avatar feed. This file only waits for text.
#if CONVERSE_AVAILABLE && CONVERSE_HOST_LLM
import CConverse
import Foundation

final class HostReplyLlm: @unchecked Sendable {
    /// Asks the app for a reply (main-thread hop is the caller's business). [continuation]: the
    /// user went on after a pause and the last user message is the WHOLE utterance, replacing
    /// the previous request's turn.
    typealias Request = (_ id: Int, _ messages: [[String: String]], _ maxTokens: Int, _ continuation: Bool) -> Void
    /// The brain dropped request [id]; [heard] = characters of its text the person heard (nil = unknown).
    typealias Cancel = (_ id: Int, _ heard: Int?) -> Void

    private let request: Request
    private let cancelRequest: Cancel
    /// No first piece within this long: the turn fails (the brain says its error reply).
    private let firstPieceTimeout: TimeInterval
    /// A stream that stalls this long after its first piece is treated as finished.
    private let stallTimeout: TimeInterval

    private struct Piece { let text: String; let done: Bool; let result: Int32 }
    private let cond = NSCondition()
    private var pieces: [Piece] = []
    private var current = -1
    private var cancelled = false
    private var nextId = 0
    /// The next request continues the previous turn (set by the controller with the commit).
    private var nextContinuation = false
    /// What the person heard of the reply being cut (set by barge(), read by the cancel path).
    private var pendingHeard: Int?
    /// The last request whose stream ENDED normally, and whether its cut was already reported.
    private var lastDone = -1
    private var lastDoneReported = true

    init(request: @escaping Request, cancelRequest: @escaping Cancel,
         firstPieceTimeout: TimeInterval = 12, stallTimeout: TimeInterval = 8) {
        self.request = request
        self.cancelRequest = cancelRequest
        self.firstPieceTimeout = firstPieceTimeout
        self.stallTimeout = stallTimeout
    }

    /// A bc_host_llm_t that owns a +1 reference to `self` (the brain releases it).
    /// The C strings must outlive bc_session_create_with_llm only (the brain copies them).
    func hostLlm(refusalReply: UnsafePointer<CChar>?, errorReply: UnsafePointer<CChar>?) -> bc_host_llm_t {
        var h = bc_host_llm_t()
        h.abi_version = UInt32(BC_ABI_VERSION)
        h.ud = Unmanaged.passRetained(self).toOpaque()
        h.stream = { ud, msgs, n, maxTokens, emit, ctx in
            guard let ud, let emit else { return Int32(BC_LLM_ERROR.rawValue) }
            let me = Unmanaged<HostReplyLlm>.fromOpaque(ud).takeUnretainedValue()
            return me.stream(HostReplyLlm.messages(msgs, n), maxTokens: Int(maxTokens), emit: emit, ctx: ctx)
        }
        h.release = { ud in
            guard let ud else { return }
            Unmanaged<HostReplyLlm>.fromOpaque(ud).release()
        }
        h.refusal_reply = refusalReply
        h.error_reply = errorReply
        return h
    }

    /// A piece of the reply to request [id] (any thread). Pieces for any other id are dropped.
    func push(id: Int, text: String, done: Bool, result: Int32) {
        cond.lock()
        if id == current {
            pieces.append(Piece(text: text, done: done, result: result))
            cond.signal()
        }
        cond.unlock()
    }

    /// Barge-in / interrupt: end the wait at once (the brain is blocked in `stream` and would
    /// otherwise notice only at the next piece, or after the first-piece timeout).
    func cancel() {
        cond.lock()
        if current >= 0 { cancelled = true; cond.signal() }
        cond.unlock()
    }

    /// The next turn the brain asks for is the rest of the previous one (a split utterance).
    func markContinuation() {
        cond.lock(); nextContinuation = true; cond.unlock()
    }

    /// The person cut in, having heard [heard] characters of the reply (call BEFORE the brain's
    /// interrupt). A reply still streaming reports it with its own cancel; a reply whose stream
    /// already ended but was still being SPOKEN ([stillSpeaking]) is reported here, once.
    func barge(heard: Int?, stillSpeaking: Bool) {
        cond.lock()
        if current >= 0 {
            pendingHeard = heard
            cond.unlock()
            return
        }
        let id = lastDone
        let report = id >= 0 && !lastDoneReported && stillSpeaking
        if report { lastDoneReported = true }
        cond.unlock()
        if report { cancelRequest(id, heard) }
    }

    private func takeHeard() -> Int? {
        cond.lock(); defer { cond.unlock() }
        let h = pendingHeard
        pendingHeard = nil
        return h
    }

    private static func messages(_ p: UnsafePointer<bc_chat_message_t>?, _ n: Int) -> [[String: String]] {
        guard let p else { return [] }
        return (0..<n).map { i in
            ["role": p[i].role.map { String(cString: $0) } ?? "",
             "content": p[i].content.map { String(cString: $0) } ?? ""]
        }
    }

    private static func ms() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // Runs on the brain's worker thread (a plain std::thread): blocking here is the contract.
    private func stream(_ msgs: [[String: String]], maxTokens: Int, emit: bc_llm_emit_fn,
                        ctx: UnsafeMutableRawPointer?) -> Int32 {
        cond.lock()
        nextId += 1
        let id = nextId
        current = id
        pieces.removeAll()
        cancelled = false
        pendingHeard = nil
        let continuation = nextContinuation
        nextContinuation = false
        lastDone = -1                    // a new reply supersedes the last one's cut
        lastDoneReported = true
        cond.unlock()
        let t0 = Date()
        var n = 0
        var firstMs = -1
        var lastAt = t0
        var why = "done"
        var reported = false             // this request's cut already went to the app
        defer {
            cond.lock()
            current = -1; pieces.removeAll()
            lastDone = id; lastDoneReported = reported
            cond.unlock()
            NSLog("[bhhost] reply id=%d pieces=%d firstPieceMs=%d totalMs=%d end=%@ hostMs=%lld",
                  id, n, firstMs, Int(Date().timeIntervalSince(t0) * 1000), why, Self.ms())
        }
        NSLog("[bhhost] reply_request id=%d msgs=%d continuation=%d hostMs=%lld", id, msgs.count,
              continuation ? 1 : 0, Self.ms())
        request(id, msgs, maxTokens, continuation)
        while true {
            cond.lock()
            var timedOut = false
            while pieces.isEmpty && !cancelled {
                let deadline = n == 0 ? t0.addingTimeInterval(firstPieceTimeout)
                                      : lastAt.addingTimeInterval(stallTimeout)
                if !cond.wait(until: deadline) { timedOut = pieces.isEmpty && !cancelled; break }
            }
            let batch = pieces
            pieces.removeAll()
            let wasCancelled = cancelled
            cond.unlock()
            if wasCancelled {
                why = "cancelled"; reported = true; cancelRequest(id, takeHeard())
                return Int32(BC_LLM_OK.rawValue)
            }
            if timedOut {
                reported = true; cancelRequest(id, nil)
                if n == 0 { why = "no first piece in \(Int(firstPieceTimeout)) s"; return Int32(BC_LLM_ERROR.rawValue) }
                why = "stalled"
                return Int32(BC_LLM_OK.rawValue)
            }
            for p in batch {
                if !p.text.isEmpty {
                    if firstMs < 0 {
                        firstMs = Int(Date().timeIntervalSince(t0) * 1000)
                        NSLog("[bhhost] first_piece id=%d ms=%d hostMs=%lld", id, firstMs, Self.ms())
                    }
                    n += 1
                    lastAt = Date()
                    if p.text.withCString({ emit(ctx, $0) }) == 0 {
                        why = "stopped by the brain"; reported = true; cancelRequest(id, takeHeard())
                        return Int32(BC_LLM_OK.rawValue)
                    }
                }
                if p.done {
                    if p.result != Int32(BC_LLM_OK.rawValue) { why = "host result \(p.result)" }
                    // What was already spoken stays spoken: a late failure ends the turn normally.
                    return (p.result == Int32(BC_LLM_OK.rawValue) || n > 0) ? Int32(BC_LLM_OK.rawValue) : p.result
                }
            }
        }
    }
}
#endif  // CONVERSE_AVAILABLE && CONVERSE_HOST_LLM
