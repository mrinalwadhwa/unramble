import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Wrap AXUIElement calls to read accessibility attributes from running applications.
///
/// All methods are static and thread-safe. Errors from the Accessibility API are
/// translated into nil returns rather than thrown errors, since partial context
/// reads are acceptable (the pipeline uses whatever fields it can get).
public enum AXElementHelper {

    // MARK: - System-Wide Element

    /// Return the system-wide AXUIElement used to query the focused element.
    public static func systemWideElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    // MARK: - Attribute Reading

    /// Read a single attribute value from an AXUIElement.
    ///
    /// - Parameters:
    ///   - attribute: The accessibility attribute name (e.g. kAXValueAttribute).
    ///   - element: The AXUIElement to query.
    /// - Returns: The attribute value, or nil if the read fails.
    public static func value(of attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    /// Read a String attribute from an AXUIElement.
    public static func stringValue(of attribute: String, from element: AXUIElement) -> String? {
        guard let value = value(of: attribute, from: element) else { return nil }
        return value as? String
    }

    /// Read an Int attribute from an AXUIElement.
    public static func intValue(of attribute: String, from element: AXUIElement) -> Int? {
        guard let value = value(of: attribute, from: element) else { return nil }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    /// Read a Bool attribute from an AXUIElement.
    public static func boolValue(of attribute: String, from element: AXUIElement) -> Bool? {
        guard let value = value(of: attribute, from: element) else { return nil }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Read an AXUIElement attribute (e.g. kAXFocusedUIElementAttribute).
    public static func elementValue(of attribute: String, from element: AXUIElement) -> AXUIElement?
    {
        guard let value = value(of: attribute, from: element) else { return nil }
        // AXUIElement is a CFTypeRef; verify it is the right type.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Read an array attribute from an AXUIElement.
    public static func arrayValue(of attribute: String, from element: AXUIElement) -> [AXUIElement]?
    {
        guard let value = value(of: attribute, from: element) else { return nil }
        guard let array = value as? [AXUIElement] else { return nil }
        return array
    }

    // MARK: - Range Attributes

    /// Read a CFRange attribute (e.g. kAXSelectedTextRangeAttribute) from an AXUIElement.
    public static func rangeValue(of attribute: String, from element: AXUIElement) -> CFRange? {
        guard let value = value(of: attribute, from: element) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Focused Element

    /// Return the currently focused UI element across the entire system.
    public static func focusedElement() -> AXUIElement? {
        let system = systemWideElement()
        return elementValue(of: kAXFocusedUIElementAttribute, from: system)
    }

    // MARK: - Application Element

    /// Create an AXUIElement for the application with the given process ID.
    public static func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// Return the focused window of the given application element.
    public static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        return elementValue(of: kAXFocusedWindowAttribute, from: appElement)
    }

    /// Read the title of a window element.
    public static func windowTitle(of windowElement: AXUIElement) -> String? {
        return stringValue(of: kAXTitleAttribute, from: windowElement)
    }

    // MARK: - Role Detection

    /// Read the accessibility role of an element (e.g. "AXTextField", "AXTextArea").
    public static func role(of element: AXUIElement) -> String? {
        return stringValue(of: kAXRoleAttribute, from: element)
    }

    /// Read the accessibility subrole of an element.
    public static func subrole(of element: AXUIElement) -> String? {
        return stringValue(of: kAXSubroleAttribute, from: element)
    }

    /// Check whether the element is a text input (text field, text area, or web area).
    public static func isTextInput(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }
        let textRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            "AXWebArea",
            kAXComboBoxRole,
            "AXSearchField",
        ]
        return textRoles.contains(role)
    }

    // MARK: - Text Field Reading

    /// Read the full text content of a text input element.
    public static func textContent(of element: AXUIElement) -> String? {
        return stringValue(of: kAXValueAttribute, from: element)
    }

    /// Read the currently selected text in a text input element.
    public static func selectedText(of element: AXUIElement) -> String? {
        return stringValue(of: kAXSelectedTextAttribute, from: element)
    }

    /// Read the cursor (insertion point) position in a text input element.
    ///
    /// Returns the location component of the selected text range. When no text
    /// is selected, this is the caret position.
    public static func cursorPosition(of element: AXUIElement) -> Int? {
        guard let range = rangeValue(of: kAXSelectedTextRangeAttribute, from: element) else {
            return nil
        }
        let location = range.location
        guard location != kCFNotFound else { return nil }
        return location
    }

    // MARK: - Text Field Writing

    /// Set the value of a text input element via the Accessibility API.
    ///
    /// - Parameters:
    ///   - text: The new text value.
    ///   - element: The target AXUIElement.
    /// - Returns: true if the value was set successfully.
    @discardableResult
    public static func setValue(_ text: String, on element: AXUIElement) -> Bool {
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    /// Set the selected text range on a text input element.
    ///
    /// - Parameters:
    ///   - range: The range to select.
    ///   - element: The target AXUIElement.
    /// - Returns: true if the range was set successfully.
    @discardableResult
    public static func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value as CFTypeRef
        )
        return result == .success
    }

    // MARK: - Element Traversal

    /// Return the children of an element.
    public static func children(of element: AXUIElement) -> [AXUIElement]? {
        return arrayValue(of: kAXChildrenAttribute, from: element)
    }

    /// Return the parent of an element.
    public static func parent(of element: AXUIElement) -> AXUIElement? {
        return elementValue(of: kAXParentAttribute, from: element)
    }

    /// Search the element tree depth-first for an element matching the predicate.
    ///
    /// - Parameters:
    ///   - root: The root element to start searching from.
    ///   - maxDepth: Maximum traversal depth to prevent runaway searches (default 5).
    ///   - predicate: Return true when the desired element is found.
    /// - Returns: The first matching element, or nil.
    public static func findElement(
        in root: AXUIElement,
        maxDepth: Int = 5,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if predicate(root) { return root }
        guard maxDepth > 0 else { return nil }
        guard let kids = children(of: root) else { return nil }
        for child in kids {
            if let found = findElement(in: child, maxDepth: maxDepth - 1, matching: predicate) {
                return found
            }
        }
        return nil
    }
}
