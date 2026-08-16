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
        guard let app = attributeElement(system, kAXFocusedApplicationAttribute) else {
            return nil
        }
        let appName = attribute(app, kAXTitleAttribute) as? String

        var candidate: AXUIElement?
        if let window = attributeElement(app, kAXFocusedWindowAttribute),
           let el = attributeElement(window, kAXFocusedUIElementAttribute) {
            candidate = el
        } else if let el = attributeElement(app, kAXFocusedUIElementAttribute) {
            candidate = el
        }
        guard let element = candidate else { return nil }

        // If the focused element itself isn't editable, walk up to the nearest
        // editable ancestor (covers web content and embedded views).
        guard let (editable, role) = findEditableElement(from: element) else { return nil }

        let text = attribute(editable, kAXValueAttribute) as? String ?? ""
        var appPID: pid_t = 0
        AXUIElementGetPid(app, &appPID)
        return FocusedInput(element: editable, appElement: app, appPID: appPID, role: role, text: text, appName: appName)
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
    private static func findFocusedEditableDescendant(
        in root: AXUIElement,
        depth: Int
    ) -> (element: AXUIElement, role: String)? {
        guard depth < 8 else { return nil }
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

    /// Walks up the accessibility tree looking for an editable text input.
    private static func findEditableElement(from start: AXUIElement) -> (element: AXUIElement, role: String)? {
        var current: AXUIElement? = start
        var depth = 0
        while let el = current, depth < 12 {
            if let hit = editableCheck(el) { return hit }
            if let role = attribute(el, kAXRoleAttribute) as? String,
               role.contains("WebArea") || role == kAXGroupRole as String || role == kAXScrollAreaRole as String {
                if let hit = findFocusedEditableDescendant(in: el, depth: 0) { return hit }
            }
            current = attributeElement(el, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    /// One-line diagnostic for when no editable input is found, e.g.
    /// "app=Safari, focusedRole=AXWebArea (AXScrollArea)".
    static func focusedElementDebugInfo() -> String {
        guard isTrusted else { return "not trusted" }
        let system = AXUIElementCreateSystemWide()
        guard let app = attributeElement(system, kAXFocusedApplicationAttribute) else {
            return "no focused app"
        }
        let appName = attribute(app, kAXTitleAttribute) as? String ?? "?"
        var candidate: AXUIElement?
        if let window = attributeElement(app, kAXFocusedWindowAttribute),
           let el = attributeElement(window, kAXFocusedUIElementAttribute) {
            candidate = el
        } else if let el = attributeElement(app, kAXFocusedUIElementAttribute) {
            candidate = el
        }
        guard let el = candidate else {
            return "app=\(appName), no focused element"
        }
        let role = attribute(el, kAXRoleAttribute) as? String ?? "?"
        let subrole = attribute(el, kAXSubroleAttribute) as? String ?? ""
        return "app=\(appName), focusedRole=\(role)\(subrole.isEmpty ? "" : " (\(subrole))")"
    }
}