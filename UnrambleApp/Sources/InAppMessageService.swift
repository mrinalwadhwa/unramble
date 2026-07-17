import Foundation
import UnrambleKit

/// A message fetched from a remote JSON file to display in the HUD.
struct InAppMessage: Codable, Equatable {
    let id: String
    let text: String
    let action: String?
    let url: String?
    let minVersion: String?
}

/// Fetch and filter in-app messages from a static JSON file on GitHub.
///
/// Messages are fetched once on app launch. The service tracks which
/// messages have been permanently dismissed and ensures each message
/// is shown at most once per day (after the first successful dictation).
@MainActor
final class InAppMessageService {

    private static let messageURL = URL(
        string: "https://github.com/mrinalwadhwa/unramble/releases/latest/download/messages.json"
    )!

    private static let dismissedIDsKey = "inAppMessageDismissedIDs"
    private static let lastShownDateKey = "inAppMessageLastShownDate"

    private var fetchedMessage: InAppMessage?

    /// In DEBUG builds, set `UNRAMBLE_TEST_MESSAGE` to a file path to
    /// load a local message instead of fetching from GitHub. All
    /// date and dismissed filters are bypassed so the message shows
    /// on every dictation.
    ///
    ///     echo '{"id":"test","text":"Hello from Unramble!"}' > /tmp/message.json
    ///     UNRAMBLE_TEST_MESSAGE=/tmp/message.json make run
    var isTestMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["UNRAMBLE_TEST_MESSAGE"] != nil
        #else
        return false
        #endif
    }

    /// Fetch the message file from GitHub. Failures are silently ignored.
    ///
    /// In DEBUG builds with `UNRAMBLE_TEST_MESSAGE` set, loads from
    /// that local file path instead.
    func fetch() async {
        do {
            let data: Data
            #if DEBUG
            if let testPath = ProcessInfo.processInfo.environment["UNRAMBLE_TEST_MESSAGE"] {
                data = try Data(contentsOf: URL(fileURLWithPath: testPath))
                Log.debug("[InAppMessage] Loaded test message from \(testPath)")
            } else {
                (data, _) = try await URLSession.shared.data(from: Self.messageURL)
            }
            #else
            (data, _) = try await URLSession.shared.data(from: Self.messageURL)
            #endif
            let message = try JSONDecoder().decode(InAppMessage.self, from: data)
            fetchedMessage = message
            Log.debug("[InAppMessage] Fetched message: \(message.id)")
        } catch {
            Log.debug("[InAppMessage] Fetch failed (ignored): \(error)")
        }
    }

    /// Return the fetched message if it should be shown right now.
    ///
    /// A message is eligible when:
    /// - It has not been permanently dismissed.
    /// - It has not already been shown today.
    /// - The app version meets the optional `minVersion` requirement.
    ///
    /// In test mode, all filters are bypassed.
    func messageToShow() -> InAppMessage? {
        guard let message = fetchedMessage else { return nil }

        if isTestMode { return message }

        let defaults = UserDefaults.standard
        let dismissed = Set(defaults.stringArray(forKey: Self.dismissedIDsKey) ?? [])
        if dismissed.contains(message.id) { return nil }

        if let minVersion = message.minVersion, !meetsMinVersion(minVersion) {
            return nil
        }

        let today = dateString(from: Date())
        let lastShown = defaults.string(forKey: Self.lastShownDateKey)
        if lastShown == today { return nil }

        return message
    }

    /// Record that a message was shown today so it does not repeat.
    /// No-op in test mode.
    func markShownToday() {
        if isTestMode { return }
        let today = dateString(from: Date())
        UserDefaults.standard.set(today, forKey: Self.lastShownDateKey)
    }

    /// Permanently dismiss a message so it never shows again.
    /// No-op in test mode.
    func markDismissed(_ id: String) {
        if isTestMode {
            Log.debug("[InAppMessage] Dismiss ignored (test mode): \(id)")
            return
        }
        let defaults = UserDefaults.standard
        var dismissed = defaults.stringArray(forKey: Self.dismissedIDsKey) ?? []
        if !dismissed.contains(id) {
            dismissed.append(id)
            defaults.set(dismissed, forKey: Self.dismissedIDsKey)
        }
        Log.debug("[InAppMessage] Dismissed: \(id)")
    }

    // MARK: - Helpers

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func meetsMinVersion(_ minVersion: String) -> Bool {
        guard let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return false }
        return appVersion.compare(minVersion, options: .numeric) != .orderedAscending
    }
}
