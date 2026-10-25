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
        let tags = (fields["tags"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return JotNote(file: url.lastPathComponent, url: url, date: date, text: text,
                       device: fields["device"], place: fields["place"], tags: tags)
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

    func reload() {
        let folder = Thoughts.folder
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
                    ForEach(note.tags, id: \.self) { MetaChip(symbol: "number", text: $0) }
                    if let (id, at) = model.recordingFor(note: note.file), let meta = model.meta(id) {
                        Button {
                            model.sidebar = .all
                            model.selectedID = id
                            model.tab = .transcript
                        } label: {
                            MetaChip(symbol: "waveform", text: "\(meta.title) at \(Format.clock(at))")
                        }
                        .buttonStyle(.plain)
                        .help("Open the recording this note was said in")
                    }
                }
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
