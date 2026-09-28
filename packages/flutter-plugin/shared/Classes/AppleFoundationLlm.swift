// Apple's on-device model (the Foundation Models framework: iOS / macOS 26 with
// Apple Intelligence) as the LLM of the on-device brain. Nothing to download:
// the model ships with the OS. Where it is not available the brain keeps
// running Llama 3.2 1B through llama.cpp.
//
// Two parts:
//   * AppleLlmStatus — whether the brain can use Apple's model here, and why
//     not (compiled on every build: the app asks BEFORE it downloads Llama).
//   * AppleFoundationLlm — the bridge libconverse calls through its host-LLM C
//     ABI (bc_session_create_with_llm, libconverse >= 2.5.0). The brain keeps
//     the safety net (a self-harm turn never reaches the model), the speakable
//     filter, sentence chunking, the TTS pipeline, barge-in and the bounded
//     history; this file only turns a message list into a streamed reply.
//
// FoundationModels is weak-linked (podspec `weak_frameworks`): the plugin still
// loads on iOS / macOS versions that do not have it.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device brain can run Apple's model on this device.
///
/// One of: `available` · `deviceNotEligible` (no Apple Intelligence hardware:
/// use Llama) · `appleIntelligenceNotEnabled` (the user can turn it on in
/// Settings → Apple Intelligence & Siri) · `modelNotReady` (turned on, model
/// still downloading: use Llama now, ask again later) · `unsupportedLocale` ·
/// `unsupportedOS` (older than iOS / macOS 26) · `notBuilt` (this plugin build
/// has no Foundation Models bridge, or its brain predates the host-LLM ABI) ·
/// `unavailable` (a reason newer than this build).
enum AppleLlmStatus {
    static func current() -> String {
        #if canImport(FoundationModels) && CONVERSE_HOST_LLM
        guard #available(iOS 26.0, macOS 26.0, *) else { return "unsupportedOS" }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            // The brain speaks English (the Supertonic voice + the en-US recognizer).
            return model.supportsLocale(Locale(identifier: "en_US")) ? "available" : "unsupportedLocale"
        case .unavailable(.deviceNotEligible): return "deviceNotEligible"
        case .unavailable(.appleIntelligenceNotEnabled): return "appleIntelligenceNotEnabled"
        case .unavailable(.modelNotReady): return "modelNotReady"
        default: return "unavailable"
        }
        #else
        return "notBuilt"
        #endif
    }
}

#if CONVERSE_AVAILABLE && CONVERSE_HOST_LLM && canImport(FoundationModels)
import CConverse

/// libconverse host LLM backed by `LanguageModelSession`.
///
/// Session reuse: the brain re-sends the whole (bounded) conversation every
/// turn. When that conversation is exactly the previous one plus the reply we
/// streamed plus a new user message, the SAME LanguageModelSession answers the
/// new message, so the model keeps its cached prefix (measured on an M4: first
/// text ~0.42 s, vs ~0.51 s for a session rebuilt from a transcript every turn).
/// Anything else — the history was trimmed, a split utterance was merged, a
/// reply was barged or refused, the system prompt changed (crisis mode) — gets a
/// fresh session built from the brain's messages, so the model never sees a
/// turn the brain dropped (a refused prompt left in a transcript makes the model
/// refuse every later turn too).
@available(iOS 26.0, macOS 26.0, *)
final class AppleFoundationLlm: @unchecked Sendable {
    /// Appended to the persona. Apple's model is chattier than the 1B Llama the
    /// persona prompts were written for (asked to name a goldfish it answered
    /// with a numbered list of nine names), and every extra sentence is seconds
    /// of speech before the user can talk again.
    static let spokenStyle =
        " Always answer in one or two short sentences, under 30 words in total. "
        + "Never use lists, numbering, headings or bold text."

    private struct Msg: Equatable { let role: String; let content: String }

    private let model = SystemLanguageModel.default
    private let lock = NSLock()
    private var session: LanguageModelSession?
    // What `session` has seen, to decide reuse (see the type doc).
    private var seenSystem: String?
    private var seenHistory: [Msg] = []
    private var seenUser: String?          // nil: fresh from warm(), nothing asked yet
    private var reusable = false           // the last turn finished normally

    // ── C ABI plumbing ────────────────────────────────────────────────────────
    /// A bc_host_llm_t that owns a +1 reference to `self` (released by the brain).
    func hostLlm(refusalReply: UnsafePointer<CChar>?) -> bc_host_llm_t {
        var h = bc_host_llm_t()
        h.abi_version = UInt32(BC_ABI_VERSION)
        h.ud = Unmanaged.passRetained(self).toOpaque()
        h.stream = { ud, msgs, n, maxTokens, emit, ctx in
            guard let ud, let emit else { return Int32(BC_LLM_ERROR.rawValue) }
            let me = Unmanaged<AppleFoundationLlm>.fromOpaque(ud).takeUnretainedValue()
            return me.stream(AppleFoundationLlm.messages(msgs, n), maxTokens: Int(maxTokens), emit: emit, ctx: ctx)
        }
        h.warm = { ud, msgs, n in
            guard let ud else { return }
            Unmanaged<AppleFoundationLlm>.fromOpaque(ud).takeUnretainedValue().warm(AppleFoundationLlm.messages(msgs, n))
        }
        h.release = { ud in
            guard let ud else { return }
            Unmanaged<AppleFoundationLlm>.fromOpaque(ud).release()
        }
        h.refusal_reply = refusalReply
        return h
    }

    private static func messages(_ p: UnsafePointer<bc_chat_message_t>?, _ n: Int) -> [Msg] {
        guard let p else { return [] }
        return (0..<n).map { i in
            Msg(role: p[i].role.map { String(cString: $0) } ?? "",
                content: p[i].content.map { String(cString: $0) } ?? "")
        }
    }

    // ── warm: build the session for the persona and prewarm the model ─────────
    private func warm(_ msgs: [Msg]) {
        let system = msgs.first(where: { $0.role == "system" })?.content ?? ""
        let s = LanguageModelSession(model: model, instructions: system + Self.spokenStyle)
        s.prewarm()
        lock.lock()
        session = s; seenSystem = system; seenHistory = []; seenUser = nil; reusable = true
        lock.unlock()
    }

    // ── stream: one reply, deltas handed to the brain on ITS thread ───────────
    private func stream(_ msgs: [Msg], maxTokens: Int, emit: bc_llm_emit_fn,
                        ctx: UnsafeMutableRawPointer?) -> Int32 {
        guard let last = msgs.last, last.role == "user" else { return Int32(BC_LLM_ERROR.rawValue) }
        let system = msgs.first(where: { $0.role == "system" })?.content ?? ""
        let history = Array(msgs.dropFirst(msgs.first?.role == "system" ? 1 : 0).dropLast())
        let s = sessionFor(system: system, history: history)

        let box = DeltaBox()
        let options = GenerationOptions(temperature: 0.7,
                                        maximumResponseTokens: maxTokens > 0 ? maxTokens : 120)
        let prompt = last.content
        let task = Task.detached(priority: .userInitiated) {
            var prev = ""
            do {
                for try await snap in s.streamResponse(to: prompt, options: options) {
                    // Snapshots are cumulative; hand over only what is new.
                    let cur = snap.content
                    let delta: String
                    if cur.hasPrefix(prev) { delta = String(cur.dropFirst(prev.count)) }
                    else { delta = String(cur.dropFirst(cur.commonPrefix(with: prev).count)) }
                    prev = cur
                    if !delta.isEmpty { box.push(delta) }
                }
                box.finish(Int32(BC_LLM_OK.rawValue))
            } catch let e as LanguageModelSession.GenerationError {
                box.finish(Self.result(for: e))
            } catch is CancellationError {
                box.finish(Int32(BC_LLM_OK.rawValue))
            } catch {
                NSLog("[Converse] Apple LLM error: %@", "\(error)")
                box.finish(Int32(BC_LLM_ERROR.rawValue))
            }
        }

        while true {
            let (pieces, done) = box.take()
            for piece in pieces {
                let keepGoing = piece.withCString { emit(ctx, $0) }
                if keepGoing == 0 {           // barge-in: stop now, never reuse this session
                    task.cancel()
                    record(system: system, history: history, user: prompt, ok: false)
                    return Int32(BC_LLM_OK.rawValue)
                }
            }
            if let rc = done {
                record(system: system, history: history, user: prompt, ok: rc == Int32(BC_LLM_OK.rawValue))
                return rc
            }
        }
    }

    private func sessionFor(system: String, history: [Msg]) -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        if let s = session, reusable, !s.isResponding, seenSystem == system {
            if seenUser == nil && history.isEmpty { return s }            // first turn after warm()
            if let u = seenUser, history.count == seenHistory.count + 2,
               Array(history.prefix(seenHistory.count)) == seenHistory,
               history[seenHistory.count] == Msg(role: "user", content: u),
               history.last?.role == "assistant" {
                return s                                                  // previous turn + our reply
            }
        }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: system + Self.spokenStyle))],
                                                  toolDefinitions: []))]
        for m in history where !m.content.isEmpty {
            if m.role == "user" {
                entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: m.content))])))
            } else if m.role == "assistant" {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: m.content))])))
            }
        }
        let s = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
        session = s
        return s
    }

    private func record(system: String, history: [Msg], user: String, ok: Bool) {
        lock.lock()
        seenSystem = system; seenHistory = history; seenUser = user; reusable = ok
        lock.unlock()
    }

    private static func result(for e: LanguageModelSession.GenerationError) -> Int32 {
        switch e {
        case .guardrailViolation, .refusal: return Int32(BC_LLM_REFUSED.rawValue)
        case .exceededContextWindowSize: return Int32(BC_LLM_CONTEXT_FULL.rawValue)
        default:
            NSLog("[Converse] Apple LLM generation error: %@", "\(e)")
            return Int32(BC_LLM_ERROR.rawValue)
        }
    }
}

/// Deltas from the generation task to the brain's worker thread (which blocks in
/// `take` — it is a plain std::thread, never a Swift concurrency thread).
private final class DeltaBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var pieces: [String] = []
    private var done: Int32?
    func push(_ s: String) { lock.lock(); pieces.append(s); lock.unlock(); sem.signal() }
    func finish(_ rc: Int32) { lock.lock(); if done == nil { done = rc }; lock.unlock(); sem.signal() }
    func take() -> ([String], Int32?) {
        while true {
            sem.wait()
            lock.lock()
            let p = pieces, d = done
            pieces.removeAll()
            lock.unlock()
            if !p.isEmpty || d != nil { return (p, d) }
        }
    }
}
#endif
