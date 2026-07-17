import Foundation

/// Orchestrates the full dictation pipeline: hotkey → record + read context →
/// stop recording → process audio → inject text.
///
/// Implementations wire together an `AudioProviding`, `AppContextProviding`,
/// and `TextInjecting` to drive the end-to-end flow. The recording state
/// machine lives behind this protocol.
public protocol PipelineProviding: Sendable {

    /// Called when the hotkey is pressed. Starts audio recording and
    /// begins reading app context in parallel.
    @discardableResult
    func activate() async -> DictationSessionID?

    /// Start the session owned by one physical press. The release boundary is
    /// shared directly with capture so key-up does not wait for actor delivery.
    @discardableResult
    func activate(
        releaseBoundary: AudioCaptureReleaseBoundary
    ) async -> DictationSessionID?

    /// Called when the hotkey is released. Stops recording, sends audio
    /// and context through the processing pipeline, and injects the
    /// resulting text into the active app.
    func complete() async

    /// Complete only the recording accepted for this physical key press.
    /// A stale release must not stop a replacement recording.
    func complete(sessionID: DictationSessionID) async

    /// Complete a physical key press at its event-tap host timestamp. Carrying
    /// the timestamp through actor scheduling prevents release latency from
    /// admitting audio captured after key-up.
    func complete(
        sessionID: DictationSessionID,
        releaseHostTime: UInt64
    ) async

    /// Cancels an in-progress pipeline run and resets to idle.
    func cancel() async

    /// Cancel only the session captured by the initiating UI action.
    func cancel(sessionID: DictationSessionID) async

    /// The current recording state. Observe this to drive UI updates
    /// (menu bar icon, HUD overlay).
    var state: RecordingState { get async }

    /// Session that currently owns capture, processing, and publication.
    var currentSessionID: DictationSessionID? { get async }
}

extension PipelineProviding {
    public func activate(
        releaseBoundary: AudioCaptureReleaseBoundary
    ) async -> DictationSessionID? {
        await activate()
    }

    public func complete(
        sessionID: DictationSessionID,
        releaseHostTime: UInt64
    ) async {
        await complete(sessionID: sessionID)
    }
}
