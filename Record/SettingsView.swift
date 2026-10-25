import GlyphCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var speech: Transcriber.Status?
    @State private var ai = OnDeviceModel.status
    @State private var mic = Permissions.microphone
    @State private var screen = Permissions.screenRecording

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Vault") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Choose\u{2026}", action: chooseVault)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([model.vault.root])
                        } label: { Image(systemName: "folder") }
                        .help("Reveal in Finder")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.vault.root.lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text(model.vault.root.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Section("Recording") {
                Toggle("Record the Mac's sound too", isOn: $model.includeSystemAudio)
                StatusRow(title: "Microphone", ok: mic == .granted,
                          fix: micFix)
                StatusRow(title: "The Mac's sound", ok: screen == .granted,
                          fix: screen == .granted ? nil : ("Allow", {
                              Permissions.requestScreenRecording()
                              AppModel.openSettingsPane("Privacy_ScreenCapture")
                          }))
            }

            Section("On this Mac") {
                speechRow
                StatusRow(title: "Apple Intelligence", ok: ai == .available, detail: aiDetail,
                          fix: ai == .appleIntelligenceOff ? ("Open Settings", { AppModel.openSettingsPane("AppleIntelligence") }) : nil)
            }

            Section("Shortcuts") {
                ForEach(Self.shortcuts, id: \.0) { s in
                    LabeledContent(s.1) {
                        Text(s.0)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 7)
                            .frame(minHeight: 22)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .task {
            speech = await Transcriber().status()
            ai = OnDeviceModel.status
            mic = Permissions.microphone
            screen = Permissions.screenRecording
        }
        .onChange(of: model.modelDownload) { if model.modelDownload == nil { Task { speech = await Transcriber().status() } } }
    }

    @ViewBuilder private var speechRow: some View {
        if let p = model.modelDownload {
            LabeledContent("Speech model") {
                ProgressView(value: p).frame(width: 140)
            }
        } else {
            switch speech {
            case .none:
                LabeledContent("Speech model") { ProgressView().controlSize(.small) }
            case .ready?:
                StatusRow(title: "Speech model", ok: true)
            case .needsDownload?:
                StatusRow(title: "Speech model", ok: false, detail: "Downloads once, then works offline",
                          fix: ("Download", { Task { await model.downloadSpeechModel() } }))
            case .unsupported?:
                StatusRow(title: "Speech model", ok: false, detail: "Not available for this Mac's language")
            }
        }
    }

    private var micFix: (String, () -> Void)? {
        switch mic {
        case .granted: return nil
        case .notDetermined: return ("Allow", { Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone } })
        case .denied: return ("Open Settings", { AppModel.openSettingsPane("Privacy_Microphone") })
        }
    }

    private var aiDetail: String? {
        switch ai {
        case .available: nil
        case .appleIntelligenceOff: "Turn it on for summaries"
        case .modelNotReady: "Still downloading"
        case .deviceNotEligible: "This Mac can't run it"
        case .unavailable: "Not available right now"
        }
    }

    static let shortcuts: [(String, String)] = [
        ("\u{2318}R", "Record or stop"),
        ("\u{21E7}\u{2318}P", "Pause or resume"),
        ("\u{2318}K", "Quick open"),
        ("\u{2318}F", "Search"),
        ("\u{21E7}\u{2318}I", "Import audio"),
        ("\u{21E7}\u{2318}T", "Add a person, account or tag"),
        ("\u{2318}1  \u{2318}2  \u{2318}3", "Summary, transcript, action items"),
        ("\u{2303}\u{2318}S", "Show or hide the sidebar"),
        ("\u{2303}\u{2318}L", "Show or hide the list"),
        ("\u{2318}\u{21A9}", "Rename"),
        ("\u{21E7}\u{2318}C", "Copy as Markdown"),
        ("\u{21E7}\u{2318}R", "Reveal in Finder"),
        ("\u{2318}\u{232B}", "Move to Trash"),
    ]

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.vault.root
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that holds your conversations"
        if panel.runModal() == .OK, let url = panel.url { model.switchVault(to: url) }
    }
}

/// A status as an icon (green tick or orange mark), with the fix beside it.
struct StatusRow: View {
    let title: String
    let ok: Bool
    var detail: String?
    var fix: (String, () -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let fix { Button(fix.0, action: fix.1).controlSize(.small) }
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ok ? Color.accentColor : Color.orange)
                    .accessibilityLabel(ok ? "Ready" : "Needs attention")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }
}
