import GlyphCore
import SwiftUI

/// Command-K: type a few letters, jump to a conversation, person, account, tag or folder.
struct QuickOpen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    @State private var contentHits: [String] = []
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        var id: String
        var title: String
        var detail: String
        var symbol: String
        var open: @MainActor (AppModel) -> Void
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let convs = model.library.conversations
        var out: [Hit] = []
        func conv(_ c: Conversation) -> Hit {
            Hit(id: "c:" + c.id, title: c.title, detail: Format.shortDate(c.created), symbol: "waveform") { m in
                if !m.listed.contains(where: { $0.id == c.id }) { m.sidebar = .all }
                m.selectedID = c.id
            }
        }
        if q.isEmpty { return convs.prefix(8).map(conv) }
        out += convs.filter { $0.title.lowercased().contains(q) }.prefix(6).map(conv)
        for row in model.library.directory.entities where ([row.entity.name] + row.entity.aliases).contains(where: { $0.lowercased().contains(q) }) {
            let e = row.entity
            out.append(Hit(id: "e:\(e.kind):\(e.name)", title: e.name, detail: e.kind == .person ? "Person" : "Account",
                           symbol: e.kind == .person ? "person" : "building.2") { m in
                m.sidebar = e.kind == .person ? .person(e.name) : .account(e.name)
            })
        }
        for t in model.library.directory.tags where t.name.contains(q) {
            out.append(Hit(id: "t:" + t.name, title: "#" + t.name, detail: "Tag", symbol: "number") { $0.sidebar = .tag(t.name) })
        }
        for f in model.folders where f.lowercased().contains(q) {
            out.append(Hit(id: "f:" + f, title: f, detail: "Folder", symbol: "folder") { $0.sidebar = .folder(f) })
        }
        let shown = Set(out.map(\.id))
        out += contentHits.compactMap { id in convs.first { $0.id == id } }.map(conv)
            .filter { !shown.contains($0.id) }
            .map { var h = $0; h.detail = "Mentions \u{201C}\(query)\u{201D}"; return h }
        return Array(out.prefix(12))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
                    TextField("Go to a conversation, person, account or tag", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .onSubmit(openHighlighted)
                        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, hits.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, 18)
                .frame(height: 54)
                if !hits.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                                row(h, on: i == highlighted)
                                    .onTapGesture { h.open(model); close() }
                                    .onHover { if $0 { highlighted = i } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
            .padding(.top, 70)
        }
        .onAppear { focused = true }
        .onChange(of: query) {
            highlighted = 0
            let q = query
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard q == query else { return }
                contentHits = q.count > 2 ? await model.library.search(q) : []
            }
        }
    }

    private func row(_ h: Hit, on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: h.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            Text(h.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer(minLength: 12)
            Text(h.detail).font(.system(size: 12.5)).lineLimit(1)
                .foregroundStyle(on ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(on ? .white : .primary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func openHighlighted() {
        let list = hits
        guard list.indices.contains(highlighted) else { return }
        list[highlighted].open(model)
        close()
    }

    private func close() { model.quickOpen = false }
}
