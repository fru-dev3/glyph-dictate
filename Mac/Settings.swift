import AVFoundation
import ServiceManagement
import SwiftUI

/// What macOS has to allow before Glyph Jot can hear the key, the mic, and paste. The engine
/// asks through the app (its parent), so the app's own answers are the ones that count.
enum JotPermissions {
    static var keys: Bool { CGPreflightListenEventAccess() }
    static var paste: Bool { CGPreflightPostEventAccess() }
    static var mic: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var allGranted: Bool { keys && paste && mic }

    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

struct GeneralTab: View {
    @Bindable private var prefs = Prefs.shared
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    // Re-read when the window comes back, after a trip to System Settings.
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Keys") {
                Picker("Talk key", selection: $prefs.talkKey) {
                    ForEach(TalkKey.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Shortcut(keys: "Hold \(prefs.talkKey.name)", does: "Dictate into any app")
                Shortcut(keys: "Double-press \(prefs.talkKey.name)", does: "Hands-free until you press it again")
                Shortcut(keys: "\(prefs.talkKey.name) + Shift", does: "Save a thought to the vault, like Glyph on the phone")
                Shortcut(keys: "\(prefs.talkKey.name) + \(prefs.talkKey.commandName)",
                         does: "Command Mode: say what to do with the selected text")
                Shortcut(keys: "\(prefs.talkKey.name) + \(prefs.talkKey.askName)",
                         does: "Ask your history: \"what did I tell Claude about the ship script?\"")
                Shortcut(keys: "Say \"fill the form, name …, email …\"", does: "Fill every field of the form you're in")
                Shortcut(keys: "End with \"press enter\"", does: "Press Return after typing (\"send it\" in a terminal)")
                Shortcut(keys: "Control-Command-V", does: "Paste the last dictation again")
                Shortcut(keys: "Control-Command-Z", does: "Take the last dictation back out")
                Shortcut(keys: "Control-Command-R", does: "Swap it for exactly what you said")
                Shortcut(keys: "Esc", does: "Cancel")
                if prefs.talkKey == .fn {
                    Text("Glyph Jot sets System Settings > Keyboard > \"Press Globe key to\" to Do Nothing, so a double-press doesn't open the emoji picker. Give Fn to Glyph Jot alone, not to another dictation app too.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Writing") {
                Toggle("Clean up with on-device AI", isOn: $prefs.aiCleanup)
                    .disabled(!AI.available)
                Text(AI.available
                     ? "Takes out \"no wait\" corrections and turns spoken lists into lists. Runs on this Mac with Apple Intelligence."
                     : "Needs Apple Intelligence (System Settings > Apple Intelligence & Siri). Filler words are still removed.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Keep the microphone ready", isOn: $prefs.keepMicReady)
                Text("Starts at once and never misses your first word. The mic stays on between dictations (the orange dot), holding under a second of sound in memory, never saved. Off: the mic turns on when you press the key.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Sounds", isOn: $prefs.sounds)
                Toggle("Open at login", isOn: $atLogin)
                    .onChange(of: atLogin) {
                        try? atLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
            Section("Permissions") {
                Grant(name: "Input Monitoring", why: "to hear the talk key", ok: JotPermissions.keys, pane: "Privacy_ListenEvent")
                Grant(name: "Accessibility", why: "to paste where you are", ok: JotPermissions.paste, pane: "Privacy_Accessibility")
                Grant(name: "Microphone", why: "to hear you", ok: JotPermissions.mic, pane: "Privacy_Microphone")
            }
            .id(refresh)
            Section("Where your words go") {
                LabeledContent {
                    HStack {
                        Text(DictationLog.chosen?.path(percentEncoded: false) ?? "None").foregroundStyle(.secondary).lineLimit(1)
                        Button("Choose…") { chooseVault() }
                    }
                } label: {
                    Text("Notes folder")
                    Text("Optional. Any folder, an Obsidian vault too: thoughts are saved in it as Markdown notes, and Glyph Jot keeps its own files in a hidden .jot folder there, so they sync with it.")
                }
                LabeledContent("Every dictation", value: DictationLog.folder.path(percentEncoded: false))
                LabeledContent("Thoughts", value: Thoughts.folder.path(percentEncoded: false))
                Text("Nothing leaves this Mac. Speech and cleanup run on-device.").font(.callout).foregroundStyle(.secondary)
            }
            .id(refresh)
            Section("About") {
                LabeledContent("Version", value: Version.text)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Your Dictionary comes along to the new folder.
        let words = Words.url
        jotDefaults.set(url.path(percentEncoded: false), forKey: "vaultPath")
        if !FileManager.default.fileExists(atPath: Words.url.path) {
            try? FileManager.default.createDirectory(at: Words.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: words, to: Words.url)
        }
        Words.shared.load()
        refresh += 1
    }
}

private struct Shortcut: View {
    let keys: String
    let does: String
    var body: some View { LabeledContent(keys, value: does) }
}

private struct Grant: View {
    let name: String
    let why: String
    let ok: Bool
    let pane: String

    var body: some View {
        LabeledContent {
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed")
            } else {
                Button("Allow…") { JotPermissions.open(pane) }
            }
        } label: {
            Text(name)
            Text(why)
        }
    }
}

struct StylesTab: View {
    private let prefs = Prefs.shared

    var body: some View {
        Form {
            Text("How dictation reads in each kind of app.").foregroundStyle(.secondary)
            ForEach(Category.allCases, id: \.self) { category in
                Section {
                    Picker(category.name, selection: Binding(get: { prefs.style(for: category) },
                                                             set: { prefs.setStyle($0, for: category) })) {
                        ForEach(Style.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    Text(prefs.style(for: category).example).font(.callout).italic()
                } footer: {
                    Text(category.apps)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DictionaryTab: View {
    @Bindable private var words = Words.shared
    @State private var write = ""
    @State private var heard = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names and words Glyph Jot should spell your way. Add what it hears instead, if it keeps getting one wrong. When you fix a word it typed, it learns it here by itself.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Spelled", text: $write, prompt: Text("Harbr"))
                TextField("Heard as (optional)", text: $heard, prompt: Text("harbor"))
                Button("Add") {
                    words.dictionary.append(.init(write: write.trimmed, heard: heard.trimmed))
                    write = ""; heard = ""
                }
                .disabled(write.trimmed.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            List {
                ForEach(words.dictionary) { entry in
                    HStack {
                        Text(entry.write).bold()
                        if !entry.heard.isEmpty { Text("heard as \(entry.heard)").foregroundStyle(.secondary) }
                        if entry.learned == true {
                            Text(entry.waiting ? "learning: fix it once more" : "learned").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().strokeBorder(.secondary.opacity(0.5)))
                        }
                        Spacer()
                        Button { words.dictionary.removeAll { $0 == entry } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.write)")
                    }
                }
            }
            .overlay { if words.dictionary.isEmpty { Text("No words yet").foregroundStyle(.secondary) } }
            Text("Saved in your vault: \(Words.url.path(percentEncoded: false))").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct SnippetsTab: View {
    @Bindable private var words = Words.shared
    @State private var say = ""
    @State private var write = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say a short phrase, get the full text: an address, a link, a sign-off.").foregroundStyle(.secondary)
            TextField("When I say", text: $say, prompt: Text("my calendar link"))
            TextEditor(text: $write)
                .frame(height: 70)
                .overlay(alignment: .topLeading) {
                    if write.isEmpty { Text("Type this").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                }
                .accessibilityLabel("Type this")
            Button("Add Snippet") {
                words.snippets.removeAll { $0.say.lowercased() == say.trimmed.lowercased() }
                words.snippets.append(.init(say: say.trimmed, write: write))
                say = ""; write = ""
            }
            .disabled(say.trimmed.isEmpty || write.isEmpty)
            List {
                ForEach(words.snippets) { snippet in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(snippet.say).bold()
                            Text(snippet.write).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { words.snippets.removeAll { $0 == snippet } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(snippet.say)")
                    }
                }
            }
            .overlay { if words.snippets.isEmpty { Text("No snippets yet").foregroundStyle(.secondary) } }
        }
        .padding()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
