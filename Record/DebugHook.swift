#if DEBUG
import AppKit
import GlyphCore
import SwiftUI

/// Debug builds only: drive the app from a script without touching the screen, so it
/// can be tested while nobody uses the Mac. Post the distributed notification
/// `dev.fru.jot.mac.app.check` with a command as the object, like `side:person:Sam Lee`,
/// `tab:transcript`, `size:900x600`, `look:dark`, `windows:/tmp/w.json`.
@MainActor
enum DebugHook {
    static func install(_ model: AppModel) {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.fru.jot.mac.app.check"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command, model) }
        }
    }

    static func run(_ command: String, _ model: AppModel) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        let window = NSApp.windows.first { $0.identifier?.rawValue.contains("library") == true } ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 600 }
        NSLog("GlyphJot check: %@", command)

        func link(_ s: String) -> Link? {
            let kv = s.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            return switch kv[0] { case "person": .person(kv[1]); case "account": .account(kv[1]); case "tag": .tag(kv[1]); default: nil }
        }

        switch verb {
        case "side":
            let kv = arg.split(separator: ":", maxSplits: 1).map(String.init)
            switch kv.first ?? "" {
            case "all": model.sidebar = .all
            case "tasks": model.sidebar = .openTasks
            case "notes": model.sidebar = .notes
            case "dictations": model.sidebar = .dictations
            case "folder": model.sidebar = .folder(kv[1])
            default: if let l = link(arg) { model.sidebar = l.sidebarItem }
            }
        case "conv": model.selectedID = arg.isEmpty ? nil : arg
        case "tab": animate { model.tab = DetailTab(rawValue: arg) ?? .summary }
        case "sidebar": model.columns = arg == "hide" ? .detailOnly : .all
        case "list": animate { model.showList = arg != "hide" }
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            guard wh.count == 2, let window else { return }
            var frame = window.frame
            frame.origin.y += frame.height - wh[1]
            frame.size = NSSize(width: wh[0], height: wh[1])
            window.setFrame(frame, display: true, animate: false)
        case "look":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        case "windows":
            let list = NSApp.windows.filter(\.isVisible).map { w in
                ["number": w.windowNumber, "title": w.title, "panel": w is NSPanel, "w": Int(w.frame.width), "h": Int(w.frame.height)] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
                try? data.write(to: URL(filePath: arg))
            }
        case "library": JotWindow.open(activate: false)
        case "front":
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        case "closesettings":
            for w in NSApp.windows where w.isVisible && w !== window && !(w is NSPanel) && w.frame.width > 300 { w.close() }
            window?.makeKeyAndOrderFront(nil)
        case "quickopen": model.quickOpen = arg != "off"
        case "search": model.searchText = arg
        case "settings":
            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let item = menu.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        case "record":
            Task { arg == "stop" ? await model.stopRecording() : await model.startRecording() }
        case "feed": model.debugFeed = arg.isEmpty ? nil : URL(filePath: arg)
        case "pause": arg == "off" ? model.recorder.resume() : model.recorder.pause()
        case "systemaudio": model.includeSystemAudio = arg == "on"
        case "rename": if let id = model.selectedID { model.rename(id, to: arg) }
        case "move": if let id = model.selectedID { model.move(id, to: arg) }
        case "trash": if let id = model.selectedID { model.trash(id) }
        case "copymd": if let id = model.selectedID { model.copyMarkdown(id) }
        case "add": if let id = model.recordingID ?? model.selectedID, let l = link(arg) { model.addLink(l, to: id) }
        case "remove": if let id = model.selectedID, let l = link(arg) { model.removeLink(l, from: id) }
        case "accept", "dismiss": if let id = model.selectedID, let l = link(arg) { model.answer(l, for: id, accept: verb == "accept") }
        case "task":
            let kv = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if let id = model.selectedID, kv.count == 2 { model.setTask(id, ActionItem(text: kv[1]), done: kv[0] == "done") }
        case "process": if let id = model.selectedID { Task { await model.process(id) } }
        case "import": model.importAudio([URL(filePath: arg)])
        case "folder": model.createFolder(arg)
        case "newperson": model.createEntity(.person, arg)
        case "notes":
            if case .person(let n) = model.sidebar, var e = model.entity(.person, n) { e.body = arg; model.saveEntity(e) }
            if case .account(let n) = model.sidebar, var e = model.entity(.account, n) { e.body = arg; model.saveEntity(e) }
        case "banner": model.show(arg.isEmpty ? AIError.unavailable(.appleIntelligenceOff).localizedDescription : arg,
                                  fix: .settings("AppleIntelligence"), for: model.selectedID)
        // A plain text window for the engine to type into (the jot-while-recording test).
        case "scratch": Scratch.show()
        case "scratchtext": try? Scratch.text.write(to: URL(filePath: arg), atomically: true, encoding: .utf8)
        // What the engine would say: "jot:on[:mode]", "jot:off", "jot:thought:<file>".
        case "jot":
            let kv = arg.split(separator: ":", maxSplits: 1).map(String.init)
            switch kv.first ?? "" {
            case "on": model.engineSaid(.init(.jot, mode: kv.count > 1 ? kv[1] : "dictate", on: true))
            case "thought": model.engineSaid(.init(.thought, text: kv.count > 1 ? kv[1] : nil))
            default: model.engineSaid(.init(.jot, on: false))
            }
        case "note": model.openNote = arg; model.sidebar = .notes
        case "state":
            let state: [String: Any] = [
                "sidebar": String(describing: model.sidebar), "selected": model.selectedID ?? "",
                "listed": model.listed.map(\.id), "recording": model.recordingID ?? "",
                "elapsed": model.recorder.elapsed, "stages": model.stages.mapValues(\.help),
                "banners": model.banners.map(\.message), "pasteboard": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(filePath: arg))
            }
        default: break
        }
    }
}
/// The test's typing target: a window with a text view, in focus.
@MainActor
enum Scratch {
    private static var window: NSWindow?
    private static var view: NSTextView?
    static var text: String { view?.string ?? "" }

    static func show() {
        if window == nil {
            let scroll = NSTextView.scrollableTextView()
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Jot test target"
            w.contentView = scroll
            w.isReleasedWhenClosed = false
            window = w
            view = scroll.documentView as? NSTextView
            view?.font = .systemFont(ofSize: 15)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }
}
#endif
