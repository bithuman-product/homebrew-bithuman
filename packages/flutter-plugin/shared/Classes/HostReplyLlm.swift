// The hybrid brain's reply stage (`localAudioStart(replyMode: 'host')`): speech in (Apple's
// on-device recognizer) and the voice out (Supertonic) stay on the device, and the REPLY TEXT
// comes from the app — typically a cheap cloud text model behind the app's own server, so no
// model key ever sits on the phone and no realtime speech-to-speech minute is paid for.
//
// Same contract as Android's HostReplyModel (one Dart API on both platforms):
//   the brain needs a reply  → event {"kind":"reply_request","id":Int,"messages":[{role,content}]}
//   the app streams it back  → localReplyText {id, text, done, result}
//   the user cut in / enough → event {"kind":"reply_cancel","id":Int} (drop the HTTP stream)
// Nothing the app sends for an old id is ever spoken.
//
// libconverse keeps everything around the model (bc_session_create_with_llm, >= 2.5.0): the
// crisis guard (a crisis turn never reaches the host), the bounded history, clause chunking,
// the speakable filter, Supertonic, barge-in and the avatar feed. This file only waits for text.
#if CONVERSE_AVAILABLE && CONVERSE_HOST_LLM
import CConverse
import Foundation

final class HostReplyLlm: @unchecked Sendable {
    /// Asks the app for a reply (main-thread hop is the caller's business).
    typealias Request = (_ id: Int, _ messages: [[String: String]], _ maxTokens: Int) -> Void

    private let request: Request
    private let cancelRequest: (Int) -> Void
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

    init(request: @escaping Request, cancelRequest: @escaping (Int) -> Void,
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
        cond.unlock()
        let t0 = Date()
        var n = 0
        var firstMs = -1
        var lastAt = t0
        var why = "done"
        defer {
            cond.lock(); current = -1; pieces.removeAll(); cond.unlock()
            NSLog("[bhhost] reply id=%d pieces=%d firstPieceMs=%d totalMs=%d end=%@ hostMs=%lld",
                  id, n, firstMs, Int(Date().timeIntervalSince(t0) * 1000), why, Self.ms())
        }
        NSLog("[bhhost] reply_request id=%d msgs=%d hostMs=%lld", id, msgs.count, Self.ms())
        request(id, msgs, maxTokens)
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
                why = "cancelled"; cancelRequest(id)
                return Int32(BC_LLM_OK.rawValue)
            }
            if timedOut {
                cancelRequest(id)
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
                        why = "stopped by the brain"; cancelRequest(id)
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
