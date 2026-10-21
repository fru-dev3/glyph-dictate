import AppKit
import Carbon.HIToolbox

/// Fill a whole form by voice: "fill the form, name Sam Lee, city Austin, email sam at
/// example dot com". Jot reads the form's fields through Accessibility (the field you're in
/// and every text field around it on the page), the on-device model matches what you said
/// to them, and Jot types each value into its field. Password fields are never touched.
enum FormFill {
    struct Field {
        let element: AXUIElement
        let label: String
    }

    @MainActor
    static func run(_ said: String, app: NSRunningApplication?) async throws -> Int {
        // A browser builds a page's accessibility tree only once something asks for it, so the
        // first look at a freshly opened page can come back empty: look again.
        var fields = Self.fields(in: app)
        for _ in 0..<3 where fields.isEmpty {
            try? await Task.sleep(for: .milliseconds(400))
            fields = Self.fields(in: app)
        }
        log.info("form: \(fields.count) fields")
        guard !fields.isEmpty else { throw JotError("No form here. Click into the form's first field, then try again.") }
        let plan = try await AI.fill(said, labels: fields.map(\.label))
        let saved = Clipboard.save()
        let pb = NSPasteboard.general
        var filled = 0
        for value in plan where fields.indices.contains(value.field) && !value.value.isEmpty {
            let field = fields[value.field].element
            let text = Self.normalCase(value.value)
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(120))
            // Typed like a paste, so web forms see the change (setting the value directly can be ignored).
            Paste.press(kVK_ANSI_A, .maskCommand)
            pb.clearContents()
            pb.setString(text, forType: .string)
            Paste.press(kVK_ANSI_V, .maskCommand)
            try? await Task.sleep(for: .milliseconds(150))
            filled += 1
        }
        try? await Task.sleep(for: .milliseconds(300))
        Clipboard.restore(saved)
        return filled
    }

    /// Emails are lowercase ("Sam@example.com" from speech), and shouting is undone ("SAM LEE"
    /// becomes "Sam Lee").
    static func normalCase(_ value: String) -> String {
        if value.contains("@"), !value.contains(" ") { return value.lowercased() }
        guard value.contains(where: \.isLetter), value == value.uppercased() else { return value }
        return value.capitalized
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// The text fields of the form you're in, in page order, each with the best label found:
    /// its title element, description, title, placeholder, or the text just before it.
    static func fields(in app: NSRunningApplication?) -> [Field] {
        guard let focused = Paste.focusedElement(in: app), let root = form(around: focused) else { return [] }
        var fields: [Field] = []
        var lastText = ""
        var seen = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard seen < 4000, depth < 60 else { return }
            seen += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXStaticText", let text = string(element, kAXValueAttribute), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lastText = text
            }
            if textRoles.contains(role), string(element, kAXSubroleAttribute) != "AXSecureTextField" {
                let label = [title(of: element), string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute),
                             string(element, kAXPlaceholderValueAttribute), lastText]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "field"
                fields.append(Field(element: element, label: label))
                lastText = ""
                return
            }
            for child in children(element) { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        log.info("form: looked at \(seen) elements under \(string(root, kAXRoleAttribute) ?? "?", privacy: .public)")
        return fields
    }

    /// The web page in the field's window (the address bar is never a form field), or else the
    /// window itself. Found from the window down: climbing up from a field inside the page
    /// lands on a web area whose children come back empty in Safari.
    private static func form(around element: AXUIElement) -> AXUIElement? {
        var window = Self.element(element, kAXWindowAttribute)
        var current: AXUIElement? = element
        while window == nil, let e = current {
            if string(e, kAXRoleAttribute) == "AXWindow" { window = e }
            current = parent(of: e)
        }
        guard let window else { return nil }
        return webArea(in: window) ?? window
    }

    /// The first web page inside a window, breadth first.
    private static func webArea(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var seen = 0
        while !queue.isEmpty, seen < 2000 {
            let e = queue.removeFirst()
            seen += 1
            if string(e, kAXRoleAttribute) == "AXWebArea" { return e }
            queue += children(e)
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func parent(of e: AXUIElement) -> AXUIElement? { element(e, kAXParentAttribute) }

    private static func title(of e: AXUIElement) -> String? {
        element(e, kAXTitleUIElementAttribute).flatMap { string($0, kAXValueAttribute) ?? string($0, kAXTitleAttribute) }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
