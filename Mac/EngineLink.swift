import AppKit

/// The engine's end of the link to Glyph Jot (Link.swift): reads what the app asks on stdin,
/// tells it what happens on stdout. When the app goes away without saying quit (it crashed),
/// typing keeps working and the engine opens the app again; the new app takes over from it.
@MainActor
enum EngineLink {
    /// A recording runs in the app: jots are reported so they stay out of its transcript.
    private(set) static var recording = false
    /// Started by the app (stdin is its pipe), not by hand.
    private(set) static var linked = false
    private static var quitting = false
    /// Tests: an engine that never listens or types (no talk key, no mic, no hot keys), so the
    /// crash and restart paths can be tried while someone works on the Mac.
    static let quiet = CommandLine.arguments.contains("-quietEngine")
    /// A jot is open (the talk key went down and the dictation hasn't ended).
    private static var jotOpen = false

    static func start() {
        var info = stat()
        linked = fstat(FileHandle.standardInput.fileDescriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
        guard linked else { log.notice("link: started by hand, no app to talk to"); return }
        let input = FileHandle.standardInput
        Thread.detachNewThread {
            var buffer = LineBuffer()
            while true {
                let data = input.availableData
                if data.isEmpty { break } // the app closed the pipe
                for line in buffer.feed(data) {
                    guard let message = LinkMessage.parse(line) else { continue }
                    Task { @MainActor in handle(message) }
                }
            }
            Task { @MainActor in appGone() }
        }
        // The pipe alone can't tell: the engine may hold a copy of its write end, so a dead app
        // never reads as end-of-file. Watch the app's process itself.
        let parent = getppid()
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        watch.setEventHandler { MainActor.assumeIsolated { appGone() } }
        watch.resume()
        parentWatch = watch
        if parent == 1 { appGone() } // already gone before the watch began
        send(.init(.ready))
        status()
    }
    private static var parentWatch: DispatchSourceProcess?

    static func send(_ message: LinkMessage) {
        guard linked else { return }
        FileHandle.standardOutput.write(Data(message.line.utf8))
    }

    /// The pill's state for the app: the last problem and the recent dictations.
    static func status() {
        send(.init(.status, text: Dictation.shared.error, recent: Dictation.shared.recent))
    }

    /// The talk key went down: during a recording this stretch is a private jot.
    static func jotStarted(_ mode: Mode) {
        jotOpen = true
        send(.init(.jot, mode: "\(mode)", on: true, at: Date.now.timeIntervalSince1970))
    }

    static func jotEnded() {
        guard jotOpen else { return }
        jotOpen = false
        send(.init(.jot, on: false, at: Date.now.timeIntervalSince1970))
    }

    private static func handle(_ message: LinkMessage) {
        switch message.kind {
        case .pasteLast: Dictation.shared.pasteLast()
        case .undo: Dictation.shared.undoLast()
        case .useWhatISaid: Dictation.shared.useWhatISaid()
        case .insert: if let text = message.text { Task { await LastApp.insert(text) } }
        case .prefs: Prefs.shared.reload()
        case .words: Words.shared.load()
        case .recording: recording = message.on ?? false
        case .quit: quitting = true; NSApp.terminate(nil)
        default: break
        }
    }

    /// The app is gone without a quit: keep typing, open the app again. The new app asks this
    /// engine to quit once it is idle and starts a fresh one.
    private static func appGone() {
        guard !quitting, linked else { return }
        linked = false
        log.error("link: the app went away, opening it again")
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true // this copy, never another Jot.app on the Mac
        if quiet { config.arguments = ["-quietEngine"]; config.hides = true }
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            guard let error else { return }
            log.error("link: reopening the app failed (\(error.localizedDescription, privacy: .public)), trying open")
            let task = Process()
            task.executableURL = URL(filePath: "/usr/bin/open")
            task.arguments = ["-g", "-j", "-n", app.path] + (quiet ? ["--args", "-quietEngine"] : [])
            try? task.run()
        }
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

