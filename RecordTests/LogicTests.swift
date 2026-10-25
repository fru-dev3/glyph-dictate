import Foundation
import GlyphCore
import Testing
@testable import GlyphJot

@MainActor
struct LogicTests {
    let directory: Vault.Directory

    /// A throwaway vault with made-up names, read back through the public API.
    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "glyph-record-tests-\(UUID().uuidString)")
        let vault = Vault(root: root)
        try vault.ensure()
        var sam = Entity(kind: .person, name: "Sam Lee")
        sam.aliases = ["Sammy"]
        try vault.saveEntity(sam)
        try vault.saveEntity(Entity(kind: .person, name: "Kim Park"))
        try vault.saveEntity(Entity(kind: .account, name: "Acme"))
        let a = try vault.createConversation(in: "Work", title: "One")
        _ = try vault.setLinks(a.id, people: ["Sam Lee"], accounts: ["Acme"], tags: ["pricing", "q4-planning"])
        let b = try vault.createConversation(in: "Work", title: "Two")
        _ = try vault.setLinks(b.id, people: [], accounts: [], tags: ["pricing"])
        directory = vault.directory()
    }

    @Test func findsByNameAliasAndWord() {
        #expect(LinkMatcher.candidates("sam", directory: directory).first?.link == .person("Sam Lee"))
        #expect(LinkMatcher.candidates("sammy", directory: directory).first?.link == .person("Sam Lee"))
        #expect(LinkMatcher.candidates("park", directory: directory).first?.link == .person("Kim Park"))
        #expect(LinkMatcher.candidates("ac", directory: directory).first?.link == .account("Acme"))
    }

    @Test func hashMeansTag() {
        let c = LinkMatcher.candidates("#pri", directory: directory)
        #expect(c.first?.link == .tag("pricing"))
        #expect(c.allSatisfy { if case .tag = $0.link { true } else { false } })
        #expect(LinkMatcher.candidates("#Q4 Budget", directory: directory).last == Candidate(link: .tag("q4-budget"), isNew: true))
    }

    @Test func offersNewOnlyWhenNotExact() {
        #expect(!LinkMatcher.candidates("Acme", directory: directory).contains { $0.isNew })
        let new = LinkMatcher.candidates("Pat Doe", directory: directory).filter(\.isNew).map(\.link)
        #expect(new == [.person("Pat Doe"), .account("Pat Doe"), .tag("pat-doe")])
    }

    @Test func excludesLinked() {
        #expect(!LinkMatcher.candidates("sam", directory: directory, excluding: [.person("Sam Lee")]).contains { $0.link == .person("Sam Lee") })
    }

    @Test func markdownExport() {
        var meta = Conversation(id: "Work/2026-10-20-sync", title: "Sync", created: "2026-10-20T15:00:00Z")
        meta.durationSec = 1_500
        meta.people = ["Sam Lee"]
        meta.tags = ["pricing"]
        let notes = Notes(summary: "We held the price.", decisions: ["Hold it"], actions: [ActionItem(text: "Send the form", owner: "Sam Lee", due: "2026-10-24")])
        let md = Markdown.export(meta, notes: notes, transcript: Transcript())
        #expect(md.hasPrefix("# Sync\n\n"))
        #expect(md.contains("With Sam Lee\n#pricing\n"))
        #expect(md.contains("## Decisions\n\n- Hold it\n"))
        #expect(md.contains("- [ ] Send the form (Sam Lee, due 2026-10-24)\n"))
        #expect(!md.contains("\u{2014}"))
    }

    @Test func durations() {
        #expect(Format.duration(48) == "48 s")
        #expect(Format.duration(25 * 60) == "25 min")
        #expect(Format.duration(65 * 60) == "1 h 5 min")
        #expect(Format.clock(187) == "3:07")
        #expect(Format.clock(3727) == "1:02:07")
    }
}
