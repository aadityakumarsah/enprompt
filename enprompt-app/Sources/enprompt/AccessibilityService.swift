import AppKit
import ApplicationServices
import Foundation

enum AXService {

    // MARK: - Trust / permission

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the macOS Accessibility permission prompt for this app.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Focused element detection

    struct FocusedInput {
        let element: AXUIElement
        let appElement: AXUIElement?
        let appPID: pid_t
        let role: String
        let text: String
        let appName: String?
    }

    /// Apps whose "focused text" is the whole terminal screen buffer, not an
    /// editable input line. They need the keyboard-based replacement path.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.warp.Warp",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "org.wezfurlong.wezterm",
        "com.tabbyml.tabby",
        "io.ghostty.Ghostty",
    ]

    static func isTerminalApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Returns the currently focused editable text input, if any.
    static func focusedTextInput() -> FocusedInput? {
        guard isTrusted else { return nil }

        let system = AXUIElementCreateSystemWide()

        // 1. The system-wide focused element directly (most reliable across
        //    apps; the app is derived from the element's own PID).
        if let element = attributeElement(system, kAXFocusedUIElementAttribute),
           let (editable, role) = findEditableElement(from: element) {
            return makeFocusedInput(element: editable, role: role)
        }

        // 2. The focused application, then its focused window / element.
        if let app = attributeElement(system, kAXFocusedApplicationAttribute),
           let input = focusedInput(in: app) {
            return input
        }

        // 3. NSWorkspace frontmost app. Covers menu-bar / LSUIElement apps
        //    (including enprompt itself) where kAXFocusedApplicationAttribute
        //    is reported as nil on some macOS versions.
        if let wsApp = NSWorkspace.shared.frontmostApplication,
           wsApp.processIdentifier != getpid() {
            let app = AXUIElementCreateApplication(wsApp.processIdentifier)
            if let input = focusedInput(in: app) {
                return input
            }
        }

        return nil
    }

    private static func focusedInput(in app: AXUIElement) -> FocusedInput? {
        var candidate: AXUIElement?
        if let window = attributeElement(app, kAXFocusedWindowAttribute),
           let el = attributeElement(window, kAXFocusedUIElementAttribute) {
            candidate = el
        } else if let el = attributeElement(app, kAXFocusedUIElementAttribute) {
            candidate = el
        }
        guard let element = candidate,
              let (editable, role) = findEditableElement(from: element) else {
            return nil
        }
        return makeFocusedInput(element: editable, role: role)
    }

    private static func makeFocusedInput(element: AXUIElement, role: String) -> FocusedInput {
        let text = attribute(element, kAXValueAttribute) as? String ?? ""
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = pid > 0 ? AXUIElementCreateApplication(pid) : nil
        let appName = app.flatMap { attribute($0, kAXTitleAttribute) as? String }
        return FocusedInput(element: element, appElement: app, appPID: pid, role: role, text: text, appName: appName)
    }

    /// Returns the currently selected text ANYWHERE - editable fields or
    /// read-only content (a tweet, an article). Checks the focused element
    /// and each ancestor for a selected-text attribute, which is how Safari
    /// and Chrome expose page selections.
    static func focusedSelection() -> String? {
        guard isTrusted else { return nil }
        guard let element = deepFocusedElement() else { return nil }
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 12 {
            if let text = attribute(el, kAXSelectedTextAttribute) as? String,
               !text.isEmpty {
                return text
            }
            current = attributeElement(el, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    private static func deepFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let element = attributeElement(system, kAXFocusedUIElementAttribute) {
            return element
        }
        if let app = attributeElement(system, kAXFocusedApplicationAttribute),
           let el = focusedElement(in: app) {
            return el
        }
        if let wsApp = NSWorkspace.shared.frontmostApplication,
           wsApp.processIdentifier != getpid() {
            let app = AXUIElementCreateApplication(wsApp.processIdentifier)
            if let el = focusedElement(in: app) {
                return el
            }
        }
        // Some apps (notably Chrome) report no AX focus info at all. Hit-test
        // at the mouse position instead - the user just selected text, so the
        // cursor is right there. Skip elements that belong to enprompt itself
        // (e.g. the popover when it is open).
        if let point = mousePositionInAXCoordinates(),
           let hit = hitTest(at: point) {
            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            if pid != getpid() {
                return hit
            }
        }
        return nil
    }

    private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        if let window = attributeElement(app, kAXFocusedWindowAttribute),
           let el = attributeElement(window, kAXFocusedUIElementAttribute) {
            return el
        }
        if let el = attributeElement(app, kAXFocusedUIElementAttribute) {
            return el
        }
        return nil
    }

    private static func hitTest(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &element
        )
        guard result == .success, let element else { return nil }
        return element
    }

    /// The current mouse location in AX coordinates (top-left origin of the
    /// main display). NSEvent.mouseLocation uses a bottom-left origin.
    private static func mousePositionInAXCoordinates() -> CGPoint? {
        guard let screen = NSScreen.main else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: screen.frame.height - mouse.y)
    }

    // MARK: - Text replacement

    /// A text selection inside an editable element.
    struct TextSelection {
        let text: String
        let location: Int
        let length: Int
    }

    /// Returns the user's current text selection in the element, if any.
    static func selectedText(of element: AXUIElement) -> TextSelection? {
        guard isTrusted else { return nil }
        guard let text = attribute(element, kAXSelectedTextAttribute) as? String,
              !text.isEmpty else { return nil }
        var location = 0
        var length = text.count
        if let value = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(value, to: AXValue.self)
            if AXValueGetType(axValue) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(axValue, .cfRange, &range) {
                    location = range.location
                    length = range.length
                }
            }
        }
        return TextSelection(text: text, location: location, length: length)
    }

    /// Replaces the text of an accessibility element (used by the LLM step later).
    @discardableResult
    static func replaceText(_ text: String, in input: AXUIElement) -> Bool {
        guard isTrusted else { return false }
        let result = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, text as CFTypeRef)
        return result == .success
    }

    /// Reads the current AX value of an element (used to verify write-backs).
    static func value(of element: AXUIElement) -> String? {
        guard isTrusted else { return nil }
        return attribute(element, kAXValueAttribute) as? String
    }

    /// Attempts to move keyboard focus back to an element of a given app.
    @discardableResult
    static func focus(_ element: AXUIElement, in app: AXUIElement?) -> Bool {
        guard let app else { return false }
        let result = AXUIElementSetAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            element
        )
        return result == .success
    }

    // MARK: - Private

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func attributeElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    /// Returns the element if it looks like an editable text input: either a
    /// known editable role or any element that carries a string value.
    private static func editableCheck(_ el: AXUIElement) -> (element: AXUIElement, role: String)? {
        if let role = attribute(el, kAXRoleAttribute) as? String, editableRoles.contains(role) {
            return (el, role)
        }
        if attribute(el, kAXValueAttribute) is String {
            return (el, attribute(el, kAXRoleAttribute) as? String ?? "AXValueInput")
        }
        return nil
    }

    private static func isFocused(_ el: AXUIElement) -> Bool {
        (attribute(el, kAXFocusedAttribute) as? Bool) == true
    }

    /// Searches inside web content / container views for a focused editable
    /// element (Safari and Chrome often report the web area as focused).
    /// Electron apps (Cursor, VS Code) mark nothing as focused, so a second
    /// pass accepts any editable element that actually holds text.
    private static func findFocusedEditableDescendant(
        in root: AXUIElement,
        depth: Int
    ) -> (element: AXUIElement, role: String)? {
        guard depth < 14 else { return nil }
        if isFocused(root), let hit = editableCheck(root) { return hit }
        guard let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let hit = findFocusedEditableDescendant(in: child, depth: depth + 1) {
                return hit
            }
        }
        return nil
    }

    /// Second pass for Electron apps: no element is marked focused, but the
    /// input the user typed into still holds text. Returns the deepest
    /// editable element with a non-empty value.
    private static func findEditableDescendantWithText(
        in root: AXUIElement,
        depth: Int
    ) -> (element: AXUIElement, role: String)? {
        guard depth < 14 else { return nil }
        var best: (element: AXUIElement, role: String)?
        if let hit = editableCheck(root),
           let value = attribute(hit.element, kAXValueAttribute) as? String,
           !value.isEmpty {
            best = hit
        }
        guard let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] else {
            return best
        }
        for child in children {
            if let deeper = findEditableDescendantWithText(in: child, depth: depth + 1) {
                best = deeper
            }
        }
        return best
    }

    /// Walks up the accessibility tree looking for an editable text input.
    private static func findEditableElement(from start: AXUIElement) -> (element: AXUIElement, role: String)? {
        var current: AXUIElement? = start
        var depth = 0
        while let el = current, depth < 12 {
            if let hit = editableCheck(el) { return hit }
            if let role = attribute(el, kAXRoleAttribute) as? String,
               role.contains("WebArea") || role == kAXGroupRole as String || role == kAXScrollAreaRole as String {
                if let hit = findFocusedEditableDescendant(in: el, depth: 0) { return hit }
                // Electron apps mark nothing as focused: fall back to the
                // deepest editable that holds text.
                if let hit = findEditableDescendantWithText(in: el, depth: 0) { return hit }
            }
            current = attributeElement(el, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    /// True when the element lives inside web content (has a WebArea
    /// ancestor). Web content is where Electron apps (Cursor, VS Code) and
    /// browsers hide their focused input from the AX focus attributes.
    static func isInsideWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 20 {
            if let role = attribute(el, kAXRoleAttribute) as? String,
               role.contains("WebArea") {
                return true
            }
            current = attributeElement(el, kAXParentAttribute)
            depth += 1
        }
        return false
    }

    /// The focused/hit element when it sits inside web content and belongs
    /// to another app (never enprompt itself). Signals that the user is in
    /// an app whose AX tree may hide the actual input (Cursor, VS Code).
    static func webContentElement() -> AXUIElement? {
        guard let element = deepFocusedElement() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { return nil }
        return isInsideWebContent(element) ? element : nil
    }

    /// One-line diagnostic for when no editable input is found, e.g.
    /// "app=Safari, focusedRole=AXWebArea (AXScrollArea)".
    static func focusedElementDebugInfo() -> String {
        guard isTrusted else { return "not trusted" }
        let system = AXUIElementCreateSystemWide()

        if let element = attributeElement(system, kAXFocusedUIElementAttribute) {
            return describe(element, source: "system-wide focused element")
        }

        if let app = attributeElement(system, kAXFocusedApplicationAttribute) {
            let appName = attribute(app, kAXTitleAttribute) as? String ?? "?"
            var candidate: AXUIElement?
            if let window = attributeElement(app, kAXFocusedWindowAttribute),
               let el = attributeElement(window, kAXFocusedUIElementAttribute) {
                candidate = el
            } else if let el = attributeElement(app, kAXFocusedUIElementAttribute) {
                candidate = el
            }
            if let el = candidate {
                return describe(el, source: "app=\(appName)")
            }
            return "app=\(appName), no focused element"
        }

        if let wsApp = NSWorkspace.shared.frontmostApplication {
            if let point = mousePositionInAXCoordinates(),
               let hit = hitTest(at: point) {
                var pid: pid_t = 0
                AXUIElementGetPid(hit, &pid)
                if pid != getpid() {
                    return describe(hit, source: "mouse hit-test (frontmost \(wsApp.localizedName ?? "?")")
                }
            }
            return "frontmost app=\(wsApp.localizedName ?? "?") (pid \(wsApp.processIdentifier)), no AX focus info"
        }

        return "no focused app"
    }

    private static func describe(_ element: AXUIElement, source: String) -> String {
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let editable = editableCheck(element) != nil ? ", editable=yes" : ""
        return "\(source), focusedRole=\(role)\(subrole.isEmpty ? "" : " (\(subrole))")\(editable)"
    }
}