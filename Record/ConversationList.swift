import GlyphCore
import SwiftUI

/// The middle column: a big header for what the sidebar chose (a Studio object or a tag
/// gets its page here), then its recordings and notes.
struct ConversationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let item = model.sidebar ?? .all
        let list = model.listed
        let notes = filedNotes(item)
        VStack(spacing: 0) {
            Group {
                switch item {
                case .object(let id): ObjectPage(id: id)
                case .tag(let t): TagPage(tag: t)
                default: ListHeader(item: item)
                }
            }
            .id(item)

                if list.isEmpty && notes.isEmpty {
                    emptyState(item)
                } else {
                    List(selection: $model.selectedID) {
                        // Keyed on what the row shows, so a row that gains chips is measured again.
                        ForEach(list, id: \.rowKey) { c in
                            ConversationRow(meta: c)
                                .tag(c.id)
                                .contextMenu { ConversationMenu(id: c.id) }
                        }
                        // A page also lists its notes: filed under it, or (a person, a product) naming it.
                        if !notes.isEmpty {
                            Section {
                                ForEach(notes) { note in
                                    Button {
                                        model.openNote = note.file
                                        model.sidebar = .notes
                                    } label: {
                                        NoteRow(note: note, linked: false).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(notes.count == 1 ? "1 note" : "\(notes.count) notes")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    // The Mac's List keeps a row's first height; when any row's content
                    // changes, the list is built again so every row is measured afresh.
                    .id(list.map(\.rowKey))
                    .animation(.glyph(false), value: list.map(\.id))
                }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func filedNotes(_ item: SidebarItem) -> [JotNote] {
        var notes = model.notes(for: item)
        // A person by full name, alias or first name ("Sam" for Sam Lee); a product by name or alias.
        if case .object(let id) = item, let o = model.studio.object(id), o.kind == .person || o.kind == .product {
            let first = o.kind == .person ? [String(o.name.split(separator: " ").first ?? "")] : []
            for n in notesMentioning([o.name] + first + o.aliases) where !notes.contains(n) { notes.append(n) }
        }
        return notes.sorted { $0.date > $1.date }
    }

    @ViewBuilder private func emptyState(_ item: SidebarItem) -> some View {
        if model.searchHits != nil {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing here says \u{201C}\(model.searchText)\u{201D}.")
        } else if model.library.conversations.isEmpty {
            EmptyState(symbol: "tray", title: "Nothing here yet")
        } else {
            EmptyState(symbol: "tray", title: "Nothing filed here yet", message: "File a recording or a note under it and it shows up here.")
        }
    }
}

/// The big title over the list.
struct ListHeader: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.listed.count
        VStack(alignment: .leading, spacing: 4) {
            Text("Recordings")
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 11))
                Text(count == 1 ? "1 recording" : "\(count) recordings")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

/// One conversation in the list: title, when and how long, who, and a status icon.
struct ConversationRow: View {
    let meta: Conversation
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meta.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.recordingID == meta.id {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                        .help("Recording")
                } else if let stage = model.stage(meta.id) {
                    StageIcon(stage: stage)
                } else if model.banners.contains(where: { $0.conversation == meta.id }) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help("Something needs a look")
                }
            }
            HStack(spacing: 5) {
                Text(Format.shortDate(meta.created))
                if meta.durationSec > 0 {
                    Text("\u{00B7}")
                    Text(Format.duration(meta.durationSec))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            // On an object's own page its chip would say the same thing on every row.
            let here: String? = if case .object(let id) = model.sidebar { id } else { nil }
            let links: [Link] = meta.links.filter { $0 != here }.map { .object($0) }
            if !links.isEmpty {
                HStack(spacing: 4) {
                    ForEach(links.prefix(2), id: \.self) { LinkChip(link: $0, size: .small) }
                    if links.count > 2 {
                        Text("+\(links.count - 2)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

/// The actions on a conversation, for its context menu and the detail's more menu.
struct ConversationMenu: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Rename") {
            model.selectedID = id
            model.renameRequest += 1
        }
        Divider()
        Button("Copy as Markdown") { model.copyMarkdown(id) }
        Button("Reveal in Finder") { model.reveal(id) }
        if model.stage(id) == nil, model.recordingID != id {
            Button("Transcribe and Summarize Again") { Task { await model.process(id) } }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trash(id) }
            .disabled(model.recordingID == id)
    }
}

extension Conversation {
    var rowKey: String { ([id, title, String(durationSec)] + links).joined(separator: "|") }
}
