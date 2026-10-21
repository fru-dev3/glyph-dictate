import AppKit
import SwiftUI

/// The small floating capsule at the bottom of the screen while you dictate. A panel that
/// never takes focus, so the app you're typing into keeps its cursor.
@MainActor
final class Pill {
    static let shared = Pill()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 36),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // Jot has a Dock icon, so it's a regular app: by default its panels hide whenever another
        // app is active, which is always while you dictate (and over full-screen apps).
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PillView())
        return panel
    }()

    func show() {
        // The screen the pointer is on, just above the Dock.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private struct PillView: View {
    private let dictation = Dictation.shared
    private let green = Color(red: 0, green: 128 / 255, blue: 0) // office green

    var body: some View {
        HStack(spacing: 3) {
            switch dictation.state {
            case .finishing:
                ProgressView().controlSize(.small).tint(.white)
            case .done where dictation.problem != nil:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text(dictation.problem ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.leading, 5)
            case .done where dictation.copiedOnly:
                // No text field had focus: it's on the clipboard instead.
                Image(systemName: "doc.on.clipboard").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("Copied · ⌘V to paste").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.leading, 5)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(green)
                if let note = dictation.note {
                    Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).padding(.leading, 5)
                }
            default:
                if dictation.locked {
                    Circle().fill(green).frame(width: 7, height: 7).padding(.trailing, 3)
                }
                ForEach(dictation.levels.indices, id: \.self) { i in
                    Capsule().fill(.white)
                        .frame(width: 3, height: 4 + CGFloat(dictation.levels[i]) * 16)
                }
                if dictation.hearing {
                    // How long and how many words so far, quiet beside the voice. Shown only
                    // while speech is turning your voice into words.
                    TimelineView(.periodic(from: dictation.startedAt, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(dictation.startedAt))
                            .formatted(.time(pattern: .minuteSecond)))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.leading, 10)
                    Text("\(dictation.words) words").foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 6)
                } else {
                    // Keep talking: the sound is kept and heard once speech is back.
                    Text(dictation.reconnecting ? "Reconnecting, keep talking" : "Starting")
                        .foregroundStyle(dictation.reconnecting ? .orange : .white.opacity(0.7))
                        .padding(.leading, 10)
                }
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .animation(.easeOut(duration: 0.08), value: dictation.levels)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(.black.opacity(0.85)))
        .frame(width: 240, height: 36)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch dictation.state {
        case .finishing: "Writing"
        case .done: dictation.problem ?? (dictation.copiedOnly ? "Copied" : "Done")
        default: dictation.mode == .thought ? "Listening for a thought" : dictation.mode == .command ? "Listening for a command" : "Listening"
        }
    }
}
