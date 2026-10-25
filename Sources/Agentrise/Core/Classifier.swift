// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

enum TurnOutcome: Equatable {
    case waiting(summary: String?)
    case done
}

/// Decides whether a finished turn is asking the CEO something. Biased toward
/// "waiting": a missed question costs more than an extra glance.
enum WaitingClassifier {
    static let phrases = ["要不要", "是否", "你希望", "你想", "请确认", "请选择", "需要你", "你来决定", "告诉我",
                          "可以吗", "吗？", "哪个", "哪种", "还是", "确认一下", "等你", "your call",
                          "should i", "do you want", "would you like", "let me know", "which one", "shall i"]

    static func classify(_ message: String?) -> TurnOutcome {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .done }
        while let last = text.last, "`*_>#-~ \n".contains(last) { text.removeLast() }
        let tail = String(text.suffix(400))
        let lower = tail.lowercased()
        let lastPara = lower.components(separatedBy: "\n\n").last ?? lower
        let asks = text.hasSuffix("?") || text.hasSuffix("？") || phrases.contains { lastPara.contains($0) }
        guard asks else { return .done }
        return .waiting(summary: summary(of: tail))
    }

    static func summary(of text: String) -> String? {
        let parts = text.split(whereSeparator: { "\n。！!".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pick = parts.last(where: { $0.contains("?") || $0.contains("？") }) ?? parts.last
        guard var s = pick else { return nil }
        s = s.replacingOccurrences(of: "**", with: "")
        return s.count > 60 ? String(s.prefix(59)) + "…" : s
    }
}
