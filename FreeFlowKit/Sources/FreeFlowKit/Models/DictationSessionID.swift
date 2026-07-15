import Foundation

/// Stable ownership token for one press-to-publication dictation lifecycle.
public struct DictationSessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
