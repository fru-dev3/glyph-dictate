import Foundation
import GlyphCore
import GlyphVault

/// The vault's link (SwiftUI has a Link too).
typealias Link = GlyphVault.Link

/// What typing in an add field can become: a link that exists, or a new one.
struct Candidate: Hashable {
    var link: Link
    var isNew = false
    /// Calls it already has, for known people, accounts and tags.
    var count = 0
}

enum LinkMatcher {
    /// Matches for `text` among the notes and tags, best first, then the ways to make it
    /// new. `#word` means a tag; anything else may be a person, an account or a tag.
    /// Links in `excluding` are left out.
    static func candidates(_ text: String, directory: Vault.Directory, excluding: Set<Link> = []) -> [Candidate] {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTag = raw.hasPrefix("#")
        let query = (isTag ? String(raw.dropFirst()) : raw).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()

        func score(_ names: [String]) -> Int? {
            let lower = names.map { $0.lowercased() }
            if lower.contains(q) { return 0 }
            if lower.contains(where: { $0.hasPrefix(q) }) { return 1 }
            if lower.contains(where: { $0.split(separator: " ").contains { $0.hasPrefix(q) } }) { return 2 }
            if lower.contains(where: { $0.contains(q) }) { return 3 }
            return nil
        }

        var found: [(Int, Candidate)] = []
        if !isTag {
            for row in directory.entities {
                guard let s = score([row.entity.name] + row.entity.aliases) else { continue }
                let link: Link = row.entity.kind == .person ? .person(row.entity.name) : .account(row.entity.name)
                found.append((s, Candidate(link: link, count: row.count)))
            }
        }
        for tag in directory.tags {
            guard let s = score([tag.name]) else { continue }
            found.append((s, Candidate(link: .tag(tag.name), count: tag.count)))
        }
        var out = found.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.count > $1.1.count }.map(\.1)
            .filter { !excluding.contains($0.link) }

        // Making something new, unless that exact name is already offered.
        let exact = out.contains { $0.link.name.lowercased() == q || $0.link.name == tidyTag(query) }
        if !exact {
            if isTag {
                out.append(Candidate(link: .tag(tidyTag(query)), isNew: true))
            } else {
                out.append(Candidate(link: .person(Entity.cleanName(query)), isNew: true))
                out.append(Candidate(link: .account(Entity.cleanName(query)), isNew: true))
                out.append(Candidate(link: .tag(tidyTag(query)), isNew: true))
            }
        }
        return Array(out.prefix(7))
    }

    /// How the vault stores a tag: lower case, words joined with `-`, no `#`.
    static func tidyTag(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }
}

enum Markdown {
    /// A conversation as Markdown to paste anywhere: title, when and who, the notes.
    static func export(_ meta: Conversation, notes: Notes, transcript: Transcript) -> String {
        var out = "# \(meta.title)\n\n"
        var facts = [Format.longDate(meta.created)]
        if meta.durationSec > 0 { facts.append(Format.duration(meta.durationSec)) }
        out += facts.joined(separator: ", ") + "\n"
        let who = meta.people + meta.accounts
        if !who.isEmpty { out += "With " + who.joined(separator: ", ") + "\n" }
        if !meta.tags.isEmpty { out += meta.tags.map { "#" + $0 }.joined(separator: " ") + "\n" }
        if !notes.summary.isEmpty { out += "\n## Summary\n\n\(notes.summary)\n" }
        if !notes.decisions.isEmpty { out += "\n## Decisions\n\n" + notes.decisions.map { "- \($0)\n" }.joined() }
        if !notes.actions.isEmpty {
            out += "\n## Action items\n\n" + notes.actions.map { a in
                var line = "- [\(a.done ? "x" : " ")] \(a.text)"
                let extra = [a.owner, a.due.map { "due \($0)" }].compactMap { $0 }
                if !extra.isEmpty { line += " (" + extra.joined(separator: ", ") + ")" }
                return line + "\n"
            }.joined()
        }
        if notes.summary.isEmpty, notes.actions.isEmpty, !transcript.segments.isEmpty {
            out += "\n## Transcript\n\n" + transcript.plainText
        }
        return out
    }
}

enum Format {
    static func date(_ iso: String) -> Date? { try? Date(iso, strategy: .iso8601) }

    /// "Today 3:12 PM", "Yesterday", "Mon", "Oct 20", "Oct 20, 2025".
    static func shortDate(_ iso: String, now: Date = .now) -> String {
        guard let d = date(iso) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: now).day, days < 6, days >= 0 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        if cal.component(.year, from: d) == cal.component(.year, from: now) {
            return d.formatted(.dateTime.month(.abbreviated).day())
        }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// A due date (`YYYY-MM-DD`): "Today", "Tomorrow", "Oct 29".
    static func due(_ ymd: String, now: Date = .now) -> String {
        guard let d = try? Date(ymd + "T12:00:00Z", strategy: .iso8601) else { return ymd }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return cal.component(.year, from: d) == cal.component(.year, from: now)
            ? d.formatted(.dateTime.month(.abbreviated).day()) : d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func longDate(_ iso: String) -> String {
        guard let d = date(iso) else { return iso }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
    }

    /// "48 s", "12 min", "1 h 5 min".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let m = (seconds + 30) / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "3:07", "1:02:07".
    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
