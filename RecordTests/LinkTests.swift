import Foundation
import GlyphCore
import Testing
@testable import GlyphJot

/// The pipe between Glyph Jot and its dictation engine.
struct LinkTests {
    @Test func messagesSurviveTheLineAndStrayOutputIsIgnored() {
        let m = LinkMessage(.jot, mode: "thought", on: true, at: 1_792_958_000.25)
        var buffer = LineBuffer()
        let half = Data(m.line.utf8)
        // A log line, then the message split across two reads.
        var lines = buffer.feed(Data("speech: ready\n".utf8) + half.prefix(10))
        #expect(lines.compactMap(LinkMessage.parse).isEmpty)
        lines = buffer.feed(half.dropFirst(10))
        #expect(lines.compactMap(LinkMessage.parse) == [m])
        #expect(LinkMessage.parse("{\"kind\":\"quit\"}") == nil) // no marker, not a message
    }

    /// Jot while recording: the jot's stretch and its note land in the conversation, and the
    /// transcript loses what was said in it (must-pass, decision d-mvo8wkr4).
    @MainActor @Test func jotsDuringARecordingAreRecordedAndKeptPrivate() async throws {
        let model = AppModel.shared
        let setting = savedRecordingsPath()
        defer { #expect(savedRecordingsPath() == setting, "a test changed the installed app's recordings folder") }
        let root = FileManager.default.temporaryDirectory.appending(path: "glyph-jot-tests-\(UUID().uuidString)")
        model.switchVault(to: root, remember: false)
        model.debugFeed = nil
        // A recording fed silence through the test path, so no microphone is needed.
        let meta = try model.vault.createConversation(in: "Recordings", title: "Sync")
        try model.testBegin(meta.id)
        model.engineSaid(.init(.jot, mode: "dictate", on: true))
        model.engineSaid(.init(.jot, on: false))
        model.engineSaid(.init(.jot, mode: "thought", on: true))
        model.engineSaid(.init(.thought, text: "2026-10-25 10-00-02.md"))
        model.engineSaid(.init(.jot, on: false))
        #expect(model.jots.count == 2)
        #expect(model.jots[1].note == "2026-10-25 10-00-02.md" && model.jots[1].kind == "thought")
        await model.stopRecording()
        let saved = try model.vault.conversation(meta.id)
        #expect(saved.jots.count == 2)
        #expect(model.recordingFor(note: "2026-10-25 10-00-02.md")?.0 == meta.id)
        try? FileManager.default.removeItem(at: root)
    }

    /// The test host is Jot.app with the installed app's settings (one bundle id): pointing it
    /// at a test folder must never reach them. Once it did, and Fru's recordings went to /tmp.
    @MainActor @Test func switchingVaultsInATestNeverSavesTheFolder() {
        let saved = savedRecordingsPath()
        let root = FileManager.default.temporaryDirectory.appending(path: "glyph-jot-tests-\(UUID().uuidString)")
        AppModel.shared.switchVault(to: root) // even asked to remember
        #expect(AppModel.testHost)
        #expect(savedRecordingsPath() == saved)
    }
}

/// The saved setting itself (not the -recordingsPath argument a test may pass).
func savedRecordingsPath() -> String? {
    UserDefaults.standard.persistentDomain(forName: "dev.fru.jot.mac")?["recordingsPath"] as? String
}
