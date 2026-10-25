import AppKit
import GlyphCore
import SwiftUI

/// Glyph Jot on the Mac: hold Fn to jot (it types where you are; Fn+Shift saves a note),
/// click Record for a meeting or a long conversation, and keep it all in one library with
/// People, Accounts and tags. Formerly Glyph Dictate (Jot) and Glyph Record (Memosa).
/// The dictation engine runs as its own process inside the app (Engine.swift).
@main
struct GlyphJotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        // Scroll bars show only while scrolling, even when System Settings says Always
        // or a mouse is plugged in: this app's own setting, read before any scroller exists.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        Window("Glyph Jot", id: "library") {
            LibraryWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.presented) // the library opens with the app, whatever the last session left
        .windowToolbarStyle(.unified)
        .commands { RecordCommands(model: model) }

        Settings {
            JotSettings()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(recording: model.isRecording)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The library window can close while a recording runs; the menu bar keeps the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Recorder.migrateSettings()
            let model = AppModel.shared
            Engine.shared.onMessage = { model.engineSaid($0) }
            // The library opens with the app, unless it was started at login (then it waits in the menu bar).
            let atLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            if !atLogin {
                Task { @MainActor in
                    for _ in 0..<20 where JotWindow.opener == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    if JotWindow.window?.isVisible != true { JotWindow.open(activate: false) }
                }
            }
            let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if !testing, !CommandLine.arguments.contains("-noEngine") { Engine.shared.start() }
            #if DEBUG
            DebugHook.install(model)
            #endif
            // `kill`, a logout or a restart asks politely: quit the normal way (the recording
            // is closed, dictation stops), so the engine never mistakes it for a crash.
            signal(SIGTERM, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            term.setEventHandler { NSApp.terminate(nil) }
            term.resume()
            self.term = term
        }
    }
    private var term: DispatchSourceSignal?

    // Quitting mid-recording closes the file first, so no sound is lost; dictation quits too.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            guard model.isRecording else { Engine.shared.stop(); return .terminateNow }
            Task { @MainActor in
                await model.stopRecording()
                Engine.shared.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

extension Recorder {
    /// Glyph Record kept its folder under "vaultPath"; in Glyph Jot that key is the notes
    /// folder, so the recordings folder is "recordingsPath". Copied once from Glyph Record.
    @MainActor static func migrateSettings() {
        let d = UserDefaults.standard
        guard d.string(forKey: "recordingsPath") == nil,
              let old = UserDefaults(suiteName: "dev.fru.glyph.record") else { return }
        if let path = old.string(forKey: "vaultPath") { d.set(path, forKey: "recordingsPath") }
        if d.object(forKey: "includeSystemAudio") == nil, old.object(forKey: "includeSystemAudio") != nil {
            d.set(old.bool(forKey: "includeSystemAudio"), forKey: "includeSystemAudio")
        }
    }
}

/// The menu bar icon. It exists from launch, so it lends SwiftUI's openWindow to the rest
/// of the app (`JotWindow.open`).
struct MenuBarLabel: View {
    let recording: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: recording ? "record.circle.fill" : "mic")
            .task { JotWindow.opener = { openWindow(id: "library") } }
    }
}

/// The library window, from anywhere.
@MainActor
enum JotWindow {
    static var opener: (() -> Void)?
    static var window: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true } }

    /// Shows the library (making it if it was closed), optionally coming to the front.
    static func open(activate: Bool = true) {
        if let window, window.isVisible || window.isMiniaturized { window.makeKeyAndOrderFront(nil) } else { opener?() }
        if activate { NSApp.activate() }
    }
}

/// Opens the library on Dictations, from anywhere (an Ask from the talk key, the menu).
enum MainWindow {
    @MainActor static func show() {
        AppModel.shared.sidebar = .dictations
        JotWindow.open()
    }
}
