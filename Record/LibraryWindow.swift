import GlyphCore
import SwiftUI
import UniformTypeIdentifiers

/// The library: sidebar | list | detail. The sidebar is the split view's own (it
/// collapses natively); the list collapses with its own toggle and can be resized.
struct LibraryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            Group {
            switch model.sidebar {
            case .notes: NotesPane()
            case .dictations: DictationsPane()
            default:
            GeometryReader { geo in
            HStack(spacing: 0) {
                if model.showList {
                    // A small window keeps the list from crowding the conversation.
                    ConversationList()
                        .frame(width: min(model.listWidth, max(250, geo.size.width * 0.4)))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ResizeHandle(width: $model.listWidth)
                }
                DetailColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            }
            }
            }
            .overlay(alignment: .top) { appBanners }
        }
        .navigationTitle("Glyph Jot") // the window's name in the Window menu and Mission Control
        .toolbar(removing: .title)
        .toolbar {
            // One control per corner: with the sidebar hidden its toggle owns the corner.
            if model.columns != .detailOnly {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.glyph(reduceMotion)) { model.showList.toggle() }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .symbolVariant(model.showList ? .fill : .none)
                }
                .help(model.showList ? "Hide the list (Control-Command-L)" : "Show the list (Control-Command-L)")
            }
            }
            ToolbarItem(placement: .principal) {
                SearchField(text: $model.searchText, focus: $model.searchFocused)
                    .frame(minWidth: 180, idealWidth: 300, maxWidth: 340)
            }
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .overlay {
            if model.quickOpen {
                QuickOpen()
                    .transition(.opacity)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        Label("Drop to import", systemImage: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importAudio(urls)
            return true
        } isTargeted: { dropping = $0 }
        .animation(.glyph(reduceMotion), value: model.columns)
        .animation(.glyph(reduceMotion), value: model.quickOpen)
        .task { NoteStore.shared.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in NoteStore.shared.reload() }
    }

    @ViewBuilder private var appBanners: some View {
        let banners = model.banners.filter { $0.conversation == nil }
        if !banners.isEmpty {
            VStack(spacing: 8) {
                ForEach(banners) { BannerView(banner: $0) }
            }
            .frame(maxWidth: 560)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
            .padding(.top, 10)
            .padding(.horizontal, 16)
        }
    }
}

/// A thin divider that resizes the list when dragged.
struct ResizeHandle: View {
    @Binding var width: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            let s = start ?? width
                            start = s
                            width = min(440, max(260, s + g.translation.width))
                        }
                        .onEnded { _ in start = nil })
            }
    }
}

/// Record in the toolbar's corner: a green capsule; while recording, the time and Stop.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRecording {
            Button { model.toggleRecording() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    Text(Format.clock(model.recorder.elapsed))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop recording (Command-R)")
        } else {
            Button { model.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Record").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .help("Record a conversation (Command-R)")
            .contextMenu {
                Toggle("Record the Mac's Sound Too", isOn: Binding(get: { model.includeSystemAudio }, set: { model.includeSystemAudio = $0 }))
            }
        }
    }
}

/// The toolbar's search: AppKit's own field, so it looks and behaves like the Mac's.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focus: Bool

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Search"
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        f.controlSize = .large
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        if focus {
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                focus = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSSearchField else { return }
            MainActor.assumeIsolated { text.wrappedValue = f.stringValue }
        }
    }
}
