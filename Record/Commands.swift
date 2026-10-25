import GlyphCore
import SwiftUI
import UniformTypeIdentifiers

struct RecordCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button(model.isRecording ? "Stop Recording" : "New Recording") { model.toggleRecording() }
                .keyboardShortcut("r")
            Button(model.recorder.state == .paused ? "Resume Recording" : "Pause Recording") {
                model.recorder.state == .paused ? model.recorder.resume() : model.recorder.pause()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!model.isRecording)
            Toggle("Record the Mac's Sound Too", isOn: Binding(get: { model.includeSystemAudio }, set: { model.includeSystemAudio = $0 }))
                .disabled(model.isRecording)
            Divider()
            Button("Import Audio\u{2026}") { importAudio() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { model.searchFocused = true }
                .keyboardShortcut("f")
            Button("Quick Open\u{2026}") { model.quickOpen.toggle() }
                .keyboardShortcut("k")
        }
        CommandGroup(after: .sidebar) {
            Button(model.showList ? "Hide List" : "Show List") { animate { model.showList.toggle() } }
                .keyboardShortcut("l", modifiers: [.command, .control])
            Divider()
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { i, tab in
                Button(tab.title) { animate { model.tab = tab } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
        }
        CommandMenu("Conversation") {
            let id = model.selectedID
            Button("Rename") { model.renameRequest += 1 }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(id == nil)
            Button("Add Person, Account or Tag") { model.addLinkRequest = (model.addLinkRequest.id + 1, "") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(id == nil)
            Menu("Move to") {
                ForEach(model.folders, id: \.self) { f in
                    Button(f) { if let id { model.move(id, to: f) } }
                }
            }
            .disabled(id == nil)
            Divider()
            Button("Copy as Markdown") { if let id { model.copyMarkdown(id) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(id == nil)
            Button("Reveal in Finder") { if let id { model.reveal(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(id == nil)
            Divider()
            Button("Move to Trash") { if let id { model.trash(id) } }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(id == nil || id == model.recordingID)
        }
    }

    @MainActor private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose recordings to add to the library"
        panel.prompt = "Import"
        if panel.runModal() == .OK { model.importAudio(panel.urls) }
    }
}

/// The menu bar: jotting (the last dictations, paste, undo), recording, and the way in.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let engine = Engine.shared

    var body: some View {
        Text("Glyph Jot \(Version.text). Hold \(Prefs.shared.talkKey.name) to jot, add Shift for a note")
        if let problem = engine.problem { Text(problem) }
        if engine.gaveUp {
            Button("Start Dictation Again") { engine.start() }
        }
        if !JotPermissions.allGranted {
            Button("Finish Setup\u{2026}") { settings() }
        }
        Divider()
        if model.isRecording {
            Text("Recording \(Format.clock(model.recorder.elapsed))")
            Button(model.recorder.state == .paused ? "Resume" : "Pause") {
                model.recorder.state == .paused ? model.recorder.resume() : model.recorder.pause()
            }
            Button("Stop and Save") { Task { await model.stopRecording() } }
        } else {
            Button("New Recording") { Task { await model.startRecording() } }
            Toggle("Record the Mac's Sound Too", isOn: Binding(get: { model.includeSystemAudio }, set: { model.includeSystemAudio = $0 }))
        }
        Divider()
        Button("Paste Last Dictation") { engine.send(.init(.pasteLast)) }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(engine.recent.isEmpty)
        Button("Undo Last Dictation") { engine.send(.init(.undo)) }
            .keyboardShortcut("z", modifiers: [.control, .command])
            .disabled(engine.recent.isEmpty)
        Button("Use What I Said") { engine.send(.init(.useWhatISaid)) }
            .keyboardShortcut("r", modifiers: [.control, .command])
            .disabled(engine.recent.isEmpty)
        if !engine.recent.isEmpty {
            Menu("Recent") {
                ForEach(engine.recent, id: \.self) { text in
                    Button(String(text.prefix(60))) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
        Divider()
        Button("Open Glyph Jot") {
            openWindow(id: "library")
            NSApp.activate()
        }
        Button("Settings\u{2026}") { settings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Glyph Jot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func settings() {
        openSettings()
        NSApp.activate()
    }
}
