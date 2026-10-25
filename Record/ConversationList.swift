import GlyphCore
import SwiftUI

/// The middle column: a big header for what the sidebar chose (a person, account or
/// tag gets its page here), then its conversations.
struct ConversationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let item = model.sidebar ?? .all
        VStack(spacing: 0) {
            Group {
                switch item {
                case .person(let n): EntityPage(kind: .person, name: n)
                case .account(let n): EntityPage(kind: .account, name: n)
                case .tag(let t): TagPage(tag: t)
                default: ListHeader(item: item)
                }
            }
            .id(item)

            if item == .openTasks {
                TaskList()
            } else {
                let list = model.listed
                if list.isEmpty {
                    emptyState(item)
                } else {
                    List(selection: $model.selectedID) {
                        // Keyed on what the row shows, so a row that gains chips is measured again.
                        ForEach(list, id: \.rowKey) { c in
                            ConversationRow(meta: c)
                                .tag(c.id)
                                .draggable(c.id)
                                .contextMenu { ConversationMenu(id: c.id) }
                        }
                        // A person's or an account's page also lists the notes that name them.
                        let mentions = mentionNotes(item)
                        if !mentions.isEmpty {
                            Section {
                                ForEach(mentions) { note in
                                    Button {
                                        model.openNote = note.file
                                        model.sidebar = .notes
                                    } label: {
                                        NoteRow(note: note, linked: false).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(mentions.count == 1 ? "1 note" : "\(mentions.count) notes")
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
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func mentionNotes(_ item: SidebarItem) -> [JotNote] {
        switch item {
        // A person by full name, alias or first name ("Sam" for Sam Lee).
        case .person(let n): notesMentioning([n, String(n.split(separator: " ").first ?? "")] + (model.entity(.person, n)?.aliases ?? []))
        case .account(let n): notesMentioning([n] + (model.entity(.account, n)?.aliases ?? []))
        default: []
        }
    }

    @ViewBuilder private func emptyState(_ item: SidebarItem) -> some View {
        if model.searchHits != nil {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing here says \u{201C}\(model.searchText)\u{201D}.")
        } else if model.library.conversations.isEmpty {
            EmptyState(symbol: "tray", title: "Nothing here yet")
        } else if case .folder = item {
            EmptyState(symbol: "folder", title: "An empty folder", message: "Record here, or drag a conversation onto it in the sidebar.")
        } else {
            EmptyState(symbol: "person.crop.circle.badge.plus", title: "No conversations yet", message: "Add this name to a conversation and it shows up here.")
        }
    }
}

/// The big title over the list.
struct ListHeader: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let (title, symbol): (String, String) = switch item {
        case .all: ("Recordings", "waveform")
        case .openTasks: ("Open tasks", "checklist")
        case .folder(let p): (p.split(separator: "/").last.map(String.init) ?? p, "folder")
        default: ("", "")
        }
        let count = item == .openTasks ? model.openTasks.count : model.listed.count
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(item == .openTasks ? "\(count) to do" : count == 1 ? "1 conversation" : "\(count) conversations")
                if case .folder(let p) = item, p.contains("/") {
                    Text(AppModel.parent(p)).lineLimit(1).truncationMode(.head)
                }
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
            let links: [Link] = meta.people.map { .person($0) } + meta.accounts.map { .account($0) }
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

/// Every open action item; checking one writes notes.md, clicking one opens its call.
struct TaskList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tasks = model.openTasks
        if tasks.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "All done", message: "Action items from your conversations land here.")
        } else {
            List {
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, t in
                    TaskRow(task: t, selected: model.selectedID == t.conversation)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

struct TaskRow: View {
    let task: VaultTask
    let selected: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            CheckBox(done: task.item.done) { model.setTask(task.conversation, task.item, done: $0) }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.item.text)
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: "waveform").font(.system(size: 10))
                    Text(task.title).lineLimit(1)
                    if let owner = task.item.owner { Text("\u{00B7} \(owner)").lineLimit(1) }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedID = task.conversation
            model.tab = .actions
        }
    }
}

/// A round checkbox that springs when ticked.
struct CheckBox: View {
    let done: Bool
    var onChange: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { onChange(!done) } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Done" : "Not done")
        .animation(.glyph(reduceMotion), value: done)
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
        Menu("Move to") {
            ForEach(model.folders, id: \.self) { f in
                Button(f) { model.move(id, to: f) }
                    .disabled(AppModel.parent(id) == f)
            }
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
    var rowKey: String { ([id, title, String(durationSec)] + people + accounts).joined(separator: "|") }
}
