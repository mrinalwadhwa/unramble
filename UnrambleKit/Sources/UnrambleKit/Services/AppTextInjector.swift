import Foundation

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Inject text into the active application using app-aware strategies.
///
/// Three injection strategies are supported, tried in order of preference:
/// 1. **Accessibility API** — set kAXValueAttribute directly on the focused element
/// 2. **Pasteboard + Cmd+V** — copy to clipboard and simulate paste (preserves original clipboard)
/// 3. **Keystroke simulation** — simulate individual key events via CGEvent
///
/// The strategy is selected per-app based on bundle ID. If the preferred strategy
/// fails, the injector falls back to the next one before throwing.
public final class AppTextInjector: TextInjecting, @unchecked Sendable {

    /// Error types for text injection failures.
    public enum InjectionError: Error, Sendable, CustomStringConvertible {
        case noFocusedElement
        case allStrategiesFailed(bundleID: String)
        case accessibilityNotGranted
        case pasteNotConsumed

        /// Whether this error should stop the strategy loop immediately
        /// instead of falling through to the next strategy.
        ///
        /// `pasteNotConsumed` is terminal because the paste was already
        /// executed (Cmd+V fired, clipboard restored). Trying another
        /// strategy would double-inject or inject stale content.
        ///
        /// `noFocusedElement` is NOT terminal because apps like Zed report
        /// AXWindow as the focused element (fails AX text input check) but
        /// handle Cmd+V internally. The pasteboard strategy must still run.
        public var isTerminal: Bool {
            switch self {
            case .pasteNotConsumed:
                return true
            case .noFocusedElement, .allStrategiesFailed, .accessibilityNotGranted:
                return false
            }
        }

        public var description: String {
            switch self {
            case .noFocusedElement:
                return "No focused UI element found for text injection"
            case .allStrategiesFailed(let bundleID):
                return "All injection strategies failed for app: \(bundleID)"
            case .accessibilityNotGranted:
                return "Accessibility permission is not granted"
            case .pasteNotConsumed:
                return "Paste was not consumed by the target application"
            }
        }
    }

    /// Map bundle IDs to their preferred injection strategy order.
    ///
    /// Apps not in this map use the default order: accessibility → pasteboard → keystroke.
    private static let strategyMap: [String: [InjectionStrategy]] = [
        // Native macOS apps — accessibility works well
        "com.apple.TextEdit": [.accessibility, .pasteboard],
        "com.apple.Notes": [.accessibility, .pasteboard],
        "com.apple.mail": [.accessibility, .pasteboard],
        "com.apple.dt.Xcode": [.accessibility, .pasteboard],

        // Terminal — pasteboard is most reliable
        "com.apple.Terminal": [.pasteboard, .keystroke],
        "com.googlecode.iterm2": [.pasteboard, .keystroke],

        // Electron apps — pasteboard is most reliable
        "com.tinyspeck.slackmacgap": [.pasteboard, .accessibility],
        "com.microsoft.VSCode": [.pasteboard, .keystroke],
        "com.todesktop.230313mzl4w4u92": [.pasteboard, .keystroke],  // Cursor
        "com.hnc.Discord": [.pasteboard, .keystroke],
        "notion.id": [.pasteboard, .accessibility],
        "md.obsidian": [.pasteboard, .accessibility],

        // Browsers — pasteboard for web content fields
        "com.apple.Safari": [.pasteboard, .accessibility],
        "com.google.Chrome": [.pasteboard, .accessibility],
        "com.microsoft.edgemac": [.pasteboard, .accessibility],
        "com.brave.Browser": [.pasteboard, .accessibility],
        "company.thebrowser.Browser": [.pasteboard, .accessibility],  // Arc
        "org.mozilla.firefox": [.pasteboard, .keystroke],

        // Messages — pasteboard
        "com.apple.MobileSMS": [.pasteboard, .accessibility],
    ]

    /// Default strategy order when an app is not in the strategy map.
    private static let defaultStrategies: [InjectionStrategy] = [
        .accessibility, .pasteboard, .keystroke,
    ]

    public init() {}

    // MARK: - TextInjecting

    public func inject(text: String, into context: AppContext) async throws {
        // Append a trailing space so consecutive dictations are separated.
        // The next injection's addLeadingSpaceIfNeeded sees the space and
        // does not add another, preventing double spaces.
        let text = text.hasSuffix(" ") || text.hasSuffix("\n") ? text : text + " "

        let isTerminal = context.isTerminal
        let strategies = AppTextInjector.strategies(for: context.bundleID)
        var lastError: Error?

        for strategy in strategies {
            do {
                switch strategy {
                case .accessibility:
                    try injectViaAccessibility(text: text, into: context)
                    return
                case .pasteboard:
                    try injectViaPasteboard(text: text, skipLeadingSpace: isTerminal)
                    return
                case .keystroke:
                    try injectViaKeystrokes(text: text, skipLeadingSpace: isTerminal)
                    return
                }
            } catch let error as InjectionError where error.isTerminal {
                throw error
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? InjectionError.allStrategiesFailed(bundleID: context.bundleID)
    }

    // MARK: - Strategy Selection

    /// Return the ordered list of strategies to try for the given bundle ID.
    public static func strategies(for bundleID: String) -> [InjectionStrategy] {
        return strategyMap[bundleID] ?? defaultStrategies
    }

    // MARK: - Strategy 1: Accessibility API

    /// Inject text by setting the accessibility value on the focused element.
    ///
    /// For text fields that support kAXValueAttribute writes, this inserts text
    /// at the cursor position (or replaces the selection) by reading the current
    /// value, splicing in the new text, and writing back the full value.
    private func injectViaAccessibility(text: String, into context: AppContext) throws {
        guard let focused = AXElementHelper.focusedElement() else {
            throw InjectionError.noFocusedElement
        }

        guard AXElementHelper.isTextInput(focused) else {
            throw InjectionError.noFocusedElement
        }

        // Read current value and cursor position to splice text in.
        // Use fresh state (not stale context from recording start) so
        // addLeadingSpaceIfNeeded sees where the cursor actually is now.
        let currentValue = AXElementHelper.textContent(of: focused) ?? ""
        let cursorPos = AXElementHelper.cursorPosition(of: focused)

        let textToInject = addLeadingSpaceIfNeeded(
            text: text,
            fieldContent: currentValue,
            cursorPosition: cursorPos
        )
        let selectedRange = AXElementHelper.rangeValue(
            of: kAXSelectedTextRangeAttribute, from: focused)

        let newValue: String
        let newCursorPos: Int

        if let range = selectedRange, range.length > 0 {
            // Replace selected text (range is in UTF-16 offsets)
            let start = stringIndexFromUTF16Offset(in: currentValue, utf16Offset: range.location)
            let end = stringIndexFromUTF16Offset(
                in: currentValue, utf16Offset: range.location + range.length)
            var mutable = currentValue
            mutable.replaceSubrange(start..<end, with: textToInject)
            newValue = mutable
            newCursorPos = range.location + utf16Count(of: textToInject)
        } else if let pos = cursorPos {
            // Insert at cursor position (pos is a UTF-16 offset)
            let index = stringIndexFromUTF16Offset(in: currentValue, utf16Offset: pos)
            var mutable = currentValue
            mutable.insert(contentsOf: textToInject, at: index)
            newValue = mutable
            newCursorPos = pos + utf16Count(of: textToInject)
        } else {
            // Append to end
            newValue = currentValue + textToInject
            newCursorPos = utf16Count(of: newValue)
        }

        guard AXElementHelper.setValue(newValue, on: focused) else {
            throw InjectionError.allStrategiesFailed(bundleID: "accessibility-set-failed")
        }

        // Move cursor to end of injected text
        let cursorRange = CFRange(location: newCursorPos, length: 0)
        AXElementHelper.setSelectedTextRange(cursorRange, on: focused)
    }

    // MARK: - Strategy 2: Pasteboard + Cmd+V

    /// Detect whether a receiving app consumed the paste by using a lazy
    /// `NSPasteboardItemDataProvider`. When the app reads the pasteboard
    /// to handle Cmd+V, the `provideDataForType:` callback fires and we
    /// deliver the text there. If no callback fires within the timeout,
    /// no app consumed the paste (no text target).
    ///
    /// Three outcomes:
    /// - `callbackFired` — text consumed and delivered via the callback.
    /// - `providerInvalidated` (finished called, callback not) — an external
    ///   process wrote to the general pasteboard between setup and read,
    ///   invalidating the provider. Falls back to eager `setString` retry.
    /// - Neither within timeout — no target. Throw `pasteNotConsumed`.
    private final class PasteConsumptionProbe: NSObject, NSPasteboardItemDataProvider {
        let text: String
        private(set) var callbackFired = false
        private(set) var providerInvalidated = false

        init(text: String) {
            self.text = text
            super.init()
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            callbackFired = true
            item.setString(text, forType: type)
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            if !callbackFired {
                providerInvalidated = true
            }
        }
    }

    /// Maximum time to wait for the receiving app to read the pasteboard
    /// after Cmd+V. Empirically measured: 7-12ms for native apps, up to
    /// ~50ms for Electron apps. 250ms provides generous headroom.
    private static let pasteConsumptionTimeout: TimeInterval = 0.25

    /// Inject text by copying it to the pasteboard and simulating Cmd+V.
    ///
    /// Uses a lazy `NSPasteboardItemDataProvider` to both deliver text and
    /// detect whether the receiving app consumed the paste. If the provider
    /// callback fires, the app read the pasteboard and received the text.
    /// If the provider is invalidated by an external clipboard write before
    /// the app reads it, falls back to eager `setString` + re-paste. If
    /// neither occurs within the timeout, no text target exists and
    /// `pasteNotConsumed` is thrown.
    private func injectViaPasteboard(text: String, skipLeadingSpace: Bool = false) throws {
        #if canImport(AppKit)
            let textToInject = skipLeadingSpace
                ? text : addLeadingSpaceIfNeededFromFocused(text: text)

            // The pasteboard provider callback fires on the main thread.
            // The entire sequence (save, lazy provider setup, Cmd+V, run
            // loop pump, restore) must run on the main thread so the
            // callback fires in the run loop we are pumping.
            let result: PasteResult =
                if Thread.isMainThread {
                    performPasteboardInjection(text: textToInject)
                } else {
                    DispatchQueue.main.sync {
                        performPasteboardInjection(text: textToInject)
                    }
                }

            switch result {
            case .consumed:
                return
            case .invalidated:
                return
            case .notConsumed:
                throw InjectionError.pasteNotConsumed
            }
        #else
            throw InjectionError.allStrategiesFailed(bundleID: "pasteboard-unavailable")
        #endif
    }

    /// Result of a pasteboard injection attempt.
    private enum PasteResult {
        case consumed
        case invalidated
        case notConsumed
    }

    /// Run the full pasteboard injection sequence on the current thread.
    ///
    /// Must be called on the main thread so the lazy provider callback
    /// fires in the run loop we pump.
    private func performPasteboardInjection(text: String) -> PasteResult {
        #if canImport(AppKit)
            let pasteboard = NSPasteboard.general

            // Save current clipboard content.
            let savedItems = savePasteboardContents(pasteboard)

            // Set up lazy provider: text is delivered in the callback when
            // the receiving app reads the pasteboard after Cmd+V.
            pasteboard.clearContents()
            let probe = PasteConsumptionProbe(text: text)
            let item = NSPasteboardItem()
            item.setDataProvider(probe, forTypes: [.string])
            pasteboard.writeObjects([item])

            // Simulate Cmd+V immediately. Keep the window between provider
            // setup and paste as tight as possible to minimize the chance
            // of an external clipboard write invalidating the provider.
            simulatePaste()

            // Pump the main run loop to receive the provider callback.
            // The callback fires when the receiving app reads the
            // pasteboard. Most apps read within 7-12ms; Electron apps
            // may take up to ~50ms. 250ms provides generous headroom.
            let deadline = Date().addingTimeInterval(Self.pasteConsumptionTimeout)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                if probe.callbackFired || probe.providerInvalidated {
                    break
                }
            }

            if probe.callbackFired {
                // The app read the pasteboard and received the text via
                // the callback. Wait briefly for the app to finish
                // processing the paste before restoring the clipboard.
                // Without this delay, fast clipboard restore can race
                // with apps that read the pasteboard data asynchronously
                // after the initial provider callback.
                Self.mainThreadDelay(seconds: 0.05)
                Log.debug("[Injection] Paste consumed (lazy provider callback fired)")
                restorePasteboardContents(pasteboard, items: savedItems)
                return .consumed
            }

            if probe.providerInvalidated {
                // An external process (clipboard manager, password manager,
                // etc.) wrote to the general pasteboard, invalidating the
                // lazy provider before the receiving app could read it.
                // Fall back to eager write + re-paste for reliable delivery.
                // No consumption detection is possible in this path.
                Log.debug(
                    "[Injection] Lazy provider invalidated by external write, retrying eagerly"
                )
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                simulatePaste()
                // Electron apps need extra time to read the pasteboard.
                Self.mainThreadDelay(seconds: 0.2)
                restorePasteboardContents(pasteboard, items: savedItems)
                return .invalidated
            }

            // No callback and no invalidation within the timeout window.
            // No app read the pasteboard, meaning no text field handled
            // the paste. Restore the clipboard and signal no-target.
            Log.debug("[Injection] Paste not consumed (no callback within timeout)")
            restorePasteboardContents(pasteboard, items: savedItems)
            return .notConsumed
        #else
            return .notConsumed
        #endif
    }

    // MARK: - Strategy 3: Keystroke Simulation

    /// Inject text by simulating individual keystrokes via CGEvent.
    ///
    /// This is the slowest strategy but works for apps that do not respond to
    /// accessibility value writes or paste commands. Each character is sent as
    /// a key-down/key-up pair using CGEvent with Unicode input.
    private func injectViaKeystrokes(text: String, skipLeadingSpace: Bool = false) throws {
        let textToInject = skipLeadingSpace
            ? text : addLeadingSpaceIfNeededFromFocused(text: text)

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.allStrategiesFailed(bundleID: "cgevent-source-failed")
        }

        for scalar in textToInject.unicodeScalars {
            // Encode the scalar as UTF-16. Characters above U+FFFF
            // produce a surrogate pair (2 code units) that must be sent
            // together in a single event so the receiving app sees one
            // character, not two broken surrogates.
            var utf16Units = Array(String(scalar).utf16)

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            else {
                continue
            }
            guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                continue
            }

            keyDown.keyboardSetUnicodeString(
                stringLength: Int(utf16Units.count), unicodeString: &utf16Units)
            keyUp.keyboardSetUnicodeString(
                stringLength: Int(utf16Units.count), unicodeString: &utf16Units)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Small delay between keystrokes to avoid overwhelming the target app
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // MARK: - Paste Simulation

    /// Simulate Cmd+V (paste) using CGEvent.
    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // Virtual key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        else { return }
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard Preservation

    #if canImport(AppKit)
        /// Saved pasteboard item with its type and data.
        private struct SavedPasteboardItem {
            let types: [NSPasteboard.PasteboardType]
            let dataByType: [NSPasteboard.PasteboardType: Data]
        }

        /// Save all items from the pasteboard for later restoration.
        private func savePasteboardContents(_ pasteboard: NSPasteboard) -> [SavedPasteboardItem] {
            guard let items = pasteboard.pasteboardItems else { return [] }

            return items.compactMap { item in
                let types = item.types
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                guard !dataByType.isEmpty else { return nil }
                return SavedPasteboardItem(types: types, dataByType: dataByType)
            }
        }

        /// Restore previously saved items to the pasteboard.
        private func restorePasteboardContents(
            _ pasteboard: NSPasteboard, items: [SavedPasteboardItem]
        ) {
            guard !items.isEmpty else { return }

            pasteboard.clearContents()

            var pasteboardItems: [NSPasteboardItem] = []
            for saved in items {
                let item = NSPasteboardItem()
                for type in saved.types {
                    if let data = saved.dataByType[type] {
                        item.setData(data, forType: type)
                    }
                }
                pasteboardItems.append(item)
            }
            pasteboard.writeObjects(pasteboardItems)
        }
    #endif

    // MARK: - Main Thread Delay

    /// Wait for `seconds` while keeping the main run loop responsive.
    ///
    /// Use instead of `Thread.sleep` on the main thread so that UI events,
    /// animations, and pasteboard provider callbacks continue to process
    /// during the delay.
    static func mainThreadDelay(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    // MARK: - Smart Leading Space

    /// Add a leading space before the injected text if the character before the
    /// cursor is not whitespace or punctuation that typically precedes a word.
    ///
    /// - Parameters:
    ///   - text: The text to inject.
    ///   - fieldContent: The current content of the focused field.
    ///   - cursorPosition: The current cursor position in the field.
    /// - Returns: The text, potentially with a leading space prepended.
    func addLeadingSpaceIfNeeded(
        text: String,
        fieldContent: String?,
        cursorPosition: Int?
    ) -> String {
        InjectionSpacing().leadingSpaced(
            text: text,
            fieldContent: fieldContent,
            cursorPosition: cursorPosition)
    }

    /// Convert a UTF-16 offset to a String.Index, clamping to valid bounds.
    ///
    /// Accessibility APIs report positions in UTF-16 code units. This converts
    /// to a Swift String.Index suitable for string mutations. If the offset
    /// lands mid-grapheme, the index is rounded down to the nearest character
    /// boundary.
    private func stringIndexFromUTF16Offset(in string: String, utf16Offset: Int) -> String.Index {
        let utf16 = string.utf16
        let clamped = max(0, min(utf16Offset, utf16.count))
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: clamped)
        // Round down to the nearest Character boundary
        if let exact = String.Index(utf16Index, within: string) {
            return exact
        }
        // If we landed mid-grapheme, scan backward for a valid boundary
        var idx = utf16Index
        while idx > utf16.startIndex {
            utf16.formIndex(before: &idx)
            if let valid = String.Index(idx, within: string) {
                return valid
            }
        }
        return string.startIndex
    }

    /// Return the UTF-16 length of a string.
    ///
    /// Used to compute new cursor positions after string mutations, since
    /// Accessibility APIs expect UTF-16 offsets.
    private func utf16Count(of string: String) -> Int {
        return string.utf16.count
    }

    /// Add a leading space by reading the currently focused element's state.
    ///
    /// Used by pasteboard and keystroke strategies that don't receive a fresh
    /// AppContext. Reads the focused element directly via AXUIElement.
    private func addLeadingSpaceIfNeededFromFocused(text: String) -> String {
        guard let focused = AXElementHelper.focusedElement() else {
            return text
        }
        guard AXElementHelper.isTextInput(focused) else {
            return text
        }

        let content = AXElementHelper.textContent(of: focused)
        let cursorPos = AXElementHelper.cursorPosition(of: focused)

        return addLeadingSpaceIfNeeded(
            text: text,
            fieldContent: content,
            cursorPosition: cursorPos
        )
    }
}
