import GlyphCore
import SwiftUI

/// All: a calm summary across notes, dictations and recordings. Ask on top, the three kinds
/// with their counts, the latest captures (or what the search finds), and what is filed
/// under which Glyph Studio object.
struct AllPane: View {
    @Environment(AppModel.self) private var model
    @State private var store = NoteStore.shared
    @State private var dictations: [HistoryView.Entry] = []
    @State private var question = ""
    @FocusState private var asking: Bool
    private let ask = Ask.shared

    var body: some View {
        let search = model.searchText.trimmingCharacters(in: .whitespaces)
        let all = captures
        let shown = search.isEmpty ? Array(all.prefix(12)) : matches(all, search)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All").font(.system(size: 30, weight: .bold))
                    Text("Everything you captured, and where it is filed in Glyph Studio")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                askBar
                if !ask.question.isEmpty { AskCard(copied: .constant(nil)) }
                tiles(all)
                section(search.isEmpty ? "Recent" : "Matches for \u{201C}\(search)\u{201D}", count: search.isEmpty ? nil : shown.count) {
                    if shown.isEmpty {
                        Text(search.isEmpty ? "Nothing captured yet. Hold Fn to jot, or press Record." : "Nothing you captured says that.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(shown) { CaptureRow(capture: $0) }
                        }
                    }
                }
                filed
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .task { dictations = HistoryView.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in dictations = HistoryView.load() }
    }

    // MARK: ask

    private var askBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
                TextField("Ask anything about what you captured", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($asking)
                    .onSubmit(run)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(asking ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
            Button("Ask", action: run)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || ask.busy)
        }
    }

    private func run() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let sources = Self.askSources(model, dictations: dictations)
        Task { await ask.run(q, over: sources, show: false) }
    }

    /// What Ask reads: every dictation, note and recording (its title, links and summary).
    static func askSources(_ model: AppModel, dictations: [HistoryView.Entry]? = nil) -> [HistoryView.Entry] {
        let notes = NoteStore.shared.notes.map {
            HistoryView.Entry(at: $0.date, text: $0.text, heard: nil, mode: "note", app: "Notes", project: nil, device: $0.device, seconds: 0)
        }
        let recordings = model.library.conversations.prefix(200).map { c in
            let summary = model.vault.notes(c.id).summary
            let filed = c.links.map(model.studio.name).joined(separator: ", ")
            return HistoryView.Entry(at: Format.date(c.created) ?? .distantPast, text: [c.title, filed, summary].filter { !$0.isEmpty }.joined(separator: ". "),
                                     heard: nil, mode: "recording", app: "Recording", project: nil, device: c.device, seconds: Double(c.durationSec))
        }
        return (dictations ?? HistoryView.load()) + notes + recordings
    }

    // MARK: the three kinds

    var captures: [Capture] { Self.captures(model, notes: store.notes, dictations: dictations) }

    static func captures(_ model: AppModel, notes: [JotNote], dictations: [HistoryView.Entry]) -> [Capture] {
        let recordings = model.library.conversations.map {
            Capture(kind: .recording, id: $0.id, title: $0.title, date: Format.date($0.created) ?? .distantPast, links: $0.links)
        }
        let notes = notes.map { Capture(kind: .note, id: $0.file, title: $0.title, date: $0.date, links: $0.links) }
        let said = dictations.filter { $0.mode != "ask" }.map {
            Capture(kind: .dictation, id: $0.id, title: String($0.text.prefix(120)), date: $0.at, links: [])
        }
        return (recordings + notes + said).sorted { $0.date > $1.date }
    }

    private func matches(_ all: [Capture], _ search: String) -> [Capture] {
        let hits = model.searchHits ?? []
        let q = search.lowercased()
        let text = Dictionary(store.notes.map { ($0.file, $0.text) }, uniquingKeysWith: { a, _ in a })
            .merging(dictations.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        return Array(all.filter { c in
            switch c.kind {
            case .recording: hits.contains(c.id)
            default: (text[c.id] ?? c.title).lowercased().contains(q) || c.links.contains { model.studio.name($0).lowercased().contains(q) }
            }
        }.prefix(50))
    }

    private func tiles(_ all: [Capture]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            tile("Notes", "note.text", .notes, all.filter { $0.kind == .note })
            tile("Dictations", "text.cursor", .dictations, all.filter { $0.kind == .dictation })
            tile("Recordings", "waveform", .recordings, all.filter { $0.kind == .recording })
        }
    }

    private func tile(_ title: String, _ symbol: String, _ item: SidebarItem, _ items: [Capture]) -> some View {
        Button { model.sidebar = item } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(items.count.formatted())
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                Text(items.first.map { "Latest " + Format.shortDate($0.date.ISO8601Format()) } ?? "None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
    }

    // MARK: filed in Studio

    private var filed: some View {
        let counts = model.linkCounts.objects
        return section("Filed in Glyph Studio", count: nil) {
            if counts.isEmpty {
                Text("Nothing filed yet. Open a note or a recording and press + to file it under a domain, person, product or project.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(StudioObject.Kind.listed, id: \.self) { kind in
                        let ids = counts.keys.filter { StudioObject.Kind(id: $0) == kind }
                            .sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : model.studio.name($0) < model.studio.name($1) }
                        if !ids.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(kind.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                FlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(ids, id: \.self) { id in CountChip(link: .object(id), count: counts[id] ?? 0) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, count: Int?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 20, weight: .semibold))
                if let count { Text(count.formatted()).font(.system(size: 14)).foregroundStyle(.secondary).monospacedDigit() }
            }
            content()
        }
    }
}

/// One capture in All: its kind, title, when, and what it is filed under. Click opens it.
struct CaptureRow: View {
    let capture: Capture
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.open(capture) } label: {
            HStack(spacing: 12) {
                Image(systemName: capture.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(capture.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(capture.kind.rawValue.capitalized + " \u{00B7} " + Format.shortDate(capture.date.ISO8601Format()))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        ForEach(capture.links.prefix(3), id: \.self) { LinkChip(link: .object($0), size: .small).fixedSize() }
                        if capture.links.count > 3 {
                            Text("+\(capture.links.count - 3)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open this \(capture.kind.rawValue)")
    }
}

/// A Studio object with how many captures it has; click opens its page.
struct CountChip: View {
    let link: Link
    let count: Int
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { if let item = link.sidebarItem { model.sidebar = item } } label: {
            HStack(spacing: 6) {
                Image(systemName: link.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tint)
                Text(link.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(count.formatted()).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.accentColor.opacity(hover ? 0.16 : 0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
        .help("Show everything filed under \(link.label)")
    }
}
