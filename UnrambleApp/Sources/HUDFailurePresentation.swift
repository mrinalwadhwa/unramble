import AppKit
import UnrambleKit

/// Values that render recoverable dictation failures in the HUD.
struct HUDFailurePresentation: Equatable {
    let message: String
    let pillSize: CGSize
    let messageWidth: CGFloat?
    let maximumMessageLines: Int

    static let rateLimitMessage =
        "You've reached the rate limit for your OpenAI API key. Wait a moment and try again."

    /// The font used to render rate-limit guidance and measure its text region.
    static let messageFont: NSFont = {
        let systemFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        guard let roundedDescriptor = systemFont.fontDescriptor.withDesign(.rounded) else {
            return systemFont
        }
        return NSFont(descriptor: roundedDescriptor, size: systemFont.pointSize)
            ?? systemFont
    }()

    static let genericRetry = HUDFailurePresentation(
        message: "Lost connection",
        pillSize: CGSize(width: 220, height: 32),
        messageWidth: nil,
        maximumMessageLines: 1)

    static let genericNoRetry = HUDFailurePresentation(
        message: "Microphone unavailable",
        pillSize: CGSize(width: 220, height: 32),
        messageWidth: nil,
        maximumMessageLines: 1)

    static let rateLimited = HUDFailurePresentation(
        message: rateLimitMessage,
        pillSize: CGSize(width: 360, height: 48),
        messageWidth: 261,
        maximumMessageLines: 2)

    static func dictationFailure(
        failure: RecordingFailure?,
        retryAvailable: Bool
    ) -> HUDFailurePresentation {
        switch failure {
        case .rateLimited:
            return rateLimited
        case nil:
            return retryAvailable ? genericRetry : genericNoRetry
        }
    }
}
