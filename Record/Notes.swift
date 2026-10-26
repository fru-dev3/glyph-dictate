import AppKit
import GlyphCore
import SwiftUI

/// A note: a thought saved with Fn+Shift on the Mac or a memo from the Glyph iPhone app,
/// one Markdown file each in the notes folder (`Thoughts.folder`).
struct JotNote: Identifiable, Hashable {
    var id: String { file }
    let file: String
    let url: URL
    let date: Date
    let text: String
    let device: String?
    let place: String?
    let tags: [String]
    /// Glyph Studio objects it is filed under, by id (front matter `links: [person/sam-lee]`).
    var links: [String] = []

    /// Front matter between `---` lines, then the text. Missing fields stay nil.
    static func read(_ url: URL) -> JotNote? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        var body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) {
            for line in raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { fields[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            body = String(raw[end.upperBound...])
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let date = fields["date"].flatMap(parseDate) ?? stemDate(url.deletingPathExtension().lastPathComponent)
            ?? ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
        let list = { (key: String) in (fields[key] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty } }
        return JotNote(file: url.lastPathComponent, url: url, date: date, text: text,
                       device: fields["device"], place: fields["place"], tags: list("tags"), links: list("links"))
    }

    /// "2026-10-25T12:08:24", local time, as the phone and the Mac write it.
    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    private static func stemDate(_ stem: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.date(from: stem)
    }

    /// `raw` with these front matter lists set (added before the closing `---`, or in a new
    /// front matter); `links` is left out when empty.
    static func withFields(_ raw: String, _ fields: [String: [String]]) -> String {
        var head: [String] = [], body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) {
            head = raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            body = String(raw[end.upperBound...])
        } else {
            body = "\n\n" + raw
        }
        for key in fields.keys.sorted() {
            let values = fields[key] ?? []
            let line = "\(key): [\(values.joined(separator: ", "))]"
            if let i = head.firstIndex(where: { $0.hasPrefix(key + ":") }) {
                if values.isEmpty, key == "links" { head.remove(at: i) } else { head[i] = line }
            } else if !(values.isEmpty && key == "links") {
                head.append(line)
            }
        }
        return "---\n" + head.joined(separator: "\n") + "\n---" + body
    }

    var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        return first.count > 90 ? String(first.prefix(88)) + "\u{2026}" : first
    }
}

/// Every note, newest first; read again when the window comes forward or a note is saved.
@MainActor @Observable
final class NoteStore {
    static let shared = NoteStore()
    private(set) var notes: [JotNote] = []
    private(set) var dictationCount = 0

    /// Writes a note's `links` and `tags` into its front matter; every other line stays.
    func setLinks(_ file: String, links: [String], tags: [String]) throws {
        guard let note = notes.first(where: { $0.file == file }) else { return }
        let raw = try String(contentsOf: note.url, encoding: .utf8)
        let unique = { (xs: [String]) in xs.reduce(into: [String]()) { out, x in if !out.contains(x) { out.append(x) } } }
        let text = JotNote.withFields(raw, ["links": unique(links), "tags": unique(tags.map(LinkMatcher.tidyTag).filter { !$0.isEmpty })])
        try text.write(to: note.url, atomically: true, encoding: .utf8)
        reload()
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var settle: DispatchWorkItem?

    /// Reads the notes again whenever the folder changes: a note the phone sends, or fixes after
    /// it was sent, shows up without waiting for the window to come forward. The folder's own
    /// write event fires when a file in it is added, replaced or removed (the inbox and vault
    /// sync both replace files whole).
    private func watch(_ folder: URL) {
        guard watcher == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.settle?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { self?.reload() } }
            self?.settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func reload() {
        let folder = Thoughts.folder
        watch(folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        notes = files.filter { $0.pathExtension == "md" }.compactMap(JotNote.read).sorted { $0.date > $1.date }
        dictationCount = HistoryView.load().count
    }
}

/// Notes: a list and the open note, in the space the conversations use.
struct NotesPane: View {
    @Environment(AppModel.self) private var model
    @State private var store = NoteStore.shared
    @State private var selected: JotNote.ID?

    private var shown: [JotNote] {
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.notes : store.notes.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.place ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if model.showList {
                    list.frame(width: min(model.listWidth, max(250, geo.size.width * 0.4)))
                    ResizeHandle(width: Binding(get: { model.listWidth }, set: { model.listWidth = $0 }))
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear {
            if let note = model.openNote { selected = note; model.openNote = nil }
            if selected == nil { selected = shown.first?.id }
        }
        .onChange(of: model.openNote) { if let note = model.openNote { selected = note; model.openNote = nil } }
        .onChange(of: model.searchText) { if !shown.contains(where: { $0.id == selected }) { selected = shown.first?.id } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Notes", symbol: "note.text", line: shown.count == 1 ? "1 note" : "\(shown.count) notes")
            if shown.isEmpty {
                EmptyState(symbol: "note.text", title: model.searchText.isEmpty ? "No notes yet" : "No matches",
                           message: model.searchText.isEmpty ? "Hold Fn and Shift, say a thought, let go. It lands here." : "No note says \u{201C}\(model.searchText)\u{201D}.")
            } else {
                List(selection: $selected) {
                    ForEach(shown) { note in
                        NoteRow(note: note, linked: model.recordingFor(note: note.file) != nil).tag(note.id)
                            .contextMenu { NoteMenu(note: note) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder private var detail: some View {
        if let note = shown.first(where: { $0.id == selected }) {
            NoteDetail(note: note).id(note.id)
        } else {
            EmptyState(symbol: "note.text", title: "Pick a note") {
                VStack(alignment: .leading, spacing: 10) {
                    KeyHint(keys: "fn \u{21E7}", label: "Hold to say a note, anywhere")
                    KeyHint(keys: "fn", label: "Hold to type what you say, where you are")
                }
            }
        }
    }
}

/// The big title over a list: what it is and how many.
struct PaneHeader: View {
    let title: String
    let symbol: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(line)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct NoteRow: View {
    let note: JotNote
    let linked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 5) {
                Text(Format.shortDate(note.date.ISO8601Format()))
                if let device = note.device { Text("\u{00B7}"); Text(device).lineLimit(1) }
                Spacer(minLength: 4)
                if linked {
                    Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(.tint)
                        .help("Said during a recording")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

struct NoteDetail: View {
    let note: JotNote
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Menu { NoteMenu(note: note) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
                        .help("More")
                }
                FlowLayout(spacing: 6) {
                    if let device = note.device { MetaChip(symbol: note.device?.contains("iPhone") == true ? "iphone" : "laptopcomputer", text: device) }
                    if let place = note.place { MetaChip(symbol: "mappin.and.ellipse", text: place) }
                    if let (id, at) = model.recordingFor(note: note.file), let meta = model.meta(id) {
                        Button {
                            model.sidebar = .recordings
                            model.selectedID = id
                            model.tab = .transcript
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                                Text("\(meta.title) at \(Format.clock(at))").font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open the recording this note was said in")
                    }
                }
                LinkEditor(target: .note(note.file), links: note.links.map { .object($0) } + note.tags.map { .tag($0) })
                Text(note.text)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Button { Engine.shared.send(.init(.insert, text: note.text)) } label: { Label("Insert", systemImage: "text.insert") }
                        .help("Type it into the app you were in")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NoteMenu: View {
    let note: JotNote

    var body: some View {
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        }
        Button("Open in Default App") { NSWorkspace.shared.open(note.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
    }
}

/// Dictations: everything you said into other apps, with stats, filters and Ask.
struct DictationsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HistoryView(search: model.searchText)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Notes that name a person or an account (or one of its aliases), for its page.
@MainActor
func notesMentioning(_ names: [String]) -> [JotNote] {
    let words = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
    guard !words.isEmpty else { return [] }
    return NoteStore.shared.notes.filter { note in
        words.contains { w in note.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
