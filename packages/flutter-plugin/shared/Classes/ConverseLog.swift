import os

// Log shim for the ported SpeechPipeline.swift (originally from avatar-ui-kit).
enum Log {
    static let audio = Logger(subsystem: "ai.bithuman.avatar", category: "audio")
    static let asr = Logger(subsystem: "ai.bithuman.avatar", category: "asr")
}
