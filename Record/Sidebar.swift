import GlyphCore
import SwiftUI

struct FolderNode: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var count: Int
    var children: [FolderNode]?

    init(_ n: Vault.Node) {
        name = n.name
        path = n.path
        count = n.count
        let kids = n.children.filter { $0.kind != .conversation }.map(FolderNode.init)
        children = kids.isEmpty ? nil : kids
    }
}

/// Library, Domains, People, Accounts, Tags: each with counts, each section folds, and
/// hovering a header reveals its +.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.domains") private var domainsOpen = true
    @AppStorage("sidebar.people") private var peopleOpen = true
    @AppStorage("sidebar.accounts") private var accountsOpen = true
    @AppStorage("sidebar.tags") private var tagsOpen = true
    @State private var creating: Creating?
    @State private var notes = NoteStore.shared
    @State private var newName = ""

    enum Creating: Identifiable {
        case folder(parent: String), person, account
        var id: String {
            switch self {
            case .folder(let p): "folder:" + p
            case .person: "person"
            case .account: "account"
            }
        }
        var title: String {
            switch self {
            case .folder(let p): p.isEmpty ? "New Domain" : "New Folder in \(p)"
            case .person: "New Person"
            case .account: "New Account"
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        let dir = model.library.directory
        let people = dir.entities.filter { $0.entity.kind == .person }
        let accounts = dir.entities.filter { $0.entity.kind == .account }
        let openCount = model.library.tasks.filter { !$0.item.done }.count

        List(selection: $model.sidebar) {
            Section {
                row("All recordings", "waveform", model.library.conversations.count).tag(SidebarItem.all)
                row("Notes", "note.text", notes.notes.count).tag(SidebarItem.notes)
                row("Dictations", "text.cursor", notes.dictationCount).tag(SidebarItem.dictations)
                row("Open tasks", "checklist", openCount).tag(SidebarItem.openTasks)
            }

            Section(isExpanded: $domainsOpen) {
                OutlineGroup(model.library.tree.filter { $0.kind != .conversation }.map(FolderNode.init), children: \.children) { node in
                    row(node.name, "folder", node.count)
                        .tag(SidebarItem.folder(node.path))
                        .contextMenu {
                            Button("New Folder Inside") { ask(.folder(parent: node.path)) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.vault.url(node.path)]) }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            for id in ids where id.contains("/") || model.meta(id) != nil { model.move(id, to: node.path) }
                            return true
                        }
                }
            } header: {
                SectionHeader(title: "Domains", add: "New domain") { ask(.folder(parent: "")) }
            }

            Section(isExpanded: $peopleOpen) {
                ForEach(people, id: \.entity.name) { r in
                    row(r.entity.name, "person", r.count).tag(SidebarItem.person(r.entity.name))
                }
            } header: {
                SectionHeader(title: "People", add: "New person") { ask(.person) }
            }

            Section(isExpanded: $accountsOpen) {
                ForEach(accounts, id: \.entity.name) { r in
                    row(r.entity.name, "building.2", r.count).tag(SidebarItem.account(r.entity.name))
                }
            } header: {
                SectionHeader(title: "Accounts", add: "New account") { ask(.account) }
            }

            if !dir.tags.isEmpty {
                Section(isExpanded: $tagsOpen) {
                    ForEach(dir.tags, id: \.name) { t in
                        row(t.name, "number", t.count).tag(SidebarItem.tag(t.name))
                    }
                } header: {
                    SectionHeader(title: "Tags", add: model.selectedID == nil ? nil : "Tag this conversation") {
                        model.addLinkRequest = (model.addLinkRequest.id + 1, "#")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert(creating?.title ?? "", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } }), presenting: creating) { what in
            TextField("Name", text: $newName)
            Button("Create") { create(what) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ symbol: String, _ count: Int) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: symbol)
        }
        .badge(count)
    }

    private func ask(_ what: Creating) {
        newName = ""
        creating = what
    }

    private func create(_ what: Creating) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return }
        switch what {
        case .folder(let parent):
            let path = parent.isEmpty ? name : parent + "/" + name
            model.createFolder(path)
            model.sidebar = .folder(path)
        case .person: model.createEntity(.person, name)
        case .account: model.createEntity(.account, name)
        }
    }
}

/// A section title; hovering reveals its + (one control, at the trailing edge).
struct SectionHeader: View {
    let title: String
    var add: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let add, hover {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(add)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}
