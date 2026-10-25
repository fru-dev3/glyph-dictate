import AppKit
import GlyphCore
import SwiftUI

/// A floating panel that stays on top of every app while recording, without taking
/// focus from the call. It can still take typing for the tag field.
final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecorderPanelController {
    private unowned let model: AppModel
    private var panel: RecorderPanel?

    init(model: AppModel) { self.model = model }

    var window: NSWindow? { panel }

    func show() {
        if panel == nil {
            let p = RecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                                  styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.animationBehavior = .utilityWindow

            let host = NSHostingController(rootView: RecorderPanelView().environment(model))
            host.sizingOptions = [.preferredContentSize]
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = .clear
            p.contentViewController = host
            panel = p
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 360 - 20, y: frame.maxY - 16))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }
}

/// Behind-window blur, so the panel reads as glass over whatever is beneath.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct RecorderPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Float] = Array(repeating: 0, count: 28)

    var body: some View {
        let recorder = model.recorder
        let paused = recorder.state == .paused
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(paused ? Color.secondary : Color.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !paused && !reduceMotion)
                    .accessibilityLabel(paused ? "Paused" : "Recording")
                Text(Format.clock(recorder.elapsed))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(paused ? .secondary : .primary)
                LevelMeter(history: history, paused: paused)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    PanelButton(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume" : "Pause") {
                        paused ? recorder.resume() : recorder.pause()
                    }
                    PanelButton(symbol: "stop.fill", help: "Stop and save", prominent: true) {
                        Task { await model.stopRecording() }
                    }
                }
            }

            if let meta = model.recording {
                let links: [Link] = meta.people.map { .person($0) } + meta.accounts.map { .account($0) } + meta.tags.map { .tag($0) }
                VStack(alignment: .leading, spacing: 8) {
                    if !links.isEmpty {
                        FlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(links, id: \.self) { link in
                                LinkChip(link: link, size: .small, onRemove: { animate { model.removeLink(link, from: meta.id) } })
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                        }
                    }
                    LinkAddField(style: .inline, placeholder: "Who is this with? Add people, accounts, #tags",
                                 excluding: Set(links), alwaysOpen: true) { link in
                        model.addLink(link, to: meta.id)
                    }
                }
                .animation(.glyph(reduceMotion), value: links)
            }

            if model.jotting != nil || !model.jots.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: model.jotting != nil ? "lock.fill" : "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(model.jotting != nil ? "Jotting. Kept out of this recording"
                         : model.jots.count == 1 ? "1 jot kept out of the transcript" : "\(model.jots.count) jots kept out of the transcript")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }

            if let warning = recorder.warning {
                Label(warning, systemImage: "speaker.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .onChange(of: recorder.levels) {
            let level = recorder.levels.values.max() ?? 0
            history.removeFirst()
            history.append(level)
        }
        .onChange(of: recorder.state) { if recorder.state == .paused { history = history.map { _ in 0 } } }
    }
}

struct PanelButton: View {
    let symbol: String
    let help: String
    var prominent = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(prominent ? .white : .primary)
                .frame(width: 32, height: 32)
                .background(prominent ? AnyShapeStyle(Color.red.opacity(hover ? 0.85 : 1)) : AnyShapeStyle(.quaternary.opacity(hover ? 1 : 0.7)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The last few seconds of sound as bars, newest at the right.
struct LevelMeter: View {
    let history: [Float]
    let paused: Bool

    var body: some View {
        GeometryReader { geo in
            let n = history.count
            let gap: CGFloat = 2
            let w = max(1.5, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    // Speech sits low on a linear scale; a square root lifts it into view.
                    let v = CGFloat(sqrt(max(0, min(1, history[i]))))
                    Capsule()
                        .fill(paused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                        .frame(width: w, height: max(3, v * geo.size.height))
                        .opacity(0.35 + 0.65 * Double(i) / Double(n))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.1), value: history)
        }
        .accessibilityHidden(true)
    }
}
