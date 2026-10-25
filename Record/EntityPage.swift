import GlyphCore
import SwiftUI

/// A person's or an account's page over its calls: name, where they work, aliases,
/// notes. Every edit saves to People/<Name>.md or Accounts/<Name>.md.
struct EntityPage: View {
    let kind: Entity.Kind
    let name: String
    @Environment(AppModel.self) private var model
    @State private var draft = Entity(kind: .person, name: "")
    @State private var title = ""
    @State private var addingAlias = false
    @State private var alias = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    enum Field { case name, account, alias, notes }

    var body: some View {
        let count = model.listed.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Avatar(name: name, kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold))
                        .focused($focus, equals: .name)
                        .onSubmit(renameIfNeeded)
                    Text(count == 1 ? "1 conversation" : "\(count) conversations")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if kind == .person {
                HStack(spacing: 6) {
                    Image(systemName: "building.2").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Works at", text: Binding(get: { draft.account ?? "" }, set: { draft.account = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focus, equals: .account)
                        .onSubmit { save(now: true) }
                    if let account = draft.account, model.entity(.account, account) != nil {
                        Button { model.sidebar = .account(account) } label: {
                            Image(systemName: "arrow.right.circle").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Open \(account)")
                    }
                }
            }

            FlowLayout(spacing: 5) {
                ForEach(draft.aliases, id: \.self) { a in
                    AliasChip(text: a) {
                        animate { draft.aliases.removeAll { $0 == a } }
                        save(now: true)
                    }
                }
                if addingAlias {
                    TextField("Also called", text: $alias)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 110)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
                        .focused($focus, equals: .alias)
                        .onSubmit(addAlias)
                        .onExitCommand { addingAlias = false }
                } else {
                    Button { addingAlias = true; focus = .alias } label: {
                        Label(draft.aliases.isEmpty ? "Add an alias" : "Alias", systemImage: "plus")
                            .font(.system(size: 12))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.body)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focus, equals: .notes)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 6)
                if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Notes about \(name)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 84)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .notes ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18)))
            .onChange(of: draft.body) { save(now: false) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .onAppear(perform: load)
        .onChange(of: model.library.generation) { if focus == nil { load() } }
        .onChange(of: focus) { old, new in
            if old == .name, new != .name { renameIfNeeded() }
            if old == .account || old == .notes { save(now: true) }
        }
        .onDisappear { save(now: true) }
    }

    private func load() {
        draft = model.entity(kind, name) ?? Entity(kind: kind, name: name)
        title = draft.name
    }

    private func addAlias() {
        let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty, !draft.aliases.contains(a) { animate { draft.aliases.append(a) } }
        alias = ""
        addingAlias = false
        save(now: true)
    }

    private func renameIfNeeded() {
        let new = Entity.cleanName(title)
        guard !new.isEmpty, new != draft.name else { title = draft.name; return }
        let old = draft.name
        draft.name = new
        model.saveEntity(draft, renamingFrom: old)
    }

    /// Notes save a moment after typing stops; everything else at once.
    private func save(now: Bool) {
        saveTask?.cancel()
        let entity = draft
        guard entity.name == name, entity != model.entity(kind, name) else { return }
        if now { model.saveEntity(entity); return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            model.saveEntity(entity)
        }
    }
}

struct AliasChip: View {
    let text: String
    var onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12))
            if hover {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .help("Remove alias")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}

/// Initials in a soft circle (people) or a building (accounts).
struct Avatar: View {
    let name: String
    let kind: Entity.Kind

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.14))
            if kind == .person {
                Text(initials).font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint)
            } else {
                Image(systemName: "building.2.fill").font(.system(size: 18)).foregroundStyle(.tint)
            }
        }
        .frame(width: 48, height: 48)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A tag's page: the tag and how many calls carry it.
struct TagPage: View {
    let tag: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.listed.count
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14))
                Image(systemName: "number").font(.system(size: 20, weight: .semibold)).foregroundStyle(.tint)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Text(count == 1 ? "1 conversation" : "\(count) conversations")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}
