import Foundation
import GlyphCore

/// Making a new person or product goes through Glyph Studio's own command (`prevail entities
/// create`), so Studio stays the one writer of its objects. Without Studio installed, Glyph
/// Jot links only to objects that already exist.
enum StudioCommand {
    /// Studio's command inside its app. ponytail: the two install names it has had; add a
    /// setting when Studio lives somewhere else.
    static var url: URL? {
        ["/Applications/Glyph Studio.app/Contents/MacOS/prevail", "/Applications/Prevail.app/Contents/MacOS/prevail"]
            .map { URL(filePath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Makes a person or a product in the Studio vault at `vault`; returns its id, or nil.
    /// Blocks for a second or two: call it off the main actor.
    static func create(_ kind: StudioObject.Kind, _ name: String, notes: String = "", vault: URL) -> String? {
        guard let url, kind == .person || kind == .product else { return nil }
        let p = Process()
        p.executableURL = url
        p.arguments = ["entities", "create", "--kind", kind == .person ? "person" : "org", "--vault", vault.path, "--json"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        var draft: [String: String] = ["name": name]
        if !notes.isEmpty { draft["notes"] = notes }
        guard let body = try? JSONSerialization.data(withJSONObject: ["draft": draft]), (try? p.run()) != nil else { return nil }
        input.fileHandleForWriting.write(body)
        try? input.fileHandleForWriting.close()
        let deadline = Date.now.addingTimeInterval(30)
        while p.isRunning, Date.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let line = String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              json["ok"] as? Bool == true, let id = json["id"] as? String, StudioObject.isID(id) else {
            jotLog.error("studio: could not make \(kind.singular, privacy: .public) (\(line, privacy: .public))")
            return nil
        }
        jotLog.notice("studio: made \(id, privacy: .public)")
        return id
    }
}

/// One thing Glyph Jot captured, of any kind, for the All view.
struct Capture: Identifiable, Hashable {
    enum Kind: String { case note, dictation, recording }
    var kind: Kind
    var id: String
    var title: String
    var date: Date
    var links: [String] = []

    var symbol: String {
        switch kind {
        case .note: "note.text"
        case .dictation: "text.cursor"
        case .recording: "waveform"
        }
    }
}

extension Link {
    /// The Studio kind of an object link, or of a new name (`.person` a person, `.account` a product).
    var studioKind: StudioObject.Kind? {
        switch self {
        case .object(let id): StudioObject.Kind(id: id)
        case .person: .person
        case .account: .product
        case .tag: nil
        }
    }
}

extension StudioObject.Kind {
    /// The sidebar's and the chips' icon (SF Symbols close to Studio's lucide icons).
    var symbol: String {
        switch self {
        case .person: "person.fill"
        case .product: "shippingbox.fill"
        case .project: "flag.fill"
        case .domain: "square.grid.2x2.fill"
        }
    }

    /// The order Glyph Jot lists them in.
    static let listed: [StudioObject.Kind] = [.domain, .person, .product, .project]
}
