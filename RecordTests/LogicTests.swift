import Foundation
import GlyphCore
import Testing
@testable import GlyphJot

@MainActor
struct LogicTests {
    let studio = StudioDirectory(objects: [
        StudioObject(id: "person/sam-lee", name: "Sam Lee", aliases: ["Sammy"], kind: .person),
        StudioObject(id: "person/kim-park", name: "Kim Park", kind: .person),
        StudioObject(id: "org/acme", name: "Acme", kind: .product),
        StudioObject(id: "org/globex", name: "Globex", kind: .product),
        StudioObject(id: "domain/career", name: "Career", kind: .domain),
    ])
    let counts = (objects: ["person/sam-lee": 3, "org/acme": 1], tags: ["pricing": 2, "q4-planning": 1])

    @Test func findsStudioObjectsByNameAliasAndWord() {
        #expect(LinkMatcher.candidates("sam", studio: studio, counts: counts).first?.link == .object("person/sam-lee"))
        #expect(LinkMatcher.candidates("sammy", studio: studio, counts: counts).first?.link == .object("person/sam-lee"))
        #expect(LinkMatcher.candidates("park", studio: studio, counts: counts).first?.link == .object("person/kim-park"))
        #expect(LinkMatcher.candidates("glob", studio: studio, counts: counts).first?.link == .object("org/globex"))
        #expect(LinkMatcher.candidates("care", studio: studio, counts: counts).first?.link == .object("domain/career"))
        #expect(LinkMatcher.candidates("sam", studio: studio, counts: counts).first?.count == 3)
    }

    @Test func hashMeansTag() {
        let c = LinkMatcher.candidates("#pri", studio: studio, counts: counts)
        #expect(c.first?.link == .tag("pricing"))
        #expect(c.allSatisfy { if case .tag = $0.link { true } else { false } })
        #expect(LinkMatcher.candidates("#Q4 Budget", studio: studio, counts: counts).last == Candidate(link: .tag("q4-budget"), isNew: true))
    }

    @Test func offersNewPersonOrProductOnlyWhenNotExact() {
        #expect(!LinkMatcher.candidates("Acme", studio: studio, counts: counts).contains { $0.isNew })
        #expect(!LinkMatcher.candidates("sammy", studio: studio, counts: counts).contains { $0.isNew }, "an alias is exact too")
        let new = LinkMatcher.candidates("Pat Doe", studio: studio, counts: counts).filter(\.isNew).map(\.link)
        #expect(new == [.person("Pat Doe"), .account("Pat Doe"), .tag("pat-doe")])
        #expect(new.map(\.kindName) == ["person", "product", "tag"], "Studio's words, never account")
    }

    @Test func excludesLinked() {
        #expect(!LinkMatcher.candidates("sam", studio: studio, counts: counts, excluding: [.object("person/sam-lee")]).contains { $0.link == .object("person/sam-lee") })
    }

    @Test func notesKeepTheirFrontMatterWhenFiled() {
        let raw = "---\ndate: 2026-10-25T12:08:24\ntags: []\nkind: voice\ndevice: iPhone\n---\n\nCall Sam about Acme.\n"
        let filed = JotNote.withFields(raw, ["links": ["person/sam-lee", "org/acme"], "tags": ["pricing"]])
        #expect(filed == "---\ndate: 2026-10-25T12:08:24\ntags: [pricing]\nkind: voice\ndevice: iPhone\nlinks: [person/sam-lee, org/acme]\n---\n\nCall Sam about Acme.\n")
        #expect(JotNote.withFields(filed, ["links": [], "tags": []]) == raw, "taking every link off leaves the note as it was")
        #expect(JotNote.withFields("Just text", ["links": ["domain/career"], "tags": []]) == "---\nlinks: [domain/career]\ntags: []\n---\n\nJust text")
        let url = FileManager.default.temporaryDirectory.appending(path: "jot-note-\(UUID().uuidString).md")
        try? filed.write(to: url, atomically: true, encoding: .utf8)
        let note = JotNote.read(url)
        #expect(note?.links == ["person/sam-lee", "org/acme"] && note?.tags == ["pricing"] && note?.text == "Call Sam about Acme.")
    }

    @Test func markdownExport() {
        var meta = Conversation(id: "Work/2026-10-20-sync", title: "Sync", created: "2026-10-20T15:00:00Z")
        meta.durationSec = 1_500
        meta.links = ["person/sam-lee"]
        meta.tags = ["pricing"]
        let notes = Notes(summary: "We held the price.", decisions: ["Hold it"], actions: [ActionItem(text: "Send the form", owner: "Sam Lee", due: "2026-10-24")])
        let md = Markdown.export(meta, notes: notes, transcript: Transcript(), studio: studio)
        #expect(md.hasPrefix("# Sync\n\n"))
        #expect(md.contains("Filed under Sam Lee\n#pricing\n"))
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
