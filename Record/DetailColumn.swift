import GlyphCore
import SwiftUI

/// The open conversation, or a quiet welcome when none is.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let meta = model.selected {
            ConversationDetail(meta: meta)
                .id(meta.id)
        } else {
            let first = model.library.conversations.isEmpty
            EmptyState(symbol: "waveform", title: first ? "Record your first conversation" : "Pick a conversation") {
                if first {
                    VStack(spacing: 18) {
                        Button { model.toggleRecording() } label: {
                            Label("Record", systemImage: "record.circle").padding(.horizontal, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                        KeyHint(keys: "\u{21E7}\u{2318}I", label: "Import audio, or drop a file here")
                    }
                } else {
                VStack(alignment: .leading, spacing: 10) {
                    KeyHint(keys: "\u{2318}R", label: "Record")
                    KeyHint(keys: "\u{2318}K", label: "Quick open")
                    KeyHint(keys: "\u{21E7}\u{2318}I", label: "Import audio, or drop a file here")
                }
                }
            }
        }
    }
}

struct ConversationDetail: View {
    let meta: Conversation
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @State private var notes = Notes()
    @State private var transcript = Transcript()
    @State private var player = AudioPlayer()
    @FocusState private var titleFocused: Bool

    private var audioURL: URL { model.vault.url(meta.id).appending(path: meta.audio) }
    private var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 22)
                ForEach(model.banners.filter { $0.conversation == meta.id }) { b in
                    BannerView(banner: b).padding(.bottom, 16)
                }
                TabBar(selection: $model.tab)
                    .padding(.bottom, 20)
                Group {
                    switch model.tab {
                    case .summary: SummaryTab(meta: meta, notes: notes, hasTranscript: !transcript.segments.isEmpty)
                    case .transcript: TranscriptTab(meta: meta, transcript: transcript, player: player, hasAudio: hasAudio)
                    }
                }
                .transition(.opacity)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.tab == .transcript, hasAudio {
                PlayerBar(player: player)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.glyph(reduceMotion), value: model.tab)
        .task(id: "\(meta.id)|\(model.library.generation)") { load() }
        .onAppear {
            title = meta.title
            if hasAudio { player.load(audioURL) }
        }
        .onDisappear { player.stop() }
        .onChange(of: meta.title) { if !titleFocused { title = meta.title } }
        .onChange(of: model.renameRequest) { titleFocused = true }
        .onChange(of: titleFocused) { if !titleFocused { model.rename(meta.id, to: title) } }
    }

    private func load() {
        let vault = model.vault
        notes = vault.notes(meta.id)
        transcript = vault.transcript(meta.id)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .onExitCommand { title = meta.title; titleFocused = false }
                    .accessibilityLabel("Title")
                Spacer(minLength: 0)
                MoreMenu(id: meta.id)
            }

            FlowLayout(spacing: 16, lineSpacing: 6) {
                MetaChip(symbol: "calendar", text: Format.longDate(meta.created))
                if meta.durationSec > 0 { MetaChip(symbol: "clock", text: Format.duration(meta.durationSec)) }
                if let device = meta.device { MetaChip(symbol: "laptopcomputer", text: device) }
                if let stage = model.stage(meta.id) {
                    HStack(spacing: 5) {
                        StageIcon(stage: stage)
                        Text(stage.help).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            LinkRow(meta: meta)
        }
    }
}

/// What a recording is filed under (Studio objects and #tags), the add field, then the AI's guesses.
struct LinkRow: View {
    let meta: Conversation
    @Environment(AppModel.self) private var model

    var body: some View {
        LinkEditor(target: .recording(meta.id),
                   links: meta.links.map { .object($0) } + meta.tags.map { .tag($0) },
                   suggestions: meta.suggested.links.map { .object($0) } + meta.suggested.people.map { .person($0) } + meta.suggested.tags.map { .tag($0) },
                   onAnswer: { link, yes in model.answer(link, for: meta.id, accept: yes) })
    }
}

/// Links on a recording or a note: chips that open their page, the + field, and guesses.
struct LinkEditor: View {
    let target: LinkTarget
    let links: [Link]
    var suggestions: [Link] = []
    var onAnswer: ((Link, Bool) -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 8) {
            ForEach(links, id: \.self) { link in
                LinkChip(link: link, onOpen: { if let item = link.sidebarItem { model.sidebar = item } }, onRemove: {
                    animate { model.removeLink(link, from: target) }
                })
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            LinkAddField(excluding: Set(links), request: model.addLinkRequest) { link in
                model.addLink(link, to: target)
            }
            ForEach(suggestions, id: \.self) { link in
                SuggestionChip(link: link,
                               onAccept: { animate { onAnswer?(link, true) } },
                               onDismiss: { animate { onAnswer?(link, false) } })
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.glyph(false), value: links)
        .animation(.glyph(false), value: suggestions)
        .zIndex(5)
    }
}

/// Every other action, behind one button.
struct MoreMenu: View {
    let id: String

    var body: some View {
        Menu {
            ConversationMenu(id: id)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("More")
    }
}

/// Summary / Transcript with an indicator that slides between them.
struct TabBar: View {
    @Binding var selection: DetailTab
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    withAnimation(.glyph(reduceMotion)) { selection = tab }
                } label: {
                    Text(tab.title)
                    .font(.system(size: 13, weight: selection == tab ? .semibold : .medium))
                    .fixedSize()
                    .foregroundStyle(selection == tab ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(.background)
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "indicator", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.55), in: Capsule())
    }
}

// MARK: tabs

struct SummaryTab: View {
    let meta: Conversation
    let notes: Notes
    let hasTranscript: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if !notes.summary.isEmpty || !notes.decisions.isEmpty || !notes.actions.isEmpty {
            VStack(alignment: .leading, spacing: 26) {
                if !notes.summary.isEmpty {
                    Text(notes.summary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !notes.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Decisions", systemImage: "signpost.right.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .labelStyle(TintedIconLabel())
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(.tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                                Text(d).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                            }
                        }
                    }
                }
                // Read here only: tasks live in Glyph Studio, not in Glyph Jot.
                if !notes.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Action items", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .labelStyle(TintedIconLabel())
                        ForEach(Array(notes.actions.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(.tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.text).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                                    if item.owner != nil || item.due != nil {
                                        HStack(spacing: 14) {
                                            if let o = item.owner { MetaChip(symbol: "person", text: o) }
                                            if let d = item.due { MetaChip(symbol: "calendar", text: Format.due(d)) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if let stage = model.stage(meta.id) {
            Working(stage: stage)
        } else if hasTranscript {
            EmptyState(symbol: "sparkles", title: "No summary yet") {
                Button("Summarize") { Task { await model.summarizeAndLink(meta.id) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(minHeight: 260)
        } else if model.recordingID == meta.id {
            EmptyState(symbol: "record.circle", title: "Recording", message: "The summary is written when you stop.")
                .frame(minHeight: 260)
        } else {
            EmptyState(symbol: "waveform", title: "Not transcribed yet") {
                Button("Transcribe and Summarize") { Task { await model.process(meta.id) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(minHeight: 260)
        }
    }
}

struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(.tint).font(.system(size: 14))
            configuration.title
        }
    }
}

/// Background work in progress, in place of a tab's content.
struct Working: View {
    let stage: Stage

    var body: some View {
        VStack(spacing: 14) {
            if case .transcribing(let p) = stage {
                ProgressView(value: p).frame(width: 180)
            } else if case .downloadingModel(let p) = stage {
                ProgressView(value: p).frame(width: 180)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(stage.help).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct TranscriptTab: View {
    let meta: Conversation
    let transcript: Transcript
    let player: AudioPlayer
    let hasAudio: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if transcript.segments.isEmpty {
            if let stage = model.stage(meta.id) {
                Working(stage: stage)
            } else {
                EmptyState(symbol: "text.quote", title: "No transcript yet") {
                    if hasAudio, model.recordingID != meta.id {
                        Button("Transcribe") { Task { await model.process(meta.id) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(minHeight: 260)
            }
        } else {
            let current = transcript.segments.lastIndex { $0.start <= player.time + 0.05 }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { i, s in
                    // Jots that began before this segment (and after the one before) show above it.
                    ForEach(meta.jots.filter { j in j.start < s.start && (i == 0 || j.start >= transcript.segments[i - 1].start) }, id: \.start) { JotMarker(jot: $0) }
                    SegmentRow(segment: s,
                               speaker: transcript.speakers[s.speaker] ?? s.speaker,
                               showSpeaker: i == 0 || transcript.segments[i - 1].speaker != s.speaker,
                               isCurrent: hasAudio && player.started && current == i) {
                        guard hasAudio else { return }
                        player.seek(s.start, play: true)
                    }
                }
                ForEach(meta.jots.filter { $0.start >= (transcript.segments.last?.start ?? 0) }, id: \.start) { JotMarker(jot: $0) }
            }
        }
    }
}

/// Where you jotted during the recording: kept out of the transcript, or a note linked here.
struct JotMarker: View {
    let jot: Jot
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: jot.note != nil ? "note.text" : "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            if let note = jot.note {
                Button {
                    model.sidebar = .notes
                    model.openNote = note
                } label: {
                    let title = NoteStore.shared.notes.first { $0.file == note }?.title
                    Text("\(Text("Note at \(Format.clock(jot.start))").underline())\(title.map { ": \($0)" } ?? "")")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open the note you said here")
            } else {
                Text("You jotted from \(Format.clock(jot.start)) to \(Format.clock(jot.end)), kept out of the transcript")
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .padding(.vertical, 6)
        .padding(.leading, 40) // under the timestamps' column
    }
}

struct SegmentRow: View {
    let segment: Transcript.Segment
    let speaker: String
    let showSpeaker: Bool
    let isCurrent: Bool
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Format.clock(segment.start))
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                if showSpeaker, !speaker.isEmpty {
                    Text(speaker)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SpeakerColor.for(speaker))
                }
                Text(segment.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : hover ? Color.secondary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, showSpeaker ? 8 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .help("Play from \(Format.clock(segment.start))")
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.accentColor, .blue, .purple, .teal, .pink, .indigo]
    static func `for`(_ name: String) -> Color {
        palette[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % palette.count]
    }
}
