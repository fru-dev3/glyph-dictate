import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

/// Jot on the Mac: a window (Home, Dictionary, Snippets, Styles, Settings), a Dock icon and a menu bar icon. Hold the talk key
/// (Fn) to dictate into any app; double-press it to talk hands-free until the next press.
/// On-device, no cloud.
@main
struct JotMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Jot", id: "main") { MainView() }
            .defaultSize(width: 900, height: 640)
        MenuBarExtra("Jot", systemImage: "mic") { JotMenu() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var key: FnKey?
    private var retry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in if granted { Dictation.shared.keepMicReady(Prefs.shared.keepMicReady) } }
        }
        Dictation.shared.recoverDraft()
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() } // to paste (Accessibility)
        _ = Words.shared // your dictionary joins the speech model's vocabulary
        Task { await Transcription.prewarm() } // download the speech model before the first dictation
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
/// (System Settings > Keyboard > "Press 🌐 key to"). Jot owns Fn, so it sets that.
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

/// "0.7 (12)", from the app's Info.plist.
enum Version {
    static var text: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

private struct JotMenu: View {
    private let dictation = Dictation.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("section") private var section: MainView.Section = .home

    var body: some View {
        Text("Jot \(Version.text). Hold \(Prefs.shared.talkKey.name) to talk, double-press for hands-free")
        if let error = dictation.error { Text(error) }
        if !Permissions.allGranted {
            Button("Finish Setup…") { open(.settings) }
        }

        Divider()
        Button("Paste Last Dictation") { dictation.pasteLast() }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(dictation.recent.isEmpty)
        Button("Undo Last Dictation") { dictation.undoLast() }
            .keyboardShortcut("z", modifiers: [.control, .command])
            .disabled(dictation.recent.isEmpty)
        Button("Use What I Said") { dictation.useWhatISaid() }
            .keyboardShortcut("r", modifiers: [.control, .command])
            .disabled(dictation.recent.isEmpty)
        if !dictation.recent.isEmpty {
            Menu("Recent") {
                ForEach(dictation.recent, id: \.self) { text in
                    Button(String(text.prefix(60))) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
        Button("Open Jot") { open(.home) }
        Button("History…") { open(.home) }
        Button("Settings…") { open(.settings) }.keyboardShortcut(",")
        Divider()
        Button("Quit Jot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(_ to: MainView.Section) {
        section = to
        openWindow(id: "main")
        NSApp.activate()
    }
}
