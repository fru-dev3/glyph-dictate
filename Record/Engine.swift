import AppKit
import os

let jotLog = Logger(subsystem: "dev.fru.jot.mac", category: "app")

/// Glyph Jot's end of the link to its dictation engine (Mac/Link.swift): starts the helper
/// app in `Contents/Helpers`, talks to it over a private pipe, and starts it again whenever
/// it stops (a speech restart, a crash), at most a few times a minute. Recording, the library
/// and everything else in this process can fail without touching typing.
@MainActor @Observable
final class Engine {
    static let shared = Engine()

    /// The engine is up and answering.
    private(set) var running = false
    /// The last dictation problem it reported (shown on Dictations), nil when fine.
    private(set) var problem: String?
    /// The last few dictations, newest first (the menu bar's Recent).
    private(set) var recent: [String] = []
    /// It kept stopping; it waits for Start Again.
    private(set) var gaveUp = false

    /// What the engine says happened, for the recorder (jots) and the library (notes, questions).
    var onMessage: ((LinkMessage) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var starts: [Date] = []
    @ObservationIgnored private var quitting = false

    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/Glyph Jot Dictation.app")
    }

    /// Starts the engine, after any engine left running by an app that crashed has finished
    /// its dictation and quit (two would both hear the talk key).
    func start() {
        guard process == nil, !quitting else { return }
        gaveUp = false
        Task {
            await Self.retireOrphans()
            launch()
        }
    }

    func send(_ message: LinkMessage) {
        guard let input else { return }
        do { try input.write(contentsOf: Data(message.line.utf8)) } catch { jotLog.error("engine: write failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Quitting Glyph Jot quits dictation too, after the dictation in progress lands.
    func stop() {
        quitting = true
        send(.init(.quit))
        let p = process
        for _ in 0..<100 where p?.isRunning == true { Thread.sleep(forTimeInterval: 0.05) }
        if p?.isRunning == true { p?.terminate() }
    }

    private func launch() {
        let exe = Self.helperURL.appending(path: "Contents/MacOS/Glyph Jot Dictation")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            jotLog.error("engine: missing at \(exe.path, privacy: .public)")
            problem = "Dictation is missing from this copy of Glyph Jot. Download it again."
            return
        }
        let p = Process()
        p.executableURL = exe
        if CommandLine.arguments.contains("-quietEngine") { p.arguments = ["-quietEngine"] }
        let toEngine = Pipe(), fromEngine = Pipe()
        p.standardInput = toEngine
        p.standardOutput = fromEngine
        // ponytail: the handler runs on one serial queue, so the buffer needs no lock.
        nonisolated(unsafe) var buffer = LineBuffer()
        fromEngine.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let messages = buffer.feed(data).compactMap(LinkMessage.parse)
            if !messages.isEmpty { Task { @MainActor in for m in messages { Engine.shared.received(m) } } }
        }
        p.terminationHandler = { ended in
            let status = ended.terminationStatus
            Task { @MainActor in Engine.shared.ended(status) }
        }
        do {
            try p.run()
            process = p
            input = toEngine.fileHandleForWriting
            starts = starts.filter { $0 > .now.addingTimeInterval(-60) } + [.now]
            jotLog.notice("engine: started, pid \(p.processIdentifier)")
        } catch {
            jotLog.error("engine: failed to start: \(error.localizedDescription, privacy: .public)")
            problem = "Dictation didn't start: \(error.localizedDescription)"
        }
    }

    private func received(_ m: LinkMessage) {
        switch m.kind {
        case .ready:
            running = true
            // A recording that runs on keeps its jots private across an engine restart.
            if AppModel.shared.isRecording { send(.init(.recording, on: true)) }
        case .status:
            problem = m.text
            recent = m.recent ?? recent
        default: break
        }
        onMessage?(m)
    }

    private func ended(_ status: Int32) {
        running = false
        process = nil
        input = nil
        guard !quitting else { return }
        jotLog.notice("engine: stopped (\(status)), starting it again")
        if starts.filter({ $0 > .now.addingTimeInterval(-60) }).count >= 5 {
            gaveUp = true
            problem = "Dictation keeps stopping. Start it again from the menu bar, or quit and reopen Glyph Jot."
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            launch()
        }
    }

    /// An engine still running from an earlier Glyph Jot (it crashed): ask it to quit, give it
    /// time to finish a dictation, then make sure.
    private static func retireOrphans() async {
        // Only this copy's own engine: a Debug or test build must never stop the installed one
        // (it did, 2026-10-25, and took typing away mid-dictation).
        let mine = Bundle.main.bundleURL.standardizedFileURL.path + "/"
        let old = NSRunningApplication.runningApplications(withBundleIdentifier: JotIDs.engine)
            .filter { $0.bundleURL?.standardizedFileURL.path.hasPrefix(mine) == true }
        guard !old.isEmpty else { return }
        jotLog.notice("engine: retiring \(old.count) left from before")
        for app in old { app.terminate() }
        for _ in 0..<150 where old.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        for app in old where !app.isTerminated { app.forceTerminate() }
    }
}
