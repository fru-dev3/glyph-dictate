import AppKit

/// Learns from your fixes: after Jot types into a field, it reads the field again a little
/// later. If you changed one word of what it typed into a similar word ("harbor" to "Harbr"),
/// that word goes in your Dictionary, marked as learned. Nothing leaves the Mac.
@MainActor
enum Learner {
    private static var watching: Task<Void, Never>?

    static func watch(_ field: AXUIElement, pasted: String) {
        stop()
        guard Rules.words(pasted).count >= 3 else { return }
        watching = Task {
            for wait in [5.0, 15, 40] { // seconds between looks, a minute in all
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let value = read(field) else { return }
                if let fix = Rules.correction(pasted: pasted, field: value) {
                    Words.shared.learn(write: fix.write, heard: fix.heard)
                    return
                }
            }
        }
    }

    static func stop() {
        watching?.cancel()
        watching = nil
    }

    private static func read(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
