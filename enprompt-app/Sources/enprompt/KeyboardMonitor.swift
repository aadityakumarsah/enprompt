import CoreGraphics
import Foundation

/// Global keyboard monitor using a CGEvent tap.
///
/// A normal macOS app only sees keyboard events while it is the active
/// application. An event tap at `.cgSessionEventTap` level sees every key
/// press system-wide, which is how enprompt learns about TAB presses without
/// being focused. Requires Accessibility permission.
final class KeyboardMonitor {

    /// Called when Option (⌥) is tapped twice quickly (gap in seconds).
    var onOptionDoubleTap: ((TimeInterval) -> Void)?

    /// Called when Option (⌥) is tapped three times quickly: visual capture
    /// (circle an area, speak an instruction).
    var onOptionTripleTap: (() -> Void)?

    /// Called when Option has been held long enough to start dictation.
    var onOptionHoldStart: (() -> Void)?

    /// Called when a held Option is released (dictation should stop).
    var onOptionHoldEnd: (() -> Void)?

    /// Called when Cmd+Z or Ctrl+Z is pressed without other modifiers.
    /// Return true to swallow the key (enprompt restored the pre-enhancement
    /// text); false lets it reach the focused app as a normal undo.
    var onUndoKey: (() -> Bool)?

    /// Called when Escape is pressed without modifiers. Return true to
    /// swallow it (e.g. finishing/cancelling visual capture dictation).
    var onEscapeKey: (() -> Bool)?

    private static let doubleTapWindow: TimeInterval = 0.8
    // Dictation starts after Option has been held this long.
    private static let holdThreshold: TimeInterval = 1.25
    // The double-tap fires after this grace period so a third tap can cancel
    // it and become a triple-tap (visual capture) instead. Long enough for a
    // natural triple-tap rhythm (~0.3s between taps), short enough that the
    // double-tap still feels instant.
    private static let tripleTapGrace: TimeInterval = 0.35

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastOptionTapAt: CFAbsoluteTime?
    private var secondLastOptionTapAt: CFAbsoluteTime?
    private var lastDoubleTapAt: CFAbsoluteTime = 0
    private var pendingDoubleTapWork: DispatchWorkItem?
    private var optionDownAt: CFAbsoluteTime?
    private var holdCheckWork: DispatchWorkItem?

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate returns nil when Accessibility permission is missing.
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            let now = CFAbsoluteTimeGetCurrent()
            if isPlainOptionTap(event) {
                // Option went down: candidate for a double/triple tap or a hold.
                if let secondLast = secondLastOptionTapAt, let last = lastOptionTapAt,
                   now - secondLast <= Self.doubleTapWindow, now - last <= Self.doubleTapWindow {
                    // Three quick taps: visual capture. Cancel the pending
                    // double-tap so enhancement does not fire.
                    secondLastOptionTapAt = nil
                    lastOptionTapAt = nil
                    pendingDoubleTapWork?.cancel()
                    pendingDoubleTapWork = nil
                    lastDoubleTapAt = now
                    onOptionTripleTap?()
                } else if let last = lastOptionTapAt, now - last <= Self.doubleTapWindow {
                    // Two quick taps: fire the double-tap after a grace period
                    // so a third quick tap can still become a triple-tap.
                    secondLastOptionTapAt = last
                    lastOptionTapAt = now
                    let gap = now - last
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.pendingDoubleTapWork = nil
                            self.secondLastOptionTapAt = nil
                            self.lastOptionTapAt = nil
                            self.lastDoubleTapAt = CFAbsoluteTimeGetCurrent()
                            self.onOptionDoubleTap?(gap)
                        }
                    }
                    pendingDoubleTapWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tripleTapGrace, execute: work)
                } else {
                    secondLastOptionTapAt = nil
                    lastOptionTapAt = now
                }
                optionDownAt = now
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let down = self.optionDownAt,
                              CFAbsoluteTimeGetCurrent() - down >= Self.holdThreshold,
                              CFAbsoluteTimeGetCurrent() - self.lastDoubleTapAt > 1.5 else {
                            return
                        }
                        self.holdCheckWork = nil
                        self.onOptionHoldStart?()
                    }
                }
                holdCheckWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: work)
            } else if event.flags.contains(.maskAlternate) {
                // Option is still down but another modifier is now held
                // (⌥⌘, ⌥⇧, ⌥⌃, …). This is not an enprompt gesture: cancel
                // every pending activation and stop dictation that may have
                // already started, so Option only works when pressed alone.
                let holdWasActive: Bool
                if let down = optionDownAt {
                    holdWasActive = CFAbsoluteTimeGetCurrent() - down >= Self.holdThreshold
                        && CFAbsoluteTimeGetCurrent() - lastDoubleTapAt > 1.5
                } else {
                    holdWasActive = false
                }
                resetGestureState()
                if holdWasActive {
                    onOptionHoldEnd?()
                }
            } else if !event.flags.contains(.maskAlternate), let down = optionDownAt {
                // Option went up after being held.
                holdCheckWork?.cancel()
                holdCheckWork = nil
                optionDownAt = nil
                if now - down >= Self.holdThreshold, now - lastDoubleTapAt > 1.5 {
                    onOptionHoldEnd?()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // A character key pressed while Option is held is an Option-combo shortcut
        // (⌥+B in Terminal, ⌥+⌫ word-delete, accented typing, ...), not an
        // enprompt gesture. Drop every tap/hold candidate so the combo can
        // never trigger a double-tap, triple-tap, or dictation.
        if type == .keyDown, event.flags.contains(.maskAlternate) {
            let holdWasActive: Bool
            if let down = optionDownAt {
                holdWasActive = CFAbsoluteTimeGetCurrent() - down >= Self.holdThreshold
                    && CFAbsoluteTimeGetCurrent() - lastDoubleTapAt > 1.5
            } else {
                holdWasActive = false
            }
            resetGestureState()
            if holdWasActive {
                onOptionHoldEnd?()
            }
        }

        // Cmd+Z / Ctrl+Z: undo the last enhancement when there is one.
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == KeyboardMonitor.zKeyCode,
           isPlainUndoKey(event) {
            if onUndoKey?() == true {
                return nil
            }
        }
        // Escape: finish or cancel visual capture when enprompt owns the stage.
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == KeyboardMonitor.escapeKeyCode,
           event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [] {
            if onEscapeKey?() == true {
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private static let zKeyCode: CGKeyCode = 6
    private static let escapeKeyCode: CGKeyCode = 53

    private func isPlainUndoKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)
        let other = flags.contains(.maskAlternate) || flags.contains(.maskShift)
        return (hasCommand || hasControl) && !other
    }

    /// True when Option was just pressed down with no other modifier held.
    private func isPlainOptionTap(_ event: CGEvent) -> Bool {
        let common: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        return event.flags.intersection(common) == [.maskAlternate]
    }

    /// Discards all in-flight gesture state so nothing can activate.
    private func resetGestureState() {
        pendingDoubleTapWork?.cancel()
        pendingDoubleTapWork = nil
        holdCheckWork?.cancel()
        holdCheckWork = nil
        optionDownAt = nil
        lastOptionTapAt = nil
        secondLastOptionTapAt = nil
    }
}