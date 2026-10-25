import AppKit
import SystemConfiguration

/// A thought (talk key + Shift) is a Markdown note with the same frontmatter as Jot on the
/// iPhone's memos. It goes in the notes folder chosen in Settings (any folder: an Obsidian
/// vault works), or `<vault>/data/domains/notes/source/jot` when that folder is a Prevail
/// vault, or `~/Documents/Jot/Thoughts` when none is chosen.
enum Thoughts {
    static var folder: URL {
        DictationLog.vault?.appending(path: "data/domains/notes/source/jot")
            ?? DictationLog.chosen
            ?? URL.documentsDirectory.appending(path: "Jot/Thoughts")
    }

    /// Saves it and returns the file's name.
    @discardableResult static func save(_ text: String) throws -> String {
        let now = Date.now
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss" // the phone's memo names
        let stem = f.string(from: now)
        let date = stem.prefix(10) + "T" + stem.dropFirst(11).replacingOccurrences(of: "-", with: ":")
        let device = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        let md = "---\ndate: \(date)\ntags: []\nkind: voice\ndevice: \(device)\nsource: jot\n---\n\n\(text)\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try md.write(to: folder.appending(path: stem + ".md"), atomically: true, encoding: .utf8)
        return stem + ".md"
    }
}

/// The words of a long dictation so far, saved every 10 seconds while you talk:
/// `<vault>/data/apps/jot/drafts/unfinished.<host>.txt`. Cleared when the dictation lands.
enum Draft {
    static var url: URL {
        DictationLog.folder.deletingLastPathComponent().appending(path: "drafts/unfinished.\(DictationLog.host).txt")
    }

    static func save(_ words: String) {
        guard !words.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? words.write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    /// The draft left by a dictation that never finished, removed as it's read.
    static func take() -> String? {
        defer { clear() }
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Every dictation, one JSON line each: `<YYYY-MM>.<host>.jsonl`, one file per Mac so syncing
/// the folder between Macs never conflicts. Beside it are the Dictionary and the draft. They live
/// in `data/apps/jot/` in a Prevail vault, in a hidden `.jot/` in any other notes folder (so they
/// sync with it but stay out of your notes), and in Application Support when none is chosen.
enum DictationLog {
    /// The notes folder: the one chosen in Settings, else this Mac's own (`LocalVault`).
    static var chosen: URL? {
        guard let path = jotDefaults.string(forKey: "vaultPath") ?? LocalVault.path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// The notes folder when it is a Prevail vault (it has `data/domains`).
    static var vault: URL? {
        chosen.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "data/domains").path) ? $0 : nil }
    }

    static var folder: URL {
        vault?.appending(path: "data/apps/jot/dictations")
            ?? chosen?.appending(path: ".jot/dictations")
            ?? URL.applicationSupportDirectory.appending(path: "Jot/dictations")
    }

    /// Same host naming as Prevail's prompt streams: "Mac-Name.local" -> "mac-name-local".
    /// From the Mac's own Bonjour name, never DNS: `ProcessInfo.hostName` asks the network,
    /// which hung the engine's launch for minutes and gave a second name on the tailnet.
    static let host: String = {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "mac"
        return (name + ".local").lowercased().replacingOccurrences(of: ".", with: "-")
    }()

    /// `heard` is the transcript before polishing (or the spoken command), so a bad cleanup
    /// can always be undone from the log.
    /// `project` (the repo or folder of a terminal or editor) is left out when unknown; older lines have none.
    static func append(text: String, heard: String, mode: String, app: NSRunningApplication?, project: String?,
                       seconds: Double, finishMs: Int) {
        let now = Date.now
        var entry: [String: Any] = [
            "at": now.ISO8601Format(),
            "text": text,
            "heard": heard,
            "mode": mode,
            "app": app?.localizedName ?? "",
            "bundle": app?.bundleIdentifier ?? "",
            "seconds": (seconds * 10).rounded() / 10,
            "finish_ms": finishMs,
        ]
        if let project { entry["project"] = project }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let month = now.formatted(.iso8601.year().month())
        add(line, to: folder.appending(path: "\(month).\(host).jsonl"))
    }

    /// Appends a line to a file, making the file and its folder if need be.
    static func add(_ line: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}
