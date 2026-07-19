import Foundation

/// Pure policy that chooses the ordered list of injection strategies to try for
/// a given app. Some apps handle Accessibility value writes well, while others —
/// terminals, Electron apps, browsers — are more reliable via the pasteboard or
/// synthesized keystrokes. Holds no state, so the ordering unit-tests in
/// isolation.
struct InjectionStrategySelector {

    /// Return the ordered list of strategies to try for the given bundle ID.
    ///
    /// Apps not in the map fall back to the default order:
    /// accessibility → pasteboard → keystroke.
    func strategies(for bundleID: String) -> [InjectionStrategy] {
        return Self.strategyMap[bundleID] ?? Self.defaultStrategies
    }

    /// Map bundle IDs to their preferred injection strategy order.
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
}
