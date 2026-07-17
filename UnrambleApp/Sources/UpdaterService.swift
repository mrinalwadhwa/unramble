import Foundation
import Sparkle

/// Manage Sparkle auto-updates using the appcast URL from Info.plist.
///
/// The `SUFeedURL` key in Info.plist points at the GitHub Releases
/// appcast. Sparkle reads the URL directly at check time; this class
/// just owns the updater controller and exposes the user-facing
/// actions.
@MainActor
final class UpdaterService: NSObject {

    private let updaterController: SPUStandardUpdaterController

    /// The underlying updater instance, exposed so the menu item can
    /// bind its enabled state and trigger manual checks.
    var updater: SPUUpdater {
        updaterController.updater
    }

    override init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        super.init()
    }

    /// Trigger a manual update check (for the "Check for Updates" menu
    /// item). Sparkle shows its standard UI.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Whether a manual check can be performed right now.
    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }
}
