import SwiftUI

/// Every dictation from the vault log, newest first, searchable, with how much you've said.
/// Reads every Mac's file, so the history is the same on each. Filter by app, project or Starred;
/// Insert Again types one into the app you were in before Jot.
struct HistoryView: View {
    @State private var entries: [Entry] = []
    @State private var search = ""
    @State private var copied: Entry.ID?
    @State private var stars: Set<String> = []
    /// "" for all, "starred", "app:<name>" or "project:<name>".
    @AppStorage("historyFilter") private var filter = ""
    private let ask = Ask.shared

    struct Entry: Decodable, Identifiable, Hashable {
        let at: Date
        let text: String
        let heard: String?
        let mode: String?
        let app: String
        /// The repo or folder of a terminal or editor; nil when unknown and in older lines.
        let project: String?
        let seconds: Double
        var id: String { at.ISO8601Format() + text.prefix(20) }
    }

    private var shown: [Entry] {
        entries.filter { entry in
            switch filter {
            case "": true
            case "starred": stars.contains(entry.id)
            case let f where f.hasPrefix("app:"): entry.app == f.dropFirst(4)
            default: entry.project.map { "project:" + $0 } == filter
            }
        }
        .filter { search.isEmpty || [$0.text, $0.app, $0.project ?? ""].contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    private var apps: [String] { Set(entries.map(\.app).filter { !$0.isEmpty }).sorted() }
    private var projects: [String] { Set(entries.compactMap(\.project)).sorted { $0.localizedCompare($1) == .orderedAscending } }

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
            Picker(selection: $filter) {
                Text("All").tag("")
                Label("Starred", systemImage: "star").tag("starred")
                if !apps.isEmpty {
                    Section("Apps") { ForEach(apps, id: \.self) { Text($0).tag("app:" + $0) } }
                }
                if !projects.isEmpty {
                    Section("Projects") { ForEach(projects, id: \.self) { Text($0).tag("project:" + $0) } }
                }
            } label: {
                Label("Filter", systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .pickerStyle(.menu)
            .help("Show one app, one project, or the starred ones")
            Button {
                Task { await ask.run(search) }
            } label: {
                Label("Ask", systemImage: "sparkle.magnifyingglass")
            }
            .help("Ask your dictations what's in the search box")
            .disabled(search.trimmingCharacters(in: .whitespaces).isEmpty || ask.busy)
        }
        .onChange(of: ask.busy) { if !ask.busy { entries = Self.load() } }
        .task { entries = Self.load(); stars = Stars.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            entries = Self.load()
            stars = Stars.load()
        }
    }

    private func copy(_ text: String, _ entry: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = entry.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == entry.id { copied = nil }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).textSelection(.enabled)
                Text([entry.app, entry.project, entry.mode == "thought" ? "Thought" : entry.mode == "command" ? "Command"
                      : entry.mode == "ask" ? "Question" : entry.mode == "recovered" ? "Recovered" : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await LastApp.insert(entry.text) } } label: { Image(systemName: "text.insert") }
                .buttonStyle(.borderless)
                .help(LastApp.app?.localizedName.map { "Insert again in \($0)" } ?? "Insert again")
                .accessibilityLabel("Insert Again")
            Button { copy(entry.text, entry) } label: {
                Image(systemName: copied == entry.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
            Button {
                let on = !stars.contains(entry.id)
                if on { stars.insert(entry.id) } else { stars.remove(entry.id) }
                Stars.set(entry.id, on)
            } label: {
                Image(systemName: stars.contains(entry.id) ? "star.fill" : "star")
                    .foregroundStyle(stars.contains(entry.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(stars.contains(entry.id) ? "Unstar" : "Star")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Insert Again") { Task { await LastApp.insert(entry.text) } }
            if let heard = entry.heard, heard != entry.text {
                Button("Copy as Heard") { copy(heard, entry) }
                Button("Insert as Heard") { Task { await LastApp.insert(heard) } }
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

/// Starred dictations, kept out of the log so it stays append-only and older Jots read it as before:
/// `stars/<host>.jsonl` beside `dictations/`, a line per star or unstar. The latest line for a
/// dictation wins, across every Mac's file.
enum Stars {
    struct Mark: Codable {
        let at: Date
        let id: String
        let on: Bool
    }

    static var folder: URL { DictationLog.folder.deletingLastPathComponent().appending(path: "stars") }

    static func load() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let marks = files.filter { $0.pathExtension == "jsonl" }
            .flatMap { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").split(separator: "\n") }
            .compactMap { try? JSONDecoder().decode(Mark.self, from: Data($0.utf8)) }
        return Self.starred(marks)
    }

    /// The ids whose latest mark is a star.
    static func starred(_ marks: [Mark]) -> Set<String> {
        var latest: [String: Mark] = [:]
        for mark in marks where (latest[mark.id]?.at ?? .distantPast) <= mark.at { latest[mark.id] = mark }
        return Set(latest.values.filter(\.on).map(\.id))
    }

    static func set(_ id: String, _ on: Bool) {
        guard var line = try? JSONEncoder().encode(Mark(at: .now, id: id, on: on)) else { return }
        line.append(0x0A)
        DictationLog.add(line, to: folder.appending(path: "\(DictationLog.host).jsonl"))
    }
}

/// The app you were in before Jot's window: where Insert Again types.
@MainActor
enum LastApp {
    private(set) static var app: NSRunningApplication?

    static func track() {
        app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            guard let active = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  active != .current else { return }
            MainActor.assumeIsolated { app = active }
        }
    }

    /// Types it into that app's focused field the way a dictation does (checked it landed, else
    /// it stays on the clipboard and Jot says so).
    static func insert(_ text: String) async {
        guard let app, !app.isTerminated else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Dictation.shared.error = "No app to insert into. It's on the clipboard."
            return
        }
        app.activate()
        for _ in 0..<50 where NSWorkspace.shared.frontmostApplication != app { // up to a second
            try? await Task.sleep(for: .milliseconds(20))
        }
        if await Paste.insert(text, into: app) == nil, Dictation.shared.error == nil {
            Dictation.shared.error = "No text field in \(app.localizedName ?? "that app"). It's on the clipboard."
        }
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
