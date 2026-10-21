@preconcurrency import AVFoundation
import Speech

/// Apple's on-device speech models, wrapped so live recording and "transcribe the saved
/// audio" share one path, on the phone and on the Mac (the JotMac target builds this file too). SpeechTranscriber is the long-form model; DictationTranscriber
/// is the fallback on phones that can't run it.
enum Transcription {
    /// Names, as the model mishears them -> as they're spelled. Whole words, any case. The
    /// model takes the spellings as a hint too. Only general ones here: your own names come
    /// from the Dictionary on the Mac, and from the phone's own list on the iPhone.
    static var corrections = [
        "claude": "Claude", "chatgpt": "ChatGPT", "github": "GitHub", "macos": "macOS", "jot": "Jot",
    ]
    static var vocabulary: [String] { Array(Set(corrections.values)) }

    static func corrected(_ text: String) -> String {
        corrections.reduce(withoutFillers(text)) { text, fix in
            text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: fix.key))\\b", with: fix.value,
                                      options: [.regularExpression, .caseInsensitive])
        }
    }

    /// um, uh, ah, er, erm, hmm, mm. Not "uh-huh" (that's a yes).
    private static let filler = "(?<![-'])\\b(?:u+m+|u+h+m*|a+h+|e+r+m*|h+m+|m{2,})\\b(?![-'])"

    /// "Um, so I was, uh, thinking" -> "So I was thinking".
    static func withoutFillers(_ text: String) -> String {
        var s = text
        // At the start of a sentence: drop it and capitalize what follows. Repeat for "Uh, um, so".
        while true {
            let next = replace(s, "(^|[.?!]\\s+)\(filler)[,.?!]?\\s*(\\w?)") { $0[1] + $0[2].uppercased() }
            if next == s { break }
            s = next
        }
        // Mid-sentence: drop it with the commas around it.
        s = replace(s, ",?[ \\t]*\(filler),?") { _ in "" }
        s = replace(s, "[ \\t]{2,}") { _ in " " }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ s: String, _ pattern: String, _ with: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
        let ns = s as NSString
        let out = NSMutableString(string: s)
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<m.numberOfRanges).map {
                m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
            }
            out.replaceCharacters(in: m.range, with: with(groups))
        }
        return out as String
    }

    /// A new paragraph starts after a pause this long.
    static let paragraphPause = 2.0

    struct Piece: Sendable {
        let text: String
        let range: CMTimeRange
        let isFinal: Bool
    }

    struct Module: @unchecked Sendable {
        let module: any SpeechModule
        let pieces: AsyncThrowingStream<Piece, Error>
    }

    static var context: AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        return context
    }

    /// A ready module, or `JotError.notReady` when the model isn't on the phone yet,
    /// in which case the download starts in the background and pending memos run after.
    static func make(live: Bool) async throws -> Module {
        if SpeechTranscriber.isAvailable {
            guard let locale = await resolved(SpeechTranscriber.supportedLocale) else {
                throw JotError("Speech recognition doesn't support this language.")
            }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: live ? [.volatileResults] : [], attributeOptions: [])
            try await ensureInstalled(t)
            return Module(module: t, pieces: stream(t.results) {
                Piece(text: String($0.text.characters), range: $0.range, isFinal: $0.isFinal)
            })
        }
        guard let locale = await resolved(DictationTranscriber.supportedLocale) else {
            throw JotError("Speech recognition doesn't support this language.")
        }
        let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                     reportingOptions: live ? [.volatileResults] : [], attributeOptions: [])
        try await ensureInstalled(t)
        return Module(module: t, pieces: stream(t.results) {
            Piece(text: String($0.text.characters), range: $0.range, isFinal: $0.isFinal)
        })
    }

    /// The language and the model reservation are looked up once per launch, not per
    /// recording: on the Mac those calls have been seen to never answer now and then.
    private static var resolvedLocale: Locale?

    private static func resolved(_ supported: (Locale) async -> Locale?) async -> Locale? {
        if let resolvedLocale { return resolvedLocale }
        guard let locale = await locale(supported) else { return nil }
        _ = try? await AssetInventory.reserve(locale: locale) // so iOS keeps the model on the phone
        resolvedLocale = locale
        return locale
    }

    /// The phone's language if the model knows it, else US English.
    private static func locale(_ supported: (Locale) async -> Locale?) async -> Locale? {
        if let locale = await supported(.current) { return locale }
        return await supported(Locale(identifier: "en-US"))
    }

    /// Call at launch so the model is downloaded before the first recording needs it.
    static func prewarm() async {
        _ = try? await make(live: true)
    }

    private static func ensureInstalled(_ module: any SpeechModule) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .unsupported:
            throw JotError("Speech recognition isn't available on this iPhone.")
        default:
            Task {
                if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try? await request.downloadAndInstall()
                }
            }
            throw JotError.notReady
        }
    }

    private static func stream<S: AsyncSequence & Sendable>(
        _ results: S, _ map: @escaping @Sendable (S.Element) -> Piece
    ) -> AsyncThrowingStream<Piece, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results { continuation.yield(map(result)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Transcribes a saved recording start to finish.
    @MainActor
    static func file(_ url: URL) async throws -> String {
        let m = try await make(live: false)
        let audio = try AVAudioFile(forReading: url)
        let collect = Task {
            var builder = TranscriptBuilder()
            for try await piece in m.pieces where piece.isFinal { builder.add(piece) }
            return builder.text
        }
        let analyzer = SpeechAnalyzer(modules: [m.module])
        try await analyzer.setContext(context)
        try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
        return try await collect.value
    }
}

/// Joins finished phrases, starting a new paragraph after a long pause,
/// so a five-minute ramble pastes into Docs as paragraphs, not one wall.
struct TranscriptBuilder {
    private(set) var text = ""
    private var lastEnd: Double?

    mutating func add(_ piece: Transcription.Piece) {
        let words = Transcription.corrected(piece.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !words.isEmpty else { return }
        let start = CMTimeGetSeconds(piece.range.start)
        if text.isEmpty {
            text = words
        } else if let lastEnd, start - lastEnd >= Transcription.paragraphPause {
            text += "\n\n" + words
        } else {
            text += " " + words
        }
        lastEnd = CMTimeGetSeconds(piece.range.end)
    }

    /// What the text would read like with this unfinished phrase on the end.
    func separator(before piece: Transcription.Piece) -> String {
        guard !text.isEmpty else { return "" }
        if let lastEnd, CMTimeGetSeconds(piece.range.start) - lastEnd >= Transcription.paragraphPause { return "\n\n" }
        return " "
    }
}


struct JotError: LocalizedError, Equatable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
    static let notReady = JotError("The speech model is still downloading.")
}
