import Foundation

@testable import UnrambleKit

extension LocalStreamingProvider {
    /// Drive the retained production Retry path without a wall-clock timer.
    /// Tests choose the deterministic slice size through the provider's
    /// `cycleInterval` initializer argument.
    func replayForTesting(
        _ pcmData: Data,
        context: AppContext = .empty,
        silenceThreshold: Float = AudioLevelAnalyzer.minimumAcceptedSpeechRMS
    ) async throws -> String {
        try await replayCapturedAudio(
            pcmData,
            sessionID: DictationSessionID(),
            context: context,
            language: nil,
            micProximity: .farField,
            silenceThreshold: silenceThreshold)
    }
}
