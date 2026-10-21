import AppKit

/// What the Fn key means, from its presses alone (no timers, no system calls), so it can be
/// checked without a keyboard: `cat Mac/FnKey.swift Mac/FnKeyCheck.swift | swift -`.
/// Hold to talk: Fn down starts, Fn up stops. Double-tap: talk hands-free until the next Fn.
/// A single short tap is dropped once the double-tap window closes.
struct FnGesture {
    enum Action: Equatable { case none, start, stop, cancel }

    static let tapMax = 0.3     // shorter than this is a tap, not a hold
    static let doubleGap = 0.35 // second tap must land this soon after the first

    private(set) var recording = false
    private(set) var locked = false
    private var downAt = 0.0
    private var tapUpAt: Double?

    mutating func fnDown(_ t: Double) -> Action {
        if locked { locked = false; recording = false; return .stop }
        if recording, let up = tapUpAt, t - up <= Self.doubleGap { locked = true; tapUpAt = nil; return .none }
        if recording { downAt = t; tapUpAt = nil; return .none } // late second press: it's a hold now
        recording = true; downAt = t; tapUpAt = nil
        return .start
    }

    mutating func fnUp(_ t: Double) -> Action {
        guard recording, !locked else { return .none }
        if t - downAt >= Self.tapMax { recording = false; return .stop }
        tapUpAt = t // a tap: wait to see if a second one follows
        return .none
    }

    /// Call `doubleGap` after a tap; ends a lone tap.
    mutating func tick(_ t: Double) -> Action {
        guard recording, !locked, let up = tapUpAt, t - up >= Self.doubleGap else { return .none }
        recording = false; tapUpAt = nil
        return .cancel
    }

    /// Esc, or another key while Fn is held (Fn+arrow, Fn+F5): not dictation.
    mutating func cancel(esc: Bool) -> Action {
        guard recording, esc || !locked else { return .none }
        recording = false; locked = false; tapUpAt = nil
        return .cancel
    }
}

/// The key you hold to talk. Fn by default; a right-hand modifier for keyboards without
/// Fn, or while another app still owns Fn. Chosen in the menu, kept in UserDefaults.
enum TalkKey: String, CaseIterable {
    case fn, rightOption, rightCommand, rightControl

    static var current: TalkKey {
        get { UserDefaults.standard.string(forKey: "talkKey").flatMap(TalkKey.init) ?? .fn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "talkKey") }
    }

    var name: String {
        switch self {
        case .fn: "Fn (Globe)"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        }
    }

    var keycode: Int64 { switch self { case .fn: 63; case .rightOption: 61; case .rightCommand: 54; case .rightControl: 62 } }

    /// The modifier that makes a dictation Command Mode, and the one that asks your history.
    var commandFlag: CGEventFlags { self == .rightControl ? .maskCommand : .maskControl }
    var askFlag: CGEventFlags { self == .rightOption ? .maskCommand : .maskAlternate }

    var commandName: String { self == .rightControl ? "Command" : "Control" }
    var askName: String { self == .rightOption ? "Command" : "Option" }

    var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        }
    }
}

/// What a dictation does with its words, from the modifiers held with the talk key at any
/// point while talking: Shift saves a thought to the vault, Control runs Command Mode on the
/// selected text, Option asks your past dictations, nothing types where you are. A talk key
/// that is itself one of those moves its job to Command.
enum Mode { case dictate, thought, command, ask }

/// Listens (never blocks) for the talk key and Esc system-wide. Needs Input Monitoring.
final class FnKey {
    private var gesture = FnGesture()
    private var tap: CFMachPort?
    private var fnHeld = false
    private var held = CGEventFlags() // modifiers seen since this dictation started
    private let onAction: (FnGesture.Action, Mode) -> Void

    init(onAction: @escaping (FnGesture.Action, Mode) -> Void) { self.onAction = onAction }

    private var mode: Mode {
        if held.contains(TalkKey.current.commandFlag) { return .command }
        if held.contains(TalkKey.current.askFlag) { return .ask }
        if held.contains(.maskShift) { return .thought }
        return .dictate
    }

    var locked: Bool { gesture.locked }

    /// False when Input Monitoring hasn't been granted yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, me in
            Unmanaged<FnKey>.fromOpaque(me!).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged where event.getIntegerValueField(.keyboardEventKeycode) == TalkKey.current.keycode:
            let down = event.flags.contains(TalkKey.current.flag)
            guard down != fnHeld else { return }
            fnHeld = down
            if down {
                let action = gesture.fnDown(now)
                if action == .start { held = event.flags }
                onAction(action, mode)
            } else {
                onAction(gesture.fnUp(now), mode)
                DispatchQueue.main.asyncAfter(deadline: .now() + FnGesture.doubleGap + 0.02) { [self] in
                    onAction(gesture.tick(ProcessInfo.processInfo.systemUptime), mode)
                }
            }
        case .flagsChanged where gesture.recording: // Shift or Control joining while you talk
            held.formUnion(event.flags)
            onAction(.none, mode)
        case .keyDown:
            let esc = event.getIntegerValueField(.keyboardEventKeycode) == 53
            if esc || fnHeld { onAction(gesture.cancel(esc: esc), mode) }
        default:
            break
        }
    }
}
