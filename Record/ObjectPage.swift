import GlyphCore
import SwiftUI

/// A Glyph Studio object's page over what Glyph Jot filed under it: its name, Studio's word
/// for it, its aliases and how many recordings and notes. Read only: Studio edits it.
struct ObjectPage: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let kind = StudioObject.Kind(id: id) ?? .person
        let object = model.studio.object(id)
        let name = model.studio.name(id)
        let recordings = model.listed.count
        let notes = model.notes(for: .object(id)).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Avatar(name: name, kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(CountLine.text(kind.singular + (object == nil ? ", no longer in Glyph Studio" : ""), recordings: recordings, notes: notes))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let aliases = object?.aliases, !aliases.isEmpty {
                FlowLayout(spacing: 5) {
                    Text("Also").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 22)
                    ForEach(aliases, id: \.self) { a in
                        Text(a).font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// "Person · 3 recordings · 1 note".
enum CountLine {
    static func text(_ lead: String, recordings: Int, notes: Int) -> String {
        var parts = [lead]
        if recordings > 0 { parts.append(recordings == 1 ? "1 recording" : "\(recordings) recordings") }
        if notes > 0 { parts.append(notes == 1 ? "1 note" : "\(notes) notes") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Initials in a soft circle (people), or the kind's icon.
struct Avatar: View {
    let name: String
    let kind: StudioObject.Kind

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.14))
            if kind == .person {
                Text(initials).font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint)
            } else {
                Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(.tint)
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
        let recordings = model.listed.count
        let notes = model.notes(for: .tag(tag)).count
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14))
                Image(systemName: "number").font(.system(size: 20, weight: .semibold)).foregroundStyle(.tint)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Text(CountLine.text("Tag", recordings: recordings, notes: notes))
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
