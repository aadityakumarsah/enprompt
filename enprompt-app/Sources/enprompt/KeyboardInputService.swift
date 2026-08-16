import AppKit
import CoreGraphics

/// Simulated keyboard input (Command-A, Command-V) used as a write-back
/// fallback for apps whose accessibility API reports success without
/// actually applying the change.
enum KeyboardInputService {

    /// Selects all current text and pastes `text` in its place. The user's
    /// original clipboard contents are restored shortly after the paste.
    static func pasteReplacingCurrentText(_ text: String, in appPID: pid_t? = nil) {
        activate(appPID)
        let pasteboard = NSPasteboard.general
        let saved = saveClipboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKey(keyCode: 0, flags: .maskCommand) // Command-A: select all
        usleep(150_000)
        postKey(keyCode: 9, flags: .maskCommand) // Command-V: paste
        usleep(150_000)

        restoreClipboard(pasteboard, saved: saved)
    }

    /// Replaces the current TUI input line: moves the caret to the end of the
    /// line (Control-E), deletes `deletingChars` characters with backspace,
    /// then pastes `text` (stripped of trailing newlines so the input isn't
    /// sent automatically). Works in readline-style apps (bash, claude, codex).
    static func replaceTerminalInput(_ text: String, deletingChars count: Int, in appPID: pid_t? = nil) {
        activate(appPID)

        let pasteboard = NSPasteboard.general
        let saved = saveClipboard(pasteboard)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        postKey(keyCode: 14, flags: .maskControl) // Control-E: end of input line
        usleep(100_000)
        let deletes = min(count, 8000)
        for _ in 0..<deletes {
            postKey(keyCode: 51, flags: []) // Backspace
            usleep(2_000)
        }
        usleep(100_000)
        postKey(keyCode: 9, flags: .maskCommand) // Command-V: paste
        usleep(100_000)

        restoreClipboard(pasteboard, saved: saved)
    }

    /// Pastes `text` at the current insertion point (no select-all first).
    static func pasteText(_ text: String, in appPID: pid_t? = nil) {
        activate(appPID)

        let pasteboard = NSPasteboard.general
        let saved = saveClipboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKey(keyCode: 9, flags: .maskCommand) // Command-V
        usleep(100_000)

        restoreClipboard(pasteboard, saved: saved)
    }

    private static func activate(_ appPID: pid_t?) {
        if let pid = appPID {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            usleep(200_000)
        }
    }

    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType: Data] {
        var saved: [NSPasteboard.PasteboardType: Data] = [:]
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved[type] = data
                }
            }
        }
        return saved
    }

    private static func restoreClipboard(_ pasteboard: NSPasteboard, saved: [NSPasteboard.PasteboardType: Data]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pasteboard.clearContents()
            for (type, data) in saved {
                pasteboard.setData(data, forType: type)
            }
        }
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}