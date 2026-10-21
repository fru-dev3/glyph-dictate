import SwiftUI

/// Every dictation from the vault log, newest first, searchable, with how much you've said.
/// Reads every Mac's file, so the history is the same on each.
struct HistoryView: View {
    @State private var entries: [Entry] = []
    @State private var search = ""
    @State private var copied: Entry.ID?
    private let ask = Ask.shared

    struct Entry: Decodable, Identifiable, Hashable {
        let at: Date
        let text: String
        let heard: String?
        let mode: String?
        let app: String
        let seconds: Double
        var id: String { at.ISO8601Format() + text.prefix(20) }
    }

    private var shown: [Entry] {
        search.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
    }

    private var days: [(Date, [Entry])] {
        Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = Dictation.shared.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 10)
            }
            if !ask.question.isEmpty { AskCard(copied: $copied).padding([.horizontal, .top]) }
            Stats(entries: entries).padding()
            Divider()
            List {
                ForEach(days, id: \.0) { day, items in
                    Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(items) { entry in row(entry) }
                    }
                }
            }
            .overlay { if shown.isEmpty { Text(entries.isEmpty ? "No dictations yet" : "Nothing matches").foregroundStyle(.secondary) } }
        }
        .searchable(text: $search)
        .toolbar {
            Button {
                Task { await ask.run(search) }
            } label: {
                Label("Ask", systemImage: "sparkle.magnifyingglass")
            }
            .help("Ask your dictations what's in the search box")
            .disabled(search.trimmingCharacters(in: .whitespaces).isEmpty || ask.busy)
        }
        .onChange(of: ask.busy) { if !ask.busy { entries = Self.load() } }
        .task { entries = Self.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            entries = Self.load()
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).textSelection(.enabled)
                Text([entry.app, entry.mode == "thought" ? "Thought" : entry.mode == "command" ? "Command"
                      : entry.mode == "ask" ? "Question" : entry.mode == "recovered" ? "Recovered" : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = entry.id
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copied == entry.id { copied = nil }
                }
            } label: {
                Image(systemName: copied == entry.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let heard = entry.heard, heard != entry.text {
                Button("Copy as Heard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(heard, forType: .string)
                }
            }
        }
    }

    static func load() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: DictationLog.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .flatMap { file in
                ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
                    .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
            }
            .sorted { $0.at > $1.at }
    }
}

/// The answer to a question about your history, with the dictations it came from.
private struct AskCard: View {
    private let ask = Ask.shared
    @Binding var copied: HistoryView.Entry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                Text(ask.question).font(.headline)
                Spacer()
                Button { ask.clear() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Close")
            }
            if ask.busy && ask.answer.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                // The model writes a little Markdown (**bold**); show it, not the asterisks.
                Text((try? AttributedString(markdown: ask.answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(ask.answer))
                    .textSelection(.enabled)
            }
            if !ask.sources.isEmpty {
                DisclosureGroup("From \(ask.sources.count) dictation\(ask.sources.count == 1 ? "" : "s")") {
                    ForEach(ask.sources.prefix(5)) { entry in
                        HStack(alignment: .top) {
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(entry.text).lineLimit(2).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
                .font(.callout)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private struct Stats: View {
    let entries: [HistoryView.Entry]

    private var words: Int { entries.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
    private var wpm: Int {
        let minutes = entries.reduce(0) { $0 + $1.seconds } / 60
        return minutes > 0 ? Int(Double(words) / minutes) : 0
    }
    private var thisWeek: Int {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return entries.filter { $0.at >= start }.count
    }

    var body: some View {
        HStack {
            Stat(value: words.formatted(), label: "words")
            Stat(value: entries.count.formatted(), label: "dictations")
            Stat(value: thisWeek.formatted(), label: "this week")
            Stat(value: wpm.formatted(), label: "words a minute")
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack {
            Text(value).font(.title.bold()).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
