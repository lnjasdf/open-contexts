@preconcurrency import ApplicationServices
import AppKit
import Combine

struct KeyboardShortcut: Codable, Equatable {
    static let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    /// Shift counts for the reverse switch key only; the keys that open a switcher may not carry it.
    static let reverseModifierMask: CGEventFlags = modifierMask.union(.maskShift)
    /// Left and right Shift arrive as flagsChanged, not keyDown, so a Shift tap is stored as the left key.
    static let shiftKeyCode: UInt16 = 56
    static let shiftKeyCodes: Set<UInt16> = [56, 60]
    static let allWindows = KeyboardShortcut(keyCode: 48, modifiers: .maskCommand, keyLabel: "Tab")
    static let currentApp = KeyboardShortcut(keyCode: 50, modifiers: .maskCommand, keyLabel: "`")
    static let reverse = KeyboardShortcut(keyCode: shiftKeyCode, modifiers: .maskCommand, keyLabel: "⇧")

    let keyCode: UInt16
    let modifierRawValue: UInt64
    let keyLabel: String

    init(keyCode: UInt16, modifiers: CGEventFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifierRawValue = modifiers.rawValue
        self.keyLabel = keyLabel
    }

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRawValue) }
    var isShiftTap: Bool { keyCode == Self.shiftKeyCode }
    var isValid: Bool { isValid(allowingShift: false) }
    func isValid(allowingShift: Bool) -> Bool {
        keyCode < 128 && (allowingShift && isShiftTap || keyCode != 53 && !(54...63).contains(keyCode))
            && !modifiers.isEmpty && modifiers.subtracting(Self.mask(allowingShift: allowingShift)).isEmpty
            && !keyLabel.isEmpty && keyLabel.count <= 20
    }
    var display: String {
        (modifiers.contains(.maskControl) ? "⌃" : "")
            + (modifiers.contains(.maskAlternate) ? "⌥" : "")
            + (modifiers.contains(.maskCommand) ? "⌘" : "")
            + (modifiers.contains(.maskShift) && !isShiftTap ? "⇧" : "") + keyLabel
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && flags.intersection(Self.reverseModifierMask) == modifiers
    }

    /// A Shift tap fires while every modifier the shortcut records stays down.
    func matchesShiftTap(flags: CGEventFlags) -> Bool {
        isShiftTap && flags.contains(.maskShift) && modifiers.isSubset(of: flags)
    }

    func conflicts(with other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && modifierRawValue == other.modifierRawValue
    }

    private static func mask(allowingShift: Bool) -> CGEventFlags {
        allowingShift ? reverseModifierMask : modifierMask
    }

    init?(event: NSEvent, allowingShift: Bool = false) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        if event.type == .flagsChanged {
            guard allowingShift, Self.shiftKeyCodes.contains(event.keyCode), flags.contains(.maskShift) else {
                return nil
            }
            self.init(keyCode: Self.shiftKeyCode, modifiers: flags.intersection(Self.modifierMask), keyLabel: "⇧")
            guard isValid(allowingShift: true) else { return nil }
            return
        }
        guard allowingShift || !flags.contains(.maskShift) else { return nil }
        let names: [UInt16: String] = [
            36: "↩", 48: "Tab", 49: "Space", 51: "⌫", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
        ]
        let functionKeys: [UInt16: Int] = [
            122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9,
            109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
        ]
        let label = names[event.keyCode] ?? functionKeys[event.keyCode].map { "F\($0)" }
            ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        self.init(keyCode: event.keyCode, modifiers: flags.intersection(Self.reverseModifierMask), keyLabel: label)
        guard isValid(allowingShift: allowingShift) else { return nil }
    }
}

enum SwitcherAction: Equatable {
    case begin(currentAppOnly: Bool)
    case step(Int)
    case search(String)
    case commit
    case cancel
}

enum ShortcutScope: String, Equatable, CaseIterable {
    case allWindows, currentApp, reverse

    var labelKey: String {
        switch self {
        case .allWindows: "All windows"
        case .currentApp: "Current app windows"
        case .reverse: "Reverse switch"
        }
    }

    var defaultsKey: String {
        switch self {
        case .allWindows: "allWindowsShortcut"
        case .currentApp: "currentAppShortcut"
        case .reverse: "reverseShortcut"
        }
    }

    var allowsShift: Bool { self == .reverse }

    var defaultShortcut: KeyboardShortcut {
        switch self {
        case .allWindows: .allWindows
        case .currentApp: .currentApp
        case .reverse: .reverse
        }
    }
}

private struct ShortcutState {
    private(set) var isSwitching = false
    private(set) var heldModifiers: CGEventFlags = []
    private(set) var searchQuery = ""

    mutating func begin(currentAppOnly: Bool, allowed: Bool,
                        modifiers: CGEventFlags = .maskCommand) -> SwitcherAction? {
        guard !isSwitching, allowed else { return nil }
        isSwitching = true
        heldModifiers = modifiers
        searchQuery = ""
        return .begin(currentAppOnly: currentAppOnly)
    }

    mutating func step(_ amount: Int) -> SwitcherAction? {
        isSwitching ? .step(amount) : nil
    }

    mutating func appendToSearch(_ characters: String) -> SwitcherAction? {
        guard isSwitching, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else { return nil }
        searchQuery += characters
        return .search(searchQuery)
    }

    mutating func deleteFromSearch() -> SwitcherAction? {
        guard isSwitching else { return nil }
        if !searchQuery.isEmpty { searchQuery.removeLast() }
        return .search(searchQuery)
    }

    mutating func finish(commit: Bool) -> SwitcherAction? {
        guard isSwitching else { return nil }
        isSwitching = false
        heldModifiers = []
        searchQuery = ""
        return commit ? .commit : .cancel
    }
}

@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var recordingScope: ShortcutScope?
    @Published private(set) var recordingErrorKey: String?
    var onAction: ((SwitcherAction) -> Void)?
    var canBegin: ((Bool) -> Bool)?
    private(set) var allWindowsShortcut = KeyboardShortcut.allWindows
    private(set) var currentAppShortcut = KeyboardShortcut.currentApp
    private(set) var reverseShortcut = KeyboardShortcut.reverse

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var state = ShortcutState()
    private var shiftIsHeld = false
    private var recordingMonitor: Any?
    private var saveRecording: ((KeyboardShortcut) -> Bool)?

    func configure(allWindows: KeyboardShortcut, currentApp: KeyboardShortcut, reverse: KeyboardShortcut) {
        guard allWindows.isValid, currentApp.isValid, reverse.isValid(allowingShift: true),
              !allWindows.conflicts(with: currentApp), !allWindows.conflicts(with: reverse),
              !currentApp.conflicts(with: reverse),
              allWindows != allWindowsShortcut || currentApp != currentAppShortcut
                  || reverse != reverseShortcut else { return }
        if let action = state.finish(commit: false) { onAction?(action) }
        allWindowsShortcut = allWindows
        currentAppShortcut = currentApp
        reverseShortcut = reverse
    }

    func beginRecording(scope: ShortcutScope, onSave: @escaping (KeyboardShortcut) -> Bool) {
        cancelRecording()
        if let action = state.finish(commit: false) { onAction?(action) }
        recordingScope = scope
        saveRecording = onSave
        // A Shift tap only arrives as flagsChanged, which the reverse key accepts.
        let monitored: NSEvent.EventTypeMask = scope.allowsShift ? [.keyDown, .flagsChanged] : .keyDown
        // Also records in Settings before Accessibility permission is granted.
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: monitored) { [weak self] event in
            let captured = MainActor.assumeIsolated {
                guard let self, self.recordingScope != nil else { return false }
                self.record(event)
                return true
            }
            return captured ? nil : event
        }
    }

    func cancelRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        saveRecording = nil
        recordingScope = nil
        recordingErrorKey = nil
    }

    private func record(_ event: NSEvent) {
        // isARepeat only answers for keyDown and keyUp; a Shift tap arrives as flagsChanged.
        let isRepeat = event.type == .keyDown && event.isARepeat
        guard let scope = recordingScope, !isRepeat else { return }
        if event.type == .flagsChanged {
            // Only a Shift press can stand in as the reverse key; other modifier transitions are composing noise.
            guard KeyboardShortcut.shiftKeyCodes.contains(event.keyCode), event.modifierFlags.contains(.shift) else {
                return
            }
        }
        if event.keyCode == 53 {
            cancelRecording()
        } else if let shortcut = KeyboardShortcut(event: event, allowingShift: scope.allowsShift) {
            if saveRecording?(shortcut) == true {
                cancelRecording()
            } else {
                recordingErrorKey = "The shortcuts must be different."
            }
        } else {
            recordingErrorKey = scope.allowsShift
                ? "Use Command, Option, Control, or Shift with a key."
                : "Use Command, Option, or Control with a key."
        }
    }

    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if let eventTap {
            // The tap survives transient trust loss or session switches; re-enable it instead of no-op.
            CGEvent.tapEnable(tap: eventTap, enable: true)
            isRunning = true
            return true
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: shortcutEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        observeSessionChanges()
        return true
    }

    func stop() {
        cancelRecording()
        if let action = state.finish(commit: false) { onAction?(action) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    func resetState() {
        _ = state.finish(commit: false)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let action = state.finish(commit: false) { emit(action, deferred: true) }
            if AXIsProcessTrusted(), let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard AXIsProcessTrusted() else {
            if let action = state.finish(commit: false) { emit(action, deferred: true) }
            isRunning = false
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if type == .flagsChanged {
            let pressedShift = flags.contains(.maskShift) && !shiftIsHeld
            shiftIsHeld = flags.contains(.maskShift)
            let action = reverseShiftAction(flags: flags, pressedShift: pressedShift) ?? modifierAction(flags: flags)
            if let action { emit(action, deferred: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        shiftIsHeld = flags.contains(.maskShift)

        if recordingScope != nil {
            // Defer AppKit/UI work until after the event tap returns, and swallow even ⌘Tab.
            if let keyEvent = NSEvent(cgEvent: event) {
                DispatchQueue.main.async { [weak self] in self?.record(keyEvent) }
            }
            return nil
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard onAction != nil else { return Unmanaged.passUnretained(event) }
        let characters = state.isSwitching ? NSEvent(cgEvent: event).flatMap(Self.searchCharacters) : nil
        guard let action = keyAction(keyCode: keyCode, flags: flags, characters: characters) else {
            // No key commands may reach the frontmost app while the switcher owns input.
            return state.isSwitching ? nil : Unmanaged.passUnretained(event)
        }
        emit(action, deferred: true)
        return nil
    }

    private func modifierAction(flags: CGEventFlags) -> SwitcherAction? {
        guard state.isSwitching, !flags.contains(state.heldModifiers) else { return nil }
        return state.finish(commit: true)
    }

    /// Tapping Shift inside an open switcher steps back; holding or releasing it does nothing.
    private func reverseShiftAction(flags: CGEventFlags, pressedShift: Bool) -> SwitcherAction? {
        guard pressedShift, state.isSwitching, reverseShortcut.matchesShiftTap(flags: flags) else { return nil }
        return state.step(-1)
    }

    private static func searchCharacters(_ event: NSEvent) -> String? {
        event.characters(byApplyingModifiers: event.modifierFlags.intersection([.shift, .capsLock]))
    }

    private func keyAction(keyCode: UInt16, flags: CGEventFlags, characters: String? = nil) -> SwitcherAction? {
        if state.isSwitching {
            if reverseShortcut.matches(keyCode: keyCode, flags: flags) {
                return state.step(-1)
            }
            if state.searchQuery.isEmpty,
               allWindowsShortcut.matches(keyCode: keyCode, flags: flags)
                || currentAppShortcut.matches(keyCode: keyCode, flags: flags) {
                return state.step(1)
            }
            switch keyCode {
            case 48, 50:
                return flags.contains(.maskShift) ? nil : state.step(1)
            case 126:
                return state.step(-1)
            case 125:
                return state.step(1)
            case 51:
                return state.deleteFromSearch()
            case 53:
                return state.finish(commit: false)
            default:
                return characters.flatMap { state.appendToSearch($0) }
            }
        }

        let currentAppOnly: Bool
        let shortcut: KeyboardShortcut
        if allWindowsShortcut.matches(keyCode: keyCode, flags: flags) {
            currentAppOnly = false
            shortcut = allWindowsShortcut
        } else if currentAppShortcut.matches(keyCode: keyCode, flags: flags) {
            currentAppOnly = true
            shortcut = currentAppShortcut
        } else {
            // The reverse key steps inside an open switcher; it never opens one.
            return nil
        }

        return state.begin(
            currentAppOnly: currentAppOnly,
            allowed: canBegin?(currentAppOnly) ?? true,
            modifiers: shortcut.modifiers
        )
    }

    private func emit(_ action: SwitcherAction, deferred: Bool) {
        guard deferred else {
            onAction?(action)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }

    private func observeSessionChanges() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.cancelRecording()
                    if let action = self.state.finish(commit: false) { self.onAction?(action) }
                    if let eventTap = self.eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
                    self.isRunning = false
                }
            },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard AXIsProcessTrusted(), let eventTap = self?.eventTap else { return }
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                    self?.isRunning = true
                }
            }
        ]
    }

    static func selfCheck() -> Bool {
        var state = ShortcutState()
        guard KeyboardShortcut.allWindows.display == "⌘Tab",
              KeyboardShortcut.currentApp.display == "⌘`",
              KeyboardShortcut.reverse.display == "⌘⇧", KeyboardShortcut.reverse.isShiftTap,
              KeyboardShortcut(keyCode: 56, modifiers: .maskCommand, keyLabel: "⇧").isValid(allowingShift: true),
              !KeyboardShortcut(keyCode: 56, modifiers: .maskCommand, keyLabel: "⇧").isValid,
              KeyboardShortcut(keyCode: 56, modifiers: [], keyLabel: "⇧").isValid(allowingShift: true) == false,
              state.begin(currentAppOnly: false, allowed: false) == nil,
              state.begin(currentAppOnly: false, allowed: true) == .begin(currentAppOnly: false),
              state.step(1) == .step(1),
              state.finish(commit: false) == .cancel,
              state.begin(currentAppOnly: true, allowed: true) == .begin(currentAppOnly: true),
              state.finish(commit: true) == .commit,
              state.finish(commit: true) == nil,
              KeyboardShortcut.reverse.isValid(allowingShift: true), !KeyboardShortcut.reverse.isValid,
              KeyboardShortcut(keyCode: 16, modifiers: [.maskCommand, .maskShift], keyLabel: "Y")
                  .isValid(allowingShift: true),
              !KeyboardShortcut(keyCode: 16, modifiers: [.maskCommand, .maskShift], keyLabel: "Y").isValid,
              !KeyboardShortcut(keyCode: 16, modifiers: [], keyLabel: "Y").isValid,
              !KeyboardShortcut(keyCode: 53, modifiers: .maskCommand, keyLabel: "Esc").isValid else { return false }

        let controller = ShortcutController()
        guard controller.keyAction(keyCode: 48, flags: []) == nil,
              controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskControl]) == nil,
              controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]) == nil,
              controller.keyAction(keyCode: 48, flags: .maskCommand) == .begin(currentAppOnly: false),
              controller.reverseShiftAction(flags: [.maskCommand, .maskShift], pressedShift: true) == .step(-1),
              controller.reverseShiftAction(flags: [.maskCommand, .maskShift], pressedShift: false) == nil,
              controller.reverseShiftAction(flags: .maskShift, pressedShift: true) == nil,
              controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]) == nil,
              controller.keyAction(keyCode: 48, flags: .maskCommand) == .step(1),
              controller.keyAction(keyCode: 50, flags: .maskCommand) == .step(1),
              controller.modifierAction(flags: [.maskCommand, .maskShift]) == nil,
              controller.modifierAction(flags: .maskShift) == .commit,
              controller.keyAction(keyCode: 50, flags: .maskCommand) == .begin(currentAppOnly: true),
              controller.keyAction(keyCode: 53, flags: .maskCommand) == .cancel else { return false }

        let custom = KeyboardShortcut(keyCode: 16, modifiers: [.maskControl, .maskAlternate], keyLabel: "Y")
        let sameKey = KeyboardShortcut(keyCode: 16, modifiers: .maskCommand, keyLabel: "Y")
        let customReverse = KeyboardShortcut(keyCode: 16,
                                             modifiers: [.maskCommand, .maskAlternate, .maskShift], keyLabel: "Y")
        guard custom.isValid, custom.display == "⌃⌥Y", !custom.conflicts(with: sameKey),
              customReverse.isValid(allowingShift: true), customReverse.display == "⌥⌘⇧Y",
              !custom.conflicts(with: customReverse), !sameKey.conflicts(with: customReverse),
              KeyboardShortcut.reverse.conflicts(with: KeyboardShortcut(
                  keyCode: 56, modifiers: .maskCommand, keyLabel: "⇧")) else { return false }
        controller.configure(allWindows: custom, currentApp: sameKey, reverse: customReverse)
        guard controller.keyAction(keyCode: 48, flags: .maskCommand) == nil,
              controller.keyAction(keyCode: 50, flags: .maskCommand) == nil,
              controller.keyAction(keyCode: 16, flags: .maskControl) == nil,
              controller.keyAction(keyCode: 16, flags: customReverse.modifiers) == nil,
              controller.keyAction(keyCode: 16, flags: custom.modifiers) == .begin(currentAppOnly: false),
              controller.keyAction(keyCode: 16, flags: customReverse.modifiers) == .step(-1),
              controller.keyAction(keyCode: 16, flags: custom.modifiers) == .step(1),
              controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]) == nil,
              controller.reverseShiftAction(flags: [.maskCommand, .maskShift], pressedShift: true) == nil,
              controller.keyAction(keyCode: 126, flags: custom.modifiers) == .step(-1),
              controller.keyAction(keyCode: 125, flags: custom.modifiers) == .step(1),
              controller.keyAction(keyCode: 0, flags: custom.modifiers) == nil,
              controller.modifierAction(flags: [.maskControl, .maskAlternate, .maskShift]) == nil,
              controller.modifierAction(flags: .maskControl) == .commit,
              controller.keyAction(keyCode: 16, flags: .maskCommand) == .begin(currentAppOnly: true),
              controller.modifierAction(flags: []) == .commit else { return false }
        controller.canBegin = { _ in false }
        guard controller.keyAction(keyCode: 16, flags: custom.modifiers) == nil else { return false }
        controller.canBegin = nil
        guard controller.keyAction(keyCode: 16, flags: custom.modifiers) != nil else { return false }
        var cancelled = false
        controller.onAction = { cancelled = $0 == .cancel }
        controller.configure(allWindows: .allWindows, currentApp: .currentApp, reverse: .reverse)
        guard cancelled, controller.modifierAction(flags: []) == nil else { return false }
        controller.configure(allWindows: .allWindows, currentApp: .allWindows, reverse: .reverse)
        guard controller.currentAppShortcut == .currentApp else { return false }
        controller.configure(allWindows: .allWindows, currentApp: .currentApp, reverse: .allWindows)
        guard controller.reverseShortcut == .reverse else { return false }

        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: [.control, .option], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "y",
                                          charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16),
              let recorded = KeyboardShortcut(event: event),
              recorded.matches(keyCode: 16, flags: custom.modifiers), recorded.keyLabel == "Y",
              Self.searchCharacters(event) == "y" else { return false }

        var acceptRecording = false
        var saved: KeyboardShortcut?
        controller.beginRecording(scope: .allWindows) { shortcut in
            guard acceptRecording else { return false }
            saved = shortcut
            return true
        }
        defer { controller.cancelRecording() }
        controller.record(event)
        guard controller.recordingScope == .allWindows,
              controller.recordingErrorKey == "The shortcuts must be different.", saved == nil else { return false }
        acceptRecording = true
        controller.record(event)
        guard saved == recorded, controller.recordingScope == nil,
              controller.recordingMonitor == nil, controller.recordingErrorKey == nil else { return false }
        controller.beginRecording(scope: .currentApp) { _ in false }
        guard let invalid = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "y",
                                            charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16),
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\u{1b}",
                                           charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return false }
        controller.record(invalid)
        guard controller.recordingScope == .currentApp, controller.recordingErrorKey != nil else { return false }
        controller.record(escape)
        guard controller.recordingScope == nil, controller.recordingMonitor == nil,
              controller.recordingErrorKey == nil else { return false }

        guard let shiftPress = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                                context: nil, characters: "", charactersIgnoringModifiers: "",
                                                isARepeat: false, keyCode: 56),
              let shiftTab = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                              modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                              context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                              isARepeat: false, keyCode: 48) else { return false }
        // Shift belongs to the reverse key alone: neither a tap nor a Shift combination records elsewhere.
        controller.beginRecording(scope: .allWindows) { _ in true }
        controller.record(shiftPress)
        controller.record(shiftTab)
        guard controller.recordingScope == .allWindows, controller.recordingErrorKey != nil else { return false }
        controller.cancelRecording()
        var savedReverse: KeyboardShortcut?
        controller.beginRecording(scope: .reverse) { shortcut in
            savedReverse = shortcut
            return true
        }
        controller.record(shiftPress)
        guard savedReverse == .reverse, controller.recordingScope == nil,
              controller.recordingErrorKey == nil else { return false }
        controller.beginRecording(scope: .reverse) { shortcut in
            savedReverse = shortcut
            return true
        }
        controller.record(shiftTab)
        guard savedReverse == KeyboardShortcut(keyCode: 48, modifiers: [.maskCommand, .maskShift], keyLabel: "Tab"),
              controller.recordingScope == nil, controller.recordingErrorKey == nil else { return false }

        let searchController = ShortcutController()
        guard searchController.keyAction(keyCode: 13, flags: .maskCommand, characters: "w") == nil,
              searchController.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]) == nil,
              searchController.keyAction(keyCode: 48, flags: .maskCommand) == .begin(currentAppOnly: false),
              searchController.keyAction(keyCode: 13, flags: .maskCommand, characters: "w") == .search("w"),
              searchController.keyAction(keyCode: 12, flags: .maskCommand, characters: "q") == .search("wq"),
              searchController.keyAction(keyCode: 8, flags: .maskCommand, characters: "C") == .search("wqC"),
              searchController.keyAction(keyCode: 49, flags: .maskCommand, characters: " ") == .search("wqC "),
              searchController.keyAction(keyCode: 51, flags: .maskCommand) == .search("wqC"),
              searchController.reverseShiftAction(flags: [.maskCommand, .maskShift], pressedShift: true) == .step(-1),
              searchController.keyAction(keyCode: 0, flags: .maskCommand, characters: "中") == nil,
              searchController.keyAction(keyCode: 122, flags: .maskCommand, characters: "\u{f704}") == nil,
              searchController.modifierAction(flags: []) == .commit,
              searchController.state.searchQuery.isEmpty,
              searchController.keyAction(keyCode: 48, flags: .maskCommand) == .begin(currentAppOnly: false),
              searchController.keyAction(keyCode: 51, flags: .maskCommand) == .search(""),
              searchController.keyAction(keyCode: 0, flags: .maskCommand, characters: "a") == .search("a"),
              searchController.keyAction(keyCode: 53, flags: .maskCommand) == .cancel,
              searchController.state.searchQuery.isEmpty else { return false }
        searchController.configure(allWindows: custom, currentApp: sameKey, reverse: .reverse)
        guard searchController.keyAction(keyCode: 16, flags: custom.modifiers) == .begin(currentAppOnly: false),
              searchController.reverseShiftAction(flags: [.maskControl, .maskAlternate, .maskShift],
                                                  pressedShift: true) == nil,
              searchController.keyAction(keyCode: 0, flags: custom.modifiers, characters: "a") == .search("a"),
              searchController.keyAction(keyCode: 16, flags: custom.modifiers, characters: "y") == .search("ay"),
              searchController.modifierAction(flags: .maskControl) == .commit,
              searchController.state.searchQuery.isEmpty else { return false }
        return true
    }
}

private let shortcutEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ShortcutController>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
}
