import AppKit
import CoreGraphics

/// Recognizes complete, brief Option taps; typing and other modifiers invalidate the pair.
struct OptionTapRecognizer {
    static let maximumHold: TimeInterval = 0.35
    static let maximumGap: TimeInterval = 0.5
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var cleanPress = false

    mutating func invalidate() {
        pressedAt = nil
        releasedAt = nil
        cleanPress = false
    }

    mutating func flagsChanged(optionDown: Bool, otherModifiers: Bool,
                               keyCode: UInt16, at time: TimeInterval) -> Bool {
        guard !otherModifiers, keyCode == 58 || keyCode == 61 else { invalidate(); return false }
        if optionDown {
            guard pressedAt == nil else { invalidate(); return false }
            pressedAt = time
            cleanPress = true
            return false
        }
        guard cleanPress, let pressedAt, time >= pressedAt,
              time - pressedAt <= Self.maximumHold else { invalidate(); return false }
        self.pressedAt = nil
        cleanPress = false
        if let previous = releasedAt, time >= previous, time - previous <= Self.maximumGap {
            releasedAt = nil
            return true
        }
        releasedAt = time
        return false
    }
}

struct ShortcutKeyRecognizer {
    enum Decision: Equatable { case passThrough, consume, cancel, pasteLast }
    private var suppressedEscape = false

    mutating func keyDown(code: UInt16, flags: CGEventFlags, repeated: Bool,
                          consumesEscape: Bool, pasteLastEnabled: Bool) -> Decision {
        if code == 53, consumesEscape || suppressedEscape {
            let first = !suppressedEscape && !repeated
            suppressedEscape = true
            return first ? .cancel : .consume
        }
        if code == 9, pasteLastEnabled, flags.contains([.maskAlternate, .maskShift]),
           flags.intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty {
            return repeated ? .consume : .pasteLast
        }
        return .passThrough
    }

    mutating func consumesKeyUp(code: UInt16) -> Bool {
        guard code == 53, suppressedEscape else { return false }
        suppressedEscape = false
        return true
    }

    mutating func reset() { suppressedEscape = false }
}

/// Runs an active event tap so Escape can be consumed during dictation without reaching
/// the underlying application. The tap is attached to the main run loop.
final class ShortcutService {
    var onToggleDictation: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?
    var consumesEscape = false
    var observesEscapeDuringMeeting = false
    private var pasteLastEnabled = UserDefaults.standard.object(forKey: "pasteLastShortcutEnabled") as? Bool ?? true
    private var recognizer = OptionTapRecognizer()
    private var keyRecognizer = ShortcutKeyRecognizer()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<ShortcutService>.fromOpaque(pointer).takeUnretainedValue()
                return service.handle(type, event)
            }, userInfo: pointer)
        else { onAvailabilityChanged?(false); return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onAvailabilityChanged?(true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        recognizer.invalidate()
        keyRecognizer.reset()
    }

    func setPasteLastShortcut(enabled: Bool) {
        pasteLastEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "pasteLastShortcutEnabled")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recognizer.invalidate()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if type == .flagsChanged {
            let others: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
            if recognizer.flagsChanged(optionDown: flags.contains(.maskAlternate),
                otherModifiers: !flags.intersection(others).isEmpty,
                keyCode: code, at: TimeInterval(event.timestamp) / 1_000_000_000) {
                DispatchQueue.main.async { [weak self] in self?.onToggleDictation?() }
            }
        } else if type == .keyDown {
            recognizer.invalidate()
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            switch keyRecognizer.keyDown(code: code, flags: flags, repeated: repeated,
                consumesEscape: consumesEscape, pasteLastEnabled: pasteLastEnabled) {
            case .cancel:
                // This tap runs on the main run loop. Revoke insertion before returning
                // the observed Escape, rather than racing a queued provider completion.
                onCancel?()
                return nil
            case .pasteLast:
                DispatchQueue.main.async { [weak self] in self?.onPasteLast?() }
                return nil
            case .consume: return nil
            case .passThrough:
                if code == 53, !repeated, observesEscapeDuringMeeting {
                    DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                }
            }
        } else if type == .keyUp, keyRecognizer.consumesKeyUp(code: code) {
            return nil
        } else if type == .leftMouseDown || type == .rightMouseDown {
            recognizer.invalidate()
        }
        return Unmanaged.passUnretained(event)
    }

    deinit { stop() }
}
