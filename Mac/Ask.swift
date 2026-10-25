import AppKit

/// Ask your history: talk key + Option, then a question ("what did I tell Claude about the
/// ship script?"). Jot finds the dictations that match and Apple's on-device model answers
/// from them only. The answer opens on Home, with the dictations it came from.
@Observable @MainActor
final class Ask {
    static let shared = Ask()

    private(set) var question = ""
    private(set) var answer = ""
    private(set) var sources: [HistoryView.Entry] = []
    private(set) var busy = false

    func run(_ question: String) async {
        self.question = question
        answer = ""
        busy = true
        defer { busy = false }
        MainWindow.show()
        sources = Self.find(question, in: HistoryView.load())
        guard !sources.isEmpty else { answer = "Nothing you've dictated matches that."; return }
        do {
            answer = try await AI.ask(question, from: sources)
        } catch {
            answer = error.localizedDescription
        }
        log.info("ask: answered from \(self.sources.count) dictations")
        #if DEBUG
        log.info("ask: \(self.answer, privacy: .public)")
        #endif
    }

    func clear() {
        question = ""
        answer = ""
        sources = []
    }

    private static let little: Set<String> = [
        "what", "when", "where", "which", "who", "why", "how", "did", "does", "do", "the", "and", "for", "about", "that",
        "this", "with", "from", "was", "were", "have", "has", "say", "said", "tell", "told", "me", "my", "you", "your",
        "are", "is", "it", "its", "a", "an", "of", "to", "in", "on", "at", "i", "can", "could", "would", "there", "last",
    ]

    /// The dictations sharing the most of the question's words, newest first among equals.
    /// Questions and earlier answers aren't sources.
    static func find(_ question: String, in entries: [HistoryView.Entry], limit: Int = 10) -> [HistoryView.Entry] {
        let keys = Set(Rules.words(question).filter { $0.count >= 3 && !little.contains($0) })
        guard !keys.isEmpty else { return [] }
        var scored: [(entry: HistoryView.Entry, score: Int)] = []
        for entry in entries where entry.mode != "ask" {
            let text = entry.text.lowercased()
            let score = keys.filter { text.contains($0) }.count
            if score > 0 { scored.append((entry, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.at > $1.entry.at }
        return scored.prefix(limit).map(\.entry)
    }
}
