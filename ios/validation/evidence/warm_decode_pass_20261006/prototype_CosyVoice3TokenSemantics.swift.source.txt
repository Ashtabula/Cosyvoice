// CosyVoice3TokenSemantics.swift
// Requirement: centralize audited token semantics without exposing model-internal IDs in the public API.
import Foundation

enum CosyVoice3TokenSemantics {
    static let speechTokenCount=6561
    static let sos=6561
    static let eos=6562
    static let task=6563
    static let fill=6564
    static let logitsCount=6761
    static let stopRange=6561...6760
    static func isSpeech(_ id: Int) -> Bool { (0..<speechTokenCount).contains(id) }
    static func isStop(_ id: Int) -> Bool { stopRange.contains(id) }
}

// Purpose: single internal source for EOS/stop terminology proven by the 2026-10-02 semantic audit.
// Upstream: CosyVoice3LM/Qwen2LM/TransformerLM audit at development commit8789402.
// Runtime: pure Swift; no behavior change.
// Generated: 2026-10-02 America/New_York.
