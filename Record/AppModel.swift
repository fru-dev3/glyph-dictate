import AppKit
import AVFoundation
import GlyphCore
import SwiftUI

/// What the sidebar shows: the three kinds of capture (and All of them), then the Glyph
/// Studio objects they are filed under (by Studio id), then plain #tags.
enum SidebarItem: Hashable {
    case all, notes, dictations, recordings
    case object(String), tag(String)

    var link: Link? {
        switch self {
        case .object(let id): .object(id)
        case .tag(let t): .tag(t)
        default: nil
        }
    }
}

/// A recording or a note: what a link is added to.
enum LinkTarget: Hashable {
    case recording(String), note(String)
}

enum DetailTab: String, CaseIterable, Identifiable {
    case summary, transcript
    var id: Self { self }
    var title: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        }
    }
}

/// What the background work is doing to a conversation.
enum Stage: Equatable {
    case transcribing(Double), downloadingModel(Double), summarizing, linking

    var symbol: String {
        switch self {
        case .transcribing, .downloadingModel: "waveform"
        case .summarizing: "sparkles"
        case .linking: "person.crop.circle.badge.questionmark"
        }
    }

    var help: String {
        switch self {
        case .transcribing(let p): "Transcribing \(Int(p * 100))%"
        case .downloadingModel(let p): "Downloading the speech model \(Int(p * 100))%"
        case .summarizing: "Writing the summary"
        case .linking: "Finding who it was with"
        }
    }
}

/// A calm message with the fix, shown inline.
struct Banner: Equatable, Identifiable {
    enum Fix: Equatable {
        case none, retry(String), settings(String), relaunch
    }
    let id = UUID()
    var message: String
    var fix: Fix = .none
    /// The conversation it is about, nil for the whole app.
    var conversation: String?
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var library: Library
    var vault: Vault { library.vault }
    /// Glyph Studio's people, products, projects and domains, from the notes vault.
    private(set) var studio = StudioDirectory()

    // Selection and layout
    var sidebar: SidebarItem? = .all { didSet { if oldValue != sidebar { syncSelection() } } }
    var selectedID: String?
    var tab: DetailTab = .summary
    var columns: NavigationSplitViewVisibility = .all
    var showList = true
    var listWidth: CGFloat = 300

    // Search
    var searchText = "" { didSet { scheduleSearch() } }
    private(set) var searchHits: Set<String>?
    var searchFocused = false
    var quickOpen = false

    // Work in the background, and what went wrong
    private(set) var stages: [String: Stage] = [:]
    var banners: [Banner] = []

    // Requests views answer (focus the title, open the add field)
    var renameRequest = 0
    var addLinkRequest: (id: Int, prefix: String) = (0, "")

    // Recording
    let recorder = Recorder()
    private(set) var recordingID: String?
    var includeSystemAudio: Bool {
        didSet { UserDefaults.standard.set(includeSystemAudio, forKey: "includeSystemAudio") }
    }
    var isRecording: Bool { recordingID != nil }
    @ObservationIgnored private lazy var panel = RecorderPanelController(model: self)
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init() {
        includeSystemAudio = UserDefaults.standard.bool(forKey: "includeSystemAudio")
        let root = AppModel.vaultRoot()
        let vault = Vault(root: root)
        try? vault.ensure()
        library = Library(vault: vault)
        library.start()
        Task { await reloadStudio(); await migrateToStudio() }
    }

    /// The Studio vault: the notes folder when it is one (`data/domains`).
    var studioRoot: URL? { DictationLog.vault }

    func reloadStudio() async {
        guard let root = studioRoot else { studio = StudioDirectory(); return }
        let read = await Task.detached(priority: .utility) { StudioDirectory(root: root) }.value
        if read != studio { studio = read }
    }

    /// An older library's People and Accounts become Studio ids, once (see Vault.migrateToStudio).
    /// Not when the Studio vault reads empty: a locked folder must not make every name again.
    func migrateToStudio() async {
        guard !AppModel.testHost, let root = studioRoot, !studio.objects(.domain).isEmpty else { return }
        let vault = vault, studio = studio
        let report = await Task.detached(priority: .utility) {
            try? vault.migrateToStudio(studio) { kind, name, notes in StudioCommand.create(kind, name, notes: notes, vault: root) }
        }.value
        guard let report, !report.isEmpty else { return }
        for r in report.rows { jotLog.notice("studio: \(r.name, privacy: .public) is \(r.id, privacy: .public)\(r.created ? " (new)" : "", privacy: .public)") }
        if !report.unresolved.isEmpty { jotLog.notice("studio: not moved yet: \(report.unresolved.joined(separator: ", "), privacy: .public)") }
        // A record to read later, beside the moved notes.
        let record: [String: Any] = [
            "at": Date.now.ISO8601Format(), "conversations": report.conversations, "notes_moved": report.notesMoved, "unresolved": report.unresolved,
            "rows": report.rows.map { ["name": $0.name, "id": $0.id, "created": $0.created] as [String: Any] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            let log = vault.root.appending(path: ".memosa/migrated-to-studio/log.jsonl")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close() }
        }
        await reloadStudio()
        library.reload()
    }

    // MARK: vault

    /// `-recordingsPath <folder>` (tests) or the chosen folder; else Memosa's vault if there,
    /// else ~/Documents/Glyph Vault. ("vaultPath" is the notes folder, Jot's older setting.)
    static func vaultRoot() -> URL {
        if let path = UserDefaults.standard.string(forKey: "recordingsPath"), !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        let docs = URL.documentsDirectory
        let memosa = docs.appending(path: "Memosa Vault", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: memosa.path) ? memosa : docs.appending(path: "Glyph Vault", directoryHint: .isDirectory)
    }

    /// `remember: false` (tests) leaves the saved choice alone: a test host shares the
    /// installed app's defaults, and once pointed Fru's recordings at a temp folder.
    func switchVault(to url: URL, remember: Bool = true) {
        if remember, !AppModel.testHost { UserDefaults.standard.set(url.path, forKey: "recordingsPath") }
        library.stop()
        let vault = Vault(root: url)
        try? vault.ensure()
        library = Library(vault: vault)
        library.start()
        sidebar = .recordings
        selectedID = nil
    }

    func meta(_ id: String?) -> Conversation? {
        guard let id else { return nil }
        return library.conversations.first { $0.id == id }
    }

    var selected: Conversation? { meta(selectedID) }

    // MARK: the list

    /// The conversations the list shows for the sidebar choice and the search.
    var listed: [Conversation] {
        let all = library.conversations
        var shown: [Conversation]
        switch sidebar ?? .all {
        case .all, .recordings: shown = all
        case .notes, .dictations: shown = []
        case .object(let id): shown = all.filter { $0.links.contains(id) }
        case .tag(let t): shown = all.filter { $0.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        }
        if let hits = searchHits { shown = shown.filter { hits.contains($0.id) } }
        return shown
    }

    /// The notes filed under a Studio object or carrying a tag.
    func notes(for item: SidebarItem) -> [JotNote] {
        switch item {
        case .object(let id): NoteStore.shared.notes.filter { $0.links.contains(id) }
        case .tag(let t): NoteStore.shared.notes.filter { $0.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        default: []
        }
    }

    /// How many recordings and notes each Studio object and tag has.
    var linkCounts: (objects: [String: Int], tags: [String: Int]) {
        var objects: [String: Int] = [:], tags: [String: Int] = [:]
        for c in library.conversations {
            for l in Set(c.links) { objects[l, default: 0] += 1 }
            for t in Set(c.tags) { tags[t, default: 0] += 1 }
        }
        for n in NoteStore.shared.notes {
            for l in Set(n.links) { objects[l, default: 0] += 1 }
            for t in Set(n.tags) { tags[t, default: 0] += 1 }
        }
        return (objects, tags)
    }

    /// Recordings and imports go into one folder; where they belong is a Studio link, not a folder.
    let targetFolder = "Recordings"

    private func syncSelection() {
        searchText = ""
        // Keep the open conversation when it is in the new list; else open the first.
        if let id = selectedID, listed.contains(where: { $0.id == id }) { return }
        selectedID = listed.first?.id
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let phrase = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { searchHits = nil; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let needle = phrase.lowercased()
            var hits = Set(library.conversations.filter { c in
                ([c.title] + c.links.map(studio.name) + c.tags).contains { $0.lowercased().contains(needle) }
            }.map(\.id))
            hits.formUnion(await library.search(phrase))
            guard !Task.isCancelled else { return }
            searchHits = hits
        }
    }

    // MARK: actions on a conversation

    func perform(_ work: () throws -> Void) {
        do { try work() } catch { show(error.localizedDescription) }
        library.reload()
    }

    func show(_ message: String, fix: Banner.Fix = .none, for id: String? = nil) {
        banners.removeAll { $0.conversation == id && $0.message == message }
        withAnimation(.snappy) { banners.append(Banner(message: message, fix: fix, conversation: id)) }
    }

    func dismiss(_ banner: Banner) {
        withAnimation(.snappy) { banners.removeAll { $0.id == banner.id } }
    }

    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != meta(id)?.title else { return }
        perform {
            let newID = try vault.rename(id, title: title)
            if selectedID == id { selectedID = newID }
        }
    }

    func trash(_ id: String) {
        let list = listed
        let next = list.firstIndex { $0.id == id }.flatMap { i in i + 1 < list.count ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil) }
        perform {
            try vault.trash(id)
            if selectedID == id { selectedID = next }
        }
    }

    func reveal(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([vault.url(id)])
    }

    func copyMarkdown(_ id: String) {
        guard let meta = meta(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Markdown.export(meta, notes: vault.notes(id), transcript: vault.transcript(id), studio: studio), forType: .string)
    }

    /// Opens a capture from All in its own section.
    func open(_ capture: Capture) {
        switch capture.kind {
        case .recording:
            sidebar = .recordings
            selectedID = capture.id
        case .note:
            openNote = capture.id
            sidebar = .notes
        case .dictation:
            sidebar = .dictations
        }
    }

    // MARK: links (Studio objects and #tags, on a recording or a note)

    /// Files a recording or a note under a Studio object or a tag. A new name (`.person`,
    /// `.account` for a product) is made in Studio first.
    func addLink(_ link: Link, to target: LinkTarget) {
        Task {
            guard let link = await resolve(link) else { return }
            let (links, tags) = current(target)
            switch link {
            case .tag(let t): save(target, links: links, tags: tags + [t])
            default: save(target, links: links + [link.name], tags: tags)
            }
        }
    }

    func removeLink(_ link: Link, from target: LinkTarget) {
        let (links, tags) = current(target)
        switch link {
        case .tag(let t): save(target, links: links, tags: tags.filter { $0.caseInsensitiveCompare(t) != .orderedSame })
        default: save(target, links: links.filter { $0 != link.name }, tags: tags)
        }
    }

    /// A yes or no to a guess on a recording; a yes to a new name makes it in Studio.
    func answer(_ link: Link, for id: String, accept: Bool) {
        Task {
            var resolved: String?
            if accept, case .person = link {
                guard let made = await resolve(link) else { return }
                resolved = made.name
            }
            perform { _ = try vault.answer(id, link, accept: accept, resolved: resolved) }
        }
    }

    /// A Studio id for a link: as it is, or made in Studio for a new name.
    private func resolve(_ link: Link) async -> Link? {
        guard let kind = link.studioKind, !link.isObject else { return link }
        if let found = studio.match(link.name, kind) { return .object(found.id) }
        guard let root = studioRoot, StudioCommand.url != nil else {
            show("New \(kind.label.lowercased()) are made in Glyph Studio, which isn't on this Mac. Pick one it already has.")
            return nil
        }
        let name = link.name
        guard let id = await Task.detached(operation: { StudioCommand.create(kind, name, vault: root) }).value else {
            show("Glyph Studio couldn't add \(name). Try again, or add it in Glyph Studio.")
            return nil
        }
        await reloadStudio()
        return .object(id)
    }

    private func current(_ target: LinkTarget) -> ([String], [String]) {
        switch target {
        case .recording(let id): meta(id).map { ($0.links, $0.tags) } ?? ([], [])
        case .note(let file): NoteStore.shared.notes.first { $0.file == file }.map { ($0.links, $0.tags) } ?? ([], [])
        }
    }

    private func save(_ target: LinkTarget, links: [String], tags: [String]) {
        switch target {
        case .recording(let id): perform { _ = try vault.setStudioLinks(id, links: links, tags: tags) }
        case .note(let file):
            do { try NoteStore.shared.setLinks(file, links: links, tags: tags) } catch { show(error.localizedDescription) }
        }
    }

    // MARK: recording

    func toggleRecording() {
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    @ObservationIgnored private var starting = false
    #if DEBUG
    /// Debug builds: record this file (played in real time) instead of the devices.
    @ObservationIgnored var debugFeed: URL?
    #endif

    func startRecording() async {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        #if DEBUG
        if let feed = debugFeed { await startFeed(feed); return }
        #endif
        // Ask first, so an unanswered prompt leaves no empty conversation behind.
        if Permissions.microphone != .granted, !(await Permissions.requestMicrophone()) {
            show(CaptureError.microphoneDenied.localizedDescription, fix: .settings("Privacy_Microphone"))
            return
        }
        let folder = targetFolder
        let title = "Recording " + Date.now.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let meta: Conversation
        do { meta = try vault.createConversation(in: folder, title: title) } catch {
            show(error.localizedDescription); return
        }
        var inputs: Set<Recorder.Input> = [.microphone]
        if includeSystemAudio { inputs.insert(.systemAudio) }
        let audio = vault.url(meta.id).appending(path: meta.audio)
        do {
            try await recorder.start(to: audio, capturing: inputs)
        } catch CaptureError.screenRecordingDenied {
            Permissions.requestScreenRecording()
            show(CaptureError.screenRecordingDenied.localizedDescription + " This one records the microphone only.",
                 fix: .settings("Privacy_ScreenCapture"))
            do { try await recorder.start(to: audio, capturing: [.microphone]) } catch {
                failStart(meta.id, error); return
            }
        } catch {
            failStart(meta.id, error); return
        }
        recordingID = meta.id
        recordingBegan()
        library.reload()
        panel.show()
    }

    #if DEBUG
    private func startFeed(_ file: URL) async {
        guard let meta = try? vault.createConversation(in: targetFolder, title: "Recording " + Date.now.formatted(.dateTime.month(.abbreviated).day().hour().minute())),
              let source = try? AVAudioFile(forReading: file) else { return }
        do {
            let feed = try recorder.start(to: vault.url(meta.id).appending(path: meta.audio), feeding: [.microphone])
            recordingID = meta.id
            recordingBegan()
            library.reload()
            panel.show()
            Task.detached {
                let format = source.processingFormat
                let chunk = AVAudioFrameCount(format.sampleRate / 10)
                while true {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                    if (try? source.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                        source.framePosition = 0   // loop until stopped
                        continue
                    }
                    feed.append(buffer, from: .microphone)
                    try? await Task.sleep(for: .milliseconds(100))
                    if await MainActor.run(body: { self.recordingID == nil }) { break }
                }
            }
        } catch { failStart(meta.id, error) }
    }
    #endif

    #if DEBUG
    /// Tests: a recording of silence into this conversation, with no device and no panel.
    func testBegin(_ id: String) throws {
        guard let meta = meta(id) ?? (try? vault.conversation(id)) else { return }
        try recorder.start(to: vault.url(id).appending(path: meta.audio), feeding: [.microphone])
        recordingID = id
        recordingBegan()
    }
    #endif

    private func failStart(_ id: String, _ error: Error) {
        try? vault.trash(id)   // the empty folder goes to the vault's trash, never deleted
        library.reload()
        let fix: Banner.Fix = (error as? CaptureError) == .microphoneDenied ? .settings("Privacy_Microphone") : .none
        show(error.localizedDescription, fix: fix)
    }

    func stopRecording() async {
        guard let id = recordingID else { return }
        panel.hide()
        closeJot()
        Engine.shared.send(.init(.recording, on: false))
        let jots = self.jots
        self.jots = []
        do {
            let recording = try await recorder.stop()
            recordingID = nil
            if var m = try? vault.conversation(id) {
                m.durationSec = Int(recording.duration.rounded())
                m.jots = jots
                try? vault.write(m)
            }
        } catch {
            recordingID = nil
            if var m = try? vault.conversation(id), !jots.isEmpty { m.jots = jots; try? vault.write(m) }
            show(error.localizedDescription, for: id)
        }
        library.reload()
        await library.settle()
        if !(listed.contains { $0.id == id }) { sidebar = .recordings }
        selectedID = id
        Task { await process(id) }
    }

    /// The live meta of the conversation being recorded (for the panel's chips).
    var recording: Conversation? { meta(recordingID) }

    // MARK: jotting while recording

    /// The jots of the recording running now (seconds on its clock); saved into meta.json at stop.
    private(set) var jots: [Jot] = []
    /// A note to open on Notes (from a recording's transcript).
    var openNote: String?
    /// A jot is open now: the talk key is down during the recording.
    private(set) var jotting: Jot?

    private func recordingBegan() {
        jots = []
        jotting = nil
        Engine.shared.send(.init(.recording, on: true))
    }

    /// What the dictation engine says: a jot started or ended, a note was saved, a question.
    func engineSaid(_ m: LinkMessage) {
        switch m.kind {
        case .jot:
            guard isRecording else { return }
            if m.on == true {
                closeJot()
                jotting = Jot(start: recorder.elapsed, end: recorder.elapsed, kind: m.mode ?? "dictate")
            } else {
                closeJot()
            }
        case .thought:
            NoteStore.shared.reload()
            // Fn+Shift during a recording: the note is linked to this moment, like a bookmark.
            guard isRecording, let note = m.text else { return }
            if jotting != nil { jotting?.note = note; jotting?.kind = "thought"; closeJot() }
            else if let i = jots.indices.last, jots[i].note == nil, recorder.elapsed - jots[i].end < 10 {
                jots[i].note = note
                jots[i].kind = "thought"
            } else {
                jots.append(Jot(start: recorder.elapsed, end: recorder.elapsed, kind: "thought", note: note))
            }
        case .ask:
            if let q = m.text { Task { await Ask.shared.run(q) } }
        case .show:
            MainWindow.show()
        default: break
        }
    }

    /// The recording a note was said in, and when: (conversation id, seconds into it).
    func recordingFor(note file: String) -> (String, Double)? {
        for c in library.conversations {
            if let j = c.jots.first(where: { $0.note == file }) { return (c.id, j.start) }
        }
        return nil
    }

    private func closeJot() {
        guard var j = jotting else { return }
        j.end = max(recorder.elapsed, j.start)
        jots.append(j)
        jotting = nil
    }

    // MARK: import

    func importAudio(_ urls: [URL]) {
        let exts: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "mp4", "mov"]
        let files = urls.filter { exts.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else {
            show("Glyph Jot can import audio files like .m4a, .mp3, .wav and .aiff.")
            return
        }
        Task {
            for file in files { await importOne(file) }
        }
    }

    private func importOne(_ file: URL) async {
        let title = file.deletingPathExtension().lastPathComponent
        let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        do {
            var meta = try vault.createConversation(in: targetFolder, title: title, created: created)
            let name = "audio." + file.pathExtension.lowercased()
            try FileManager.default.copyItem(at: file, to: vault.url(meta.id).appending(path: name))
            meta.audio = name
            meta.source = "import"
            if let seconds = try? await AVURLAsset(url: file).load(.duration).seconds, seconds.isFinite {
                meta.durationSec = Int(seconds.rounded())
            }
            try vault.write(meta)
            library.reload()
            await library.settle()
            selectedID = meta.id
            await process(meta.id)
        } catch {
            show(error.localizedDescription)
        }
    }

    // MARK: background work

    func stage(_ id: String) -> Stage? { stages[id] }

    /// Transcribe, summarize, suggest links. Each step reports as a status icon; a
    /// failure becomes a banner with the fix, and the later steps still run when they can.
    func process(_ id: String) async {
        guard stages[id] == nil, let meta = try? vault.conversation(id) else { return }
        let vault = vault
        banners.removeAll { $0.conversation == id }
        let audio = vault.url(id).appending(path: meta.audio)

        if FileManager.default.fileExists(atPath: audio.path) {
            stages[id] = .transcribing(0)
            do {
                let names = studio.objects(.person).flatMap { [$0.name] + $0.aliases }
                let transcript = try await Transcriber().transcribe(audio, names: names) { event in
                    Task { @MainActor in
                        guard self.stages[id] != nil else { return }
                        switch event {
                        case .downloadingModel(let p): self.stages[id] = .downloadingModel(p)
                        case .transcribing(let p): self.stages[id] = .transcribing(p)
                        }
                    }
                }
                // What you said while jotting went to another app or a note: never into the meeting.
                let jots = (try? vault.conversation(id))?.jots ?? []
                try vault.writeTranscript(transcript.excluding(jots), for: id)
            } catch {
                stages[id] = nil
                let fix: Banner.Fix = (error as? TranscriptionError) == .serviceLost ? .relaunch : .retry(id)
                show(error.localizedDescription, fix: fix, for: id)
                library.reload()
                return
            }
            library.reload()
        }
        await summarizeAndLink(id)
    }

    func summarizeAndLink(_ id: String) async {
        let vault = vault
        stages[id] = .summarizing
        do { _ = try await Summarizer().summarize(id, in: vault) } catch AIError.emptyTranscript {
            // Silence: nothing to summarize, and nothing to say about it.
        } catch {
            let fix: Banner.Fix = (error as? AIError) == .unavailable(.appleIntelligenceOff) ? .settings("AppleIntelligence") : .retry(id)
            show(error.localizedDescription, fix: fix, for: id)
        }
        library.reload()
        stages[id] = .linking
        await reloadStudio()
        let heard = (try? await LinkSuggester().hear(vault.transcript(id).plainText)) ?? Heard()
        _ = try? vault.suggest(id, heard: heard, studio: studio)
        stages[id] = nil
        library.reload()
    }

    /// For the settings pane: the speech model download.
    var modelDownload: Double?

    func downloadSpeechModel() async {
        modelDownload = 0
        do {
            try await Transcriber().prepare { event in
                if case .downloadingModel(let p) = event { Task { @MainActor in self.modelDownload = p } }
            }
        } catch {
            show(error.localizedDescription)
        }
        modelDownload = nil
    }

    // MARK: helpers

    /// Running as a unit test's host: never write the installed app's settings.
    static let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func parent(_ id: String) -> String {
        id.split(separator: "/").dropLast().joined(separator: "/")
    }

    static func openSettingsPane(_ anchor: String) {
        let url = switch anchor {
        case "AppleIntelligence": "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        default: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
