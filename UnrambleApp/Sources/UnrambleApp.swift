import UnrambleKit
import SwiftUI

@main
struct UnrambleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app only — no windows. Settings can be added later.
        Settings {
            EmptyView()
        }
    }
}
