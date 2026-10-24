@preconcurrency import AVFoundation
import AppKit
import Carbon.HIToolbox
import os
import Speech

let log = Logger(subsystem: "dev.fru.jot.mac", category: "dictation")

/// One dictation: the talk key down starts the mic, words stream through Apple's on-device
/// model while you talk, the key up finishes. Then, by mode: type it where you are, save it
/// to the vault as a thought, or run it as a command on the selected text. Nothing leaves the
/// Mac. Every dictation is also appended to the vault log (`DictationLog`).
@Observable @MainActor
final class Dictation {
    enum State { case idle, listening, finishing, done }

    static let shared = Dictation()

    private(set) var state = State.idle
    private(set) var locked = false
    private(set) var mode = Mode.dictate
    private(set) var levels = Array(repeating: Float(0), count: 9)
    private(set) var recent: [String] = []
    /// Live while you talk: words so far, for the pill.
    private(set) var words = 0
    private(set) var startedAt = Date()
    /// The last one went to the clipboard, not a text field (none had focus).
    private(set) var copiedOnly = false
    /// A short word on the pill when it's done ("3 fields", "Return").
    private(set) var note: String?
    /// Speech is turning your voice into words. Until it is, the pill shows no time or words:
    /// a running timer always means you're being heard.
    private(set) var hearing = false
    /// Speech stalled or didn't start, and is being started again on the sound so far.
    private(set) var reconnecting = false
    /// The dictation didn't work; the pill says so in place of the tick.
    private(set) var problem: String?
    var error: String?

    private let mic = Mic()
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var relay: Relay?
    private var pipeline: Task<String, Error>?
    // The stall check: voice heard (seconds) since the last new word, and when that was.
    private var voiced = 0.0
    private var wordsAt = Date()
    private var lastLevel = Date()
    private var target: NSRunningApplication?
    private var live: LiveCleaner?
    /// The words heard so far in this dictation, kept for the safety net.
    private var soFar = ""
    private var draftAt = Date.distantPast
    /// The last dictation as heard, before polishing, for "Use What I Said".
    private var lastHeard = ""

    func keepMicReady(_ on: Bool) { mic.keepReady(on) }

    func handle(_ action: FnGesture.Action, locked: Bool, mode: Mode) {
        if state == .listening { self.mode = mode; self.locked = locked }
        switch action {
        case .start: start(mode)
        case .stop: finish(keep: true)
        case .cancel: finish(keep: false)
        case .none: break
        }
    }

    private func start(_ mode: Mode) {
        guard state == .idle || state == .done else { return }
        error = nil
        note = nil
        problem = nil
        hearing = false
        reconnecting = false
        Learner.stop()
        target = NSWorkspace.shared.frontmostApplication
        let (audio, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.feed = feed
        self.mode = mode
        locked = false
        startedAt = .now
        live = mode == .dictate || mode == .thought ? LiveCleaner() : nil
        words = 0
        soFar = ""
        draftAt = .now
        copiedOnly = false
        state = .listening
        Prefs.shared.play("Tink")
        Pill.shared.show(over: target)
        let mic = mic
        let relay = Relay()
        self.relay = relay
        let pipeline = Task {
            guard let format = await mic.start(feed, level: { db in Task { @MainActor in Dictation.shared.push(db) } }) else {
                throw JotError("The microphone didn't start.")
            }
            Task { for await buffer in audio { relay.add(buffer) }; relay.end() }
            return try await Self.listen(relay, mic: format, ready: {
                Task { @MainActor in Dictation.shared.speechReady() }
            }, words: { count, finished in
                Task { @MainActor in Dictation.shared.heard(count, finished) }
            })
        }
        self.pipeline = pipeline
        // Speech that fails while you talk is said at once, not when you let go.
        Task {
            guard case .failure(let failure) = await pipeline.result, state == .listening, self.pipeline == pipeline else { return }
            log.error("listen: failed while talking: \(failure.localizedDescription, privacy: .public)")
            if let feed = self.feed { self.mic.stop(feed) }
            self.feed = nil
            let speech = failure is SpeechDown
            rescue(failure.localizedDescription)
            problem = speech ? "Speech stopped. Restarting Jot"
                : failure as? JotError == .notReady ? "Speech model downloading. Try soon"
                : "The mic didn't start"
            pipeline.cancel()
            state = .done
            Task {
                try? await Task.sleep(for: .seconds(3))
                if state == .done { reset() }
                if speech { Relaunch.now() }
            }
        }
    }

    private func speechReady() {
        guard state == .listening else { return }
        if !hearing && !reconnecting { startedAt = .now } // the timer starts when you're heard
        hearing = true
        reconnecting = false
        voiced = 0
        wordsAt = .now
    }

    /// Voice keeps coming but no words do: speech has stalled. Start it again on everything so far.
    private func stalled() {
        guard hearing, let relay else { return }
        log.error("listen: \(Int(self.voiced)) s of voice and no new words, restarting speech")
        hearing = false
        reconnecting = true
        live = mode == .dictate || mode == .thought ? LiveCleaner() : nil
        relay.stall()
    }

    /// More words while you talk: the pill's count, the live cleanup, and every 10 seconds a
    /// draft in the vault, so a crash mid-ramble loses at most the last few seconds.
    private func heard(_ count: Int, _ finished: String) {
        guard state == .listening || state == .finishing else { return }
        if count != words { wordsAt = .now; voiced = 0 }
        words = count
        live?.heard(finished)
        soFar = finished
        if Date.now.timeIntervalSince(draftAt) >= 10 {
            draftAt = .now
            Draft.save(finished)
        }
    }

    private func finish(keep: Bool) {
        guard state == .listening, let pipeline else { return }
        state = .finishing
        if let feed { mic.stop(feed) }
        feed = nil
        let seconds = Date.now.timeIntervalSince(startedAt)
        let released = Date.now
        let mode = mode, target = target, live = live
        // Never spin forever: if speech or cleanup hangs, give up on this one and say so.
        Task {
            try? await Task.sleep(for: .seconds(10))
            if state == .finishing, self.pipeline == pipeline {
                log.error("finish: stuck, giving up")
                pipeline.cancel()
                rescue("That one got stuck.")
                reset()
            }
        }
        Task {
            guard keep else { pipeline.cancel(); Draft.clear(); reset(); return }
            do {
                log.info("finish: waiting for speech")
                let heard = try await pipeline.value
                log.info("finish: heard \(heard.count) chars")
                guard !heard.isEmpty else { Draft.clear(); reset(); return }
                let text: String
                switch mode {
                case .dictate:
                    if let request = Rules.formRequest(heard) {
                        text = request
                        let filled = try await FormFill.run(request, app: target)
                        note = filled == 1 ? "1 field" : "\(filled) fields"
                    } else {
                        let code = Category(target) == .code
                        let polished = await Polish.text(heard, app: target, live: live)
                        let (body, enter) = Rules.splitEnter(polished, code: code)
                        text = body
                        let field = await Paste.insert(text, into: target)
                        copiedOnly = field == nil
                        if enter, field != nil {
                            try? await Task.sleep(for: .milliseconds(150))
                            Paste.press(kVK_Return, [])
                            note = "Return"
                        }
                        if let field { Learner.watch(field, pasted: text) }
                    }
                case .thought:
                    text = await Polish.text(heard, app: nil, live: live)
                    try Thoughts.save(text)
                case .command:
                    let saved = Clipboard.save()
                    let selection = await Paste.copySelection()
                    text = try await AI.command(heard, selection: selection)
                    await Paste.insert(text, into: target, restoring: saved)
                case .ask:
                    text = heard
                    Task { await Ask.shared.run(heard) }
                }
                log.info("finish: done")
                Draft.clear()
                if mode != .ask { remember(text, heard: heard) }
                DictationLog.append(text: text, heard: heard, mode: "\(mode)", app: target, seconds: seconds,
                                    finishMs: Int(Date.now.timeIntervalSince(released) * 1000))
                Prefs.shared.play(mode == .thought ? "Glass" : "Pop")
                done()
            } catch {
                rescue(error.localizedDescription)
                reset()
                if error is SpeechDown { Relaunch.now() }
            }
        }
    }

    /// Something went wrong after you talked: what was heard so far isn't lost. It goes to the
    /// clipboard and the log, and the draft is cleared.
    private func rescue(_ message: String) {
        let words = soFar.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty {
            fail(message)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(words, forType: .string)
            DictationLog.append(text: words, heard: words, mode: "recovered", app: target, seconds: 0, finishMs: 0)
            fail(message + " What you said is on the clipboard.")
        }
        Draft.clear()
    }

    /// The pill shows a tick for a moment, so a saved thought (which types nothing) is seen to land.
    private func done() {
        state = .done
        Task {
            try? await Task.sleep(for: .milliseconds(copiedOnly || note != nil ? 2000 : 700))
            if state == .done { reset() }
        }
    }

    private func reset() {
        pipeline = nil
        relay = nil
        live = nil
        hearing = false
        reconnecting = false
        state = .idle
        locked = false
        levels = levels.map { _ in 0 }
        Pill.shared.hide()
    }

    private func fail(_ message: String) {
        error = message
        Prefs.shared.play("Basso")
    }

    private func remember(_ text: String, heard: String) {
        recent.insert(text, at: 0)
        recent = Array(recent.prefix(5))
        lastHeard = heard
    }

    private func push(_ db: Float) {
        let now = Date.now
        if state == .listening, hearing, !reconnecting {
            if db > -38 { voiced += min(now.timeIntervalSince(lastLevel), 0.2) }
            if voiced > 3, now.timeIntervalSince(wordsAt) > 5 { stalled() }
        }
        lastLevel = now
        levels.removeFirst()
        levels.append(min(1, max(0, (db + 55) / 45))) // -55 dB...-10 dB -> 0...1
    }

    func pasteLast() {
        if let text = recent.first { Task { await Paste.insert(text, into: NSWorkspace.shared.frontmostApplication) } }
    }

    /// Takes the last dictation back out (Cmd-Z in the app it went to).
    func undoLast() {
        Paste.press(kVK_ANSI_Z, .maskCommand)
    }

    /// Swaps the last dictation for exactly what you said, before any cleanup.
    func useWhatISaid() {
        guard !lastHeard.isEmpty else { return }
        Paste.press(kVK_ANSI_Z, .maskCommand)
        let heard = lastHeard
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await Paste.insert(heard, into: NSWorkspace.shared.frontmostApplication)
        }
    }

    /// A dictation cut off by a crash or a quit is in the draft: put it in the log and on the
    /// clipboard at the next launch.
    func recoverDraft() {
        guard let words = Draft.take() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
        DictationLog.append(text: words, heard: words, mode: "recovered", app: nil, seconds: 0, finishMs: 0)
        error = "Recovered a dictation cut off last time. It's in History and on the clipboard."
    }

    /// Speech on the dictation's sound, started again (up to three times, on all the sound so far)
    /// when it fails or stalls. Apple's speech service now and then stops answering a running app.
    nonisolated private static func listen(_ relay: Relay, mic: AVAudioFormat, ready: @escaping @Sendable () -> Void,
                                           words: @escaping @Sendable (Int, String) -> Void) async throws -> String {
        for attempt in 1...3 {
            if attempt > 1 {
                Transcription.forget()
                try await Task.sleep(for: .milliseconds(300 * attempt))
            }
            let audio = relay.stream()
            let job = Task { try await transcribe(audio, mic: mic, ready: ready, words: words) }
            relay.onStall { job.cancel() }
            do {
                return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            } catch {
                try Task.checkCancellation() // let go with Esc, or stopped: not a failure
                log.error("speech: attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                // The model is downloading: speech isn't down, and a restart or relaunch won't help.
                if error as? JotError == .notReady { throw error }
                if error as? JotError == .serviceLost { throw SpeechDown() } // only a relaunch helps
            }
        }
        throw SpeechDown()
    }

    /// Same path as Jot on the phone (`Recorder.transcribeLive`), minus the audio file:
    /// a dictation keeps only its words.
    nonisolated private static func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, mic: AVAudioFormat,
                                               ready: @Sendable () -> Void,
                                               words: @escaping @Sendable (Int, String) -> Void) async throws -> String {
        log.info("speech: making model")
        #if DEBUG
        if Breakage.take(Breakage.fail) { throw JotError("Test: speech didn't start.") }
        if Breakage.take(Breakage.model) { throw JotError.notReady }
        let mute = Breakage.take(Breakage.mute)
        #endif
        // Apple's speech service has now and then never answered here; don't wait forever.
        let m = try await within(4, "Speech didn't start.") { try await Transcription.make(live: true) }
        log.info("speech: model ready")
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m.module], considering: mic),
              let converter = AVAudioConverter(from: mic, to: format) else {
            throw JotError("Speech recognition can't read this microphone's audio.")
        }
        converter.primeMethod = .none
        let analyzer = SpeechAnalyzer(modules: [m.module])
        try await analyzer.setContext(Transcription.context)
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task {
            var builder = TranscriptBuilder()
            for try await piece in m.pieces {
                if piece.isFinal { builder.add(piece) }
                words(Self.count(builder.text) + (piece.isFinal ? 0 : Self.count(piece.text)), builder.text)
            }
            return builder.text
        }
        try await analyzer.start(inputSequence: input)
        ready()
        var fed = 0
        for await buffer in audio {
            #if DEBUG // silence on a copy: the kept sound must stay whole for the replay
            var buffer = buffer
            if mute, let quiet = copy(buffer), let d = quiet.floatChannelData {
                for c in 0..<Int(quiet.format.channelCount) { memset(d[c], 0, Int(quiet.frameLength) * 4) }
                buffer = quiet
            }
            #endif
            if let out = convert(buffer, converter, format) { feed.yield(AnalyzerInput(buffer: out)); fed += 1 }
        }
        feed.finish()
        if Task.isCancelled { // stalled: this one is dropped and a new one hears it all again
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw CancellationError()
        }
        // With no audio at all (let go before the mic was up) the analyzer never answers.
        guard fed > 0 else {
            log.info("speech: no audio")
            await analyzer.cancelAndFinishNow()
            results.cancel()
            return ""
        }
        log.info("speech: audio ended, finalizing")
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        log.info("speech: finalized")
        return try await results.value
    }

    /// The work's result, or `message` as an error if it takes longer than `seconds`.
    nonisolated private static func within<T: Sendable>(_ seconds: Double, _ message: String,
                                                         _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let answered = OSAllocatedUnfairLock(initialState: false)
        let first = { answered.withLock { done in defer { done = true }; return !done } }
        return try await withCheckedThrowingContinuation { result in
            let job = Task {
                do { let value = try await work(); if first() { result.resume(returning: value) } }
                catch { if first() { result.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if first() { job.cancel(); log.error("speech: no answer in \(seconds) s"); result.resume(throwing: JotError(message)) }
            }
        }
    }

    nonisolated private static func count(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        return 20 * log10(max((sum / Float(buffer.frameLength)).squareRoot(), 1e-6))
    }

    /// The engine reuses tap buffers, so anything held past the callback is copied.
    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let from = s.mData, let to = d.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter,
                                            _ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}

#if DEBUG
/// Test switches (scripts drive them through the check hook): break speech on purpose.
enum Breakage {
    static let fail = OSAllocatedUnfairLock(initialState: 0)
    static let mute = OSAllocatedUnfairLock(initialState: 0)
    static let model = OSAllocatedUnfairLock(initialState: 0)
    static let lost = OSAllocatedUnfairLock(initialState: 0)
    static func take(_ counter: OSAllocatedUnfairLock<Int>) -> Bool {
        counter.withLock { n in defer { n = max(0, n - 1) }; return n > 0 }
    }
}
#endif

/// Speech stopped answering, three times over. Relaunching Jot has always brought it back.
struct SpeechDown: LocalizedError {
    var errorDescription: String? { "Speech stopped answering, so Jot is restarting. Talk again in a moment." }
}

/// The dictation's sound, kept in memory while you talk and dropped when it's done (never
/// written anywhere), so speech that stalls can start again and hear all of it.
final class Relay: @unchecked Sendable {
    private struct State {
        var buffers: [AVAudioPCMBuffer] = []
        var frames: AVAudioFrameCount = 0
        var out: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var ended = false
        var stall: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func add(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { s in
            s.buffers.append(buffer)
            s.frames += buffer.frameLength
            // ponytail: keeps the last 10 minutes; a stall later than that replays only those.
            let keep = AVAudioFrameCount(buffer.format.sampleRate * 600)
            while s.frames > keep, let first = s.buffers.first {
                s.buffers.removeFirst()
                s.frames -= first.frameLength
            }
            s.out?.yield(buffer)
        }
    }

    func end() { state.withLockUnchecked { $0.ended = true; $0.out?.finish() } }

    /// All the sound so far, then the rest as it comes. Ends the stream handed out before.
    func stream() -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, out) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        state.withLockUnchecked { s in
            s.out?.finish()
            for buffer in s.buffers { out.yield(buffer) }
            if s.ended { out.finish() }
            s.out = out
        }
        return stream
    }

    func onStall(_ action: @escaping @Sendable () -> Void) { state.withLockUnchecked { $0.stall = action } }
    func stall() { state.withLockUnchecked { $0.stall }?() }
}

/// Opens a fresh Jot and quits this one: what brings Apple's speech service back when it stops
/// answering a running app. At most once in 10 minutes, so it can never loop.
enum Relaunch {
    /// At most once in 10 minutes, so a speech service that stays down can't put Jot in a loop.
    @MainActor static func now() {
        let last = UserDefaults.standard.double(forKey: "relaunchedAt")
        guard Date.now.timeIntervalSince1970 - last > 600 else { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "relaunchedAt")
        log.error("relaunch: speech stopped answering")
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Every two minutes and after the Mac wakes, while you aren't dictating: is speech still
/// reachable? macOS's speech service now and then drops a running app, and the next dictation
/// would fail; reconnecting (a relaunch) while idle means it never does.
@MainActor
enum SpeechWatch {
    private static var timer: Timer?

    static func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in Task { await check() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { try? await Task.sleep(for: .seconds(5)); await check() }
        }
    }

    static func check() async {
        var lost = false
        #if DEBUG
        lost = Breakage.take(Breakage.lost)
        #endif
        if !lost { lost = !(await Transcription.reachable()) }
        guard lost, Dictation.shared.state == .idle else { return }
        log.error("watch: speech unreachable between dictations, reconnecting")
        Relaunch.now()
    }
}

/// The microphone, run on its own queue: starting it can take seconds (another app holding the
/// device, a USB mic waking up), and the talk key must stay live meanwhile. Kept ready (the
/// default), it runs between dictations and holds the last moment of sound in memory, so the
/// key starts at once and a word said as the key goes down is still heard. Nothing is kept
/// past that moment, and nothing is written anywhere.
final class Mic: @unchecked Sendable {
    static let preRoll = 0.8 // seconds of sound from just before the key went down

    private struct Live {
        var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var level: (@Sendable (Float) -> Void)?
        var ring: [AVAudioPCMBuffer] = []
        var ringFrames: AVAudioFrameCount = 0
    }

    private let queue = DispatchQueue(label: "dev.fru.jot.mic")
    private var engine: AVAudioEngine? // `engine`, `format` and `ready` only on `queue`
    private var format: AVAudioFormat?
    private var ready = false
    private let live = OSAllocatedUnfairLock(uncheckedState: Live()) // shared with the audio thread

    init() {
        // A new mic plugged in, AirPods connecting, or the Mac waking: the engine stops itself.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart() }
        }
    }

    /// Keep the mic running between dictations (or not).
    func keepReady(_ on: Bool) {
        queue.async {
            self.ready = on
            if on { _ = self.running() } else if self.live.withLockUnchecked({ $0.feed == nil }) { self.teardown() }
        }
    }

    /// The mic's format once it's on, or nil if it didn't start. The sound from just before
    /// (when kept ready) goes first.
    func start(_ feed: AsyncStream<AVAudioPCMBuffer>.Continuation,
               level: @escaping @Sendable (Float) -> Void) async -> AVAudioFormat? {
        await withCheckedContinuation { done in
            queue.async {
                let begun = Date.now
                guard let format = self.running() else { done.resume(returning: nil); return }
                let earlier = self.live.withLockUnchecked { s -> Int in
                    for buffer in s.ring { feed.yield(buffer) }
                    defer { s.ring = []; s.ringFrames = 0 }
                    s.feed = feed
                    s.level = level
                    return s.ring.count
                }
                log.info("mic: on in \(Int(Date.now.timeIntervalSince(begun) * 1000)) ms, \(earlier) buffers from before")
                done.resume(returning: format)
            }
        }
    }

    /// Queued after `start`, so it also works when you let go before the mic was up.
    func stop(_ feed: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        queue.async {
            self.live.withLockUnchecked { $0.feed = nil; $0.level = nil }
            feed.finish()
            if !self.ready { self.teardown() }
        }
    }

    /// On `queue`: the running engine's format, starting it if needed.
    private func running() -> AVAudioFormat? {
        if let engine, engine.isRunning, let format { return format }
        teardown()
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return nil }
        let keep = AVAudioFrameCount(format.sampleRate * Self.preRoll)
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [live] buffer, _ in
            guard let copy = Dictation.copy(buffer) else { return }
            let (feed, level) = live.withLockUnchecked { s in
                if s.feed == nil {
                    s.ring.append(copy)
                    s.ringFrames += copy.frameLength
                    while let first = s.ring.first, s.ringFrames - first.frameLength >= keep {
                        s.ring.removeFirst()
                        s.ringFrames -= first.frameLength
                    }
                }
                return (s.feed, s.level)
            }
            feed?.yield(copy)
            level?(Dictation.decibels(buffer))
        }
        do { try engine.start() } catch { engine.inputNode.removeTap(onBus: 0); return nil }
        self.engine = engine
        self.format = format
        return format
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        format = nil
        live.withLockUnchecked { $0.ring = []; $0.ringFrames = 0 }
    }

    private func restart() {
        let talking = live.withLockUnchecked { $0.feed != nil }
        guard ready || talking else { return }
        teardown()
        let format = running()
        log.info("mic: restarted after a device change, \(format == nil ? "off" : "on", privacy: .public)")
    }
}

/// The clipboard as it was, every type of every item, so it can be put back after Jot borrows it.
enum Clipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static func save() -> Snapshot {
        NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
    }

    static func restore(_ saved: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(saved.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        })
    }
}

/// Puts text into the focused field: clipboard + Cmd-V, then the old clipboard back.
/// Works in native apps, browsers, Electron and terminals alike. Needs Accessibility.
enum Paste {
    /// Pastes where you are, then checks it landed: the field's text must have changed. When it
    /// didn't (no text field, or one that only looks like it, as Finder's window does), the
    /// words stay on the clipboard to paste yourself and this returns nil. Only a paste that
    /// landed gets your old clipboard back.
    @MainActor @discardableResult
    static func insert(_ text: String, into app: NSRunningApplication?, restoring saved: Clipboard.Snapshot? = nil) async -> AXUIElement? {
        let pb = NSPasteboard.general
        // A password field has secure input on: never type a dictation into it.
        guard !IsSecureEventInputEnabled() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            Dictation.shared.error = "Not pasted into a password field. It's on the clipboard."
            return nil
        }
        let el = focusedElement(in: app)
        let before = el.flatMap(value)
        let saved = saved ?? Clipboard.save()
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        if let app, app != NSWorkspace.shared.frontmostApplication { app.activate() }
        press(kVK_ANSI_V, .maskCommand)
        // Give the app time to take the paste, then look.
        try? await Task.sleep(for: .milliseconds(350))
        guard let el else {
            log.info("paste: no focused element, left on the clipboard")
            return nil
        }
        let role = string(el, kAXRoleAttribute) ?? "?"
        let after = value(el)
        let landed = before != nil && after != nil ? before != after : textRoles.contains(role)
        log.info("paste: focused \(role, privacy: .public), landed \(landed)")
        guard landed else { return nil }
        // Put back what was there, unless something else has been copied meanwhile.
        try? await Task.sleep(for: .milliseconds(150))
        if pb.changeCount == ours { Clipboard.restore(saved) }
        return el
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attribute as CFString, &v)
        return v as? String
    }

    /// A field's text, to tell whether a paste went in.
    private static func value(_ el: AXUIElement) -> String? { string(el, kAXValueAttribute) }

    /// The front app's focused element, by Accessibility. Chrome and Electron apps only expose
    /// their fields once asked to (AXManualAccessibility).
    static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        guard let pid = (app ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// The selected text in the front app, by Cmd-C (works where reading it directly doesn't:
    /// browsers, Electron, terminals). Nil when nothing is selected.
    @MainActor
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        press(kVK_ANSI_C, .maskCommand)
        for _ in 0..<15 { // up to 300 ms
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before { return pb.string(forType: .string).flatMap { $0.isEmpty ? nil : String($0.prefix(6000)) } }
        }
        return nil
    }

    static func press(_ key: Int, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

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

    static func save(_ text: String) throws {
        let now = Date.now
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss" // the phone's memo names
        let stem = f.string(from: now)
        let date = stem.prefix(10) + "T" + stem.dropFirst(11).replacingOccurrences(of: "-", with: ":")
        let device = Host.current().localizedName ?? "Mac"
        let md = "---\ndate: \(date)\ntags: []\nkind: voice\ndevice: \(device)\nsource: jot\n---\n\n\(text)\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try md.write(to: folder.appending(path: stem + ".md"), atomically: true, encoding: .utf8)
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
        guard let path = UserDefaults.standard.string(forKey: "vaultPath") ?? LocalVault.path,
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
    static var host: String {
        ProcessInfo.processInfo.hostName.lowercased().replacingOccurrences(of: ".", with: "-")
    }

    /// `heard` is the transcript before polishing (or the spoken command), so a bad cleanup
    /// can always be undone from the log.
    static func append(text: String, heard: String, mode: String, app: NSRunningApplication?, seconds: Double, finishMs: Int) {
        let now = Date.now
        let entry: [String: Any] = [
            "at": now.ISO8601Format(),
            "text": text,
            "heard": heard,
            "mode": mode,
            "app": app?.localizedName ?? "",
            "bundle": app?.bundleIdentifier ?? "",
            "seconds": (seconds * 10).rounded() / 10,
            "finish_ms": finishMs,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let month = now.formatted(.iso8601.year().month())
        let file = folder.appending(path: "\(month).\(host).jsonl")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}
