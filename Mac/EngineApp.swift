import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

/// The dictation engine of Glyph Jot: hold the talk key (Fn) to dictate into any app,
/// double-press it to talk hands-free, Fn+Shift for a note. A helper app inside Glyph Jot's
/// bundle with no Dock icon and no window: the main app starts it, shows its settings and
/// history, and restarts it if it ever stops (Link.swift). On-device, no cloud.
@main
enum EngineMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var key: FnKey?
    private var retry: Timer?

    /// Asked to quit mid-dictation (the app is taking over): finish it first, then go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Dictation.shared.state == .listening || Dictation.shared.state == .finishing else { return .terminateNow }
        Task {
            for _ in 0..<300 where Dictation.shared.state == .listening || Dictation.shared.state == .finishing {
                try? await Task.sleep(for: .milliseconds(200))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineLink.start()
        if EngineLink.quiet { log.notice("engine: quiet, for a test"); return }
        // What macOS allows this engine (asked through the app): the install script reads this line.
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        log.notice("engine: permissions keys=\(CGPreflightListenEventAccess(), privacy: .public) paste=\(CGPreflightPostEventAccess(), privacy: .public) mic=\(mic, privacy: .public)")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in if granted { Dictation.shared.keepMicReady(Prefs.shared.keepMicReady) } }
        }
        Dictation.shared.recoverDraft()
        LastApp.track()
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() } // to paste (Accessibility)
        _ = Words.shared // your dictionary joins the speech model's vocabulary
        Task { await Transcription.prewarm() } // download the speech model before the first dictation
        SpeechWatch.start()
        AI.prewarm()
        HotKeys.register([
            (kVK_ANSI_V, { Dictation.shared.pasteLast() }),
            (kVK_ANSI_Z, { Dictation.shared.undoLast() }),
            (kVK_ANSI_R, { Dictation.shared.useWhatISaid() }),
        ])
        if Prefs.shared.talkKey == .fn { FnSetting.doNothing() }
        let key = FnKey { action, mode in
            Task { @MainActor in Dictation.shared.handle(action, locked: self.key?.locked ?? false, mode: mode) }
        }
        self.key = key
        #if DEBUG // scripts/mac-check.sh drives Jot without a keyboard: "start[:mode]", "stop", "undo", "raw"
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.fru.jot.mac.check"), object: nil,
                                                            queue: .main) { note in
            let said = (note.object as? String ?? "").split(separator: ":").map(String.init)
            Task { @MainActor in
                switch said.first {
                case "undo": Dictation.shared.undoLast()
                case "raw": Dictation.shared.useWhatISaid()
                case "stop": Dictation.shared.handle(.stop, locked: false, mode: Dictation.shared.mode)
                // "fail:N": the next N speech starts fail; "mute:N": the next N hear silence (a stall).
                case "fail": Breakage.fail.withLock { $0 = Int(said.last ?? "") ?? 1 }
                case "mute": Breakage.mute.withLock { $0 = Int(said.last ?? "") ?? 1 }
                // "model:N": the next N speech starts find the model still downloading.
                case "model": Breakage.model.withLock { $0 = Int(said.last ?? "") ?? 1 }
                // "lost": the between-dictations check finds speech unreachable, now.
                case "lost": Breakage.lost.withLock { $0 = 1 }; await SpeechWatch.check()
                // "fullscreen:on|off": the front app's window in or out of full screen (the pill must show over it).
                case "fullscreen":
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { break }
                    var window: CFTypeRef?
                    if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
                       let window { AXUIElementSetAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, (said.last == "on") as CFBoolean) }
                default:
                    let mode: Mode = switch said.last {
                    case "thought": .thought
                    case "command": .command
                    case "ask": .ask
                    default: .dictate
                    }
                    Dictation.shared.handle(.start, locked: false, mode: mode)
                }
            }
        }
        #endif
        if !key.start() {
            CGRequestListenEventAccess() // Input Monitoring; the tap works once it's granted
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                Task { @MainActor in if self?.key?.start() == true { timer.invalidate() } }
            }
        }
    }

}

/// Pressing Fn twice opens the emoji picker unless the Globe key is set to Do Nothing
/// (System Settings > Keyboard > "Press Globe key to"). Jot owns Fn, so it sets that.
enum FnSetting {
    static func doNothing() {
        let domain = "com.apple.HIToolbox" as CFString
        guard CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int != 0 else { return }
        CFPreferencesSetAppValue("AppleFnUsageType" as CFString, 0 as CFNumber, domain)
        CFPreferencesAppSynchronize(domain)
        log.info("fn: set the Globe key to Do Nothing")
    }
}

/// Control-Command plus a letter, anywhere (Carbon hot keys: swallowed, so the front app doesn't
/// also see them). V pastes the last dictation again, Z takes it back out, R swaps it for
/// exactly what you said.
enum HotKeys {
    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]

    static func register(_ keys: [(Int, @MainActor () -> Void)]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            Task { @MainActor in HotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        for (n, (key, action)) in keys.enumerated() {
            let id = UInt32(n + 1)
            actions[id] = action
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(cmdKey | controlKey), EventHotKeyID(signature: 0x4A4F5421, id: id),
                                GetApplicationEventTarget(), 0, &ref)
        }
    }
}

