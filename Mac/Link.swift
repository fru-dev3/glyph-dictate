import Foundation
import os

let log = Logger(subsystem: "dev.fru.jot.mac", category: "dictation")

/// Glyph Jot is one app in two processes. The app you see (library, Record, settings, the
/// menu bar) is the bundle's main executable; the dictation engine (the talk key, the pill,
/// typing into other apps) is a helper app inside it, `Contents/Helpers/Glyph Jot Dictation.app`,
/// started and watched by the main app. Meeting code can crash or hang and typing keeps working.
///
/// They talk over the engine's stdin (to the engine) and stdout (from it): one JSON object
/// per line, after a marker so a stray print can never be read as a message. The pipe is
/// private to the two, so nothing else on the Mac can make the engine type.
struct LinkMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        // to the engine
        case pasteLast, undo, useWhatISaid, insert, prefs, words, recording, quit
        // from the engine
        case ready, status, jot, thought, ask, show
    }

    var kind: Kind
    var text: String?
    var mode: String?
    var on: Bool?
    var at: Double?
    var recent: [String]?

    init(_ kind: Kind, text: String? = nil, mode: String? = nil, on: Bool? = nil, at: Double? = nil, recent: [String]? = nil) {
        self.kind = kind
        self.text = text
        self.mode = mode
        self.on = on
        self.at = at
        self.recent = recent
    }

    static let marker = "\u{00A7}jot "

    var line: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.marker + String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The message on a line, or nil for anything else (a log line, half a line).
    static func parse(_ line: Substring) -> LinkMessage? {
        guard line.hasPrefix(marker) else { return nil }
        return try? JSONDecoder().decode(LinkMessage.self, from: Data(line.dropFirst(marker.count).utf8))
    }
}

/// Splits a byte stream into lines across reads (a message can arrive in pieces).
struct LineBuffer {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [Substring] {
        pending.append(data)
        guard let last = pending.lastIndex(of: 0x0A) else { return [] }
        let text = String(decoding: pending[..<last], as: UTF8.self)
        pending = Data(pending[pending.index(after: last)...])
        return text.split(separator: "\n")
    }
}

/// Settings both processes share: the main app's own defaults (`dev.fru.jot.mac`), so Jot's
/// existing settings carry over and the engine reads what the settings window writes.
let jotDefaults: UserDefaults = Bundle.main.bundleIdentifier == "dev.fru.jot.mac"
    ? .standard : UserDefaults(suiteName: "dev.fru.jot.mac") ?? .standard

enum JotIDs {
    static let app = "dev.fru.jot.mac"
    static let engine = "dev.fru.jot.mac.engine"
}

/// "0.7 (12)", from the app's Info.plist (the engine carries Glyph Jot's version).
enum Version {
    static var text: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
