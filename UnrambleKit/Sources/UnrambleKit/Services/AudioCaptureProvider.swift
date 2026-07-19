import Foundation
import ObjCExceptionCatcher

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(CoreAudio)
    import CoreAudio
#endif

enum AudioCaptureConfigurationChangeAction: Equatable, Sendable {
    case ignore
    case rebuildIdleEngine
    case invalidateActiveCapture
}

enum AudioCaptureConfigurationChangePolicy {
    static func action(
        isRecording: Bool,
        inputFormatChanged: Bool
    ) -> AudioCaptureConfigurationChangeAction {
        guard isRecording else { return .rebuildIdleEngine }
        return inputFormatChanged ? .invalidateActiveCapture : .ignore
    }
}

/// Publishes preview coverage independently of the provider's engine lock.
/// Exact tokens prevent delayed teardown from clearing a replacement tap.
final class AudioPreviewPreRollPublication<Token: Equatable & Sendable>:
    @unchecked Sendable
{
    private struct Entry: Sendable {
        let token: Token
        let hasCoverage: @Sendable (UInt64) -> Bool
    }

    private let lock = NSLock()
    private var entry: Entry?

    func publish(
        for token: Token,
        hasCoverage: @escaping @Sendable (UInt64) -> Bool
    ) {
        lock.withLock {
            entry = Entry(token: token, hasCoverage: hasCoverage)
        }
    }

    @discardableResult
    func clear(for token: Token) -> Bool {
        lock.withLock {
            guard entry?.token == token else { return false }
            entry = nil
            return true
        }
    }

    func reset() {
        lock.withLock { entry = nil }
    }

    func canRecover(at pressHostTime: UInt64) -> Bool {
        let hasCoverage = lock.withLock { entry?.hasCoverage }
        return hasCoverage?(pressHostTime) ?? false
    }
}

/// Owns release observation and final converter drain as one deadline-bounded
/// operation. A deadline observer can close hardware without cancelling or
/// joining work that still owns the router and converter.
final class AudioCaptureStopDrain<Value: Sendable>: @unchecked Sendable {
    enum Result: Sendable {
        case releaseRejected
        case finalized(Value)
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var stage: AudioCaptureIntegrityFailure.Stage = .releaseDrain

        func beginFinalization() {
            lock.withLock { stage = .converterDrain }
        }

        var timeoutFailure: AudioCaptureIntegrityFailure {
            lock.withLock {
                AudioCaptureIntegrityFailure(
                    stage: stage,
                    affectedFrameCount: nil)
            }
        }
    }

    private let progress = Progress()
    private let operation: DetachedOperation<Result>

    init(
        observeRelease: @escaping @Sendable () async -> Bool,
        finalize: @escaping @Sendable () -> Value
    ) {
        let progress = progress
        operation = DetachedOperation {
            guard await observeRelease() else { return .releaseRejected }
            progress.beginFinalization()
            return .finalized(finalize())
        }
    }

    var task: Task<Result, Never> { operation.task }
    var timeoutFailure: AudioCaptureIntegrityFailure { progress.timeoutFailure }

    func outcome(
        timeout: TimeInterval
    ) async -> DetachedOperationObservation<Result> {
        await operation.outcome(timeout: timeout)
    }
}

/// Closes the capture device synchronously, then owns cleanup that may block
/// behind an in-flight callback. The same task is used for deadline observation
/// and retained cleanup so replacement capture cannot race a late tap removal.
final class AudioCapturePhysicalStop<CleanupResult: Sendable>: Sendable {
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isClaimed = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func claim() -> Bool {
            lock.withLock {
                guard !isClaimed else { return false }
                isClaimed = true
                return true
            }
        }

        func waitUntilOpen() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    guard !isOpen else { return true }
                    waiters.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }

        func open() {
            let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
                guard !isOpen else { return [] }
                isOpen = true
                let continuations = waiters
                waiters.removeAll(keepingCapacity: false)
                return continuations
            }
            continuations.forEach { $0.resume() }
        }
    }

    private let startGate: StartGate
    private let cleanup: DetachedOperation<CleanupResult>

    fileprivate init(
        cleanup: @escaping @Sendable () -> CleanupResult
    ) {
        let startGate = StartGate()
        self.startGate = startGate
        self.cleanup = DetachedOperation {
            await startGate.waitUntilOpen()
            return cleanup()
        }
    }

    convenience init(
        closeHardware: () -> Void,
        cleanup: @escaping @Sendable () -> CleanupResult
    ) {
        self.init(cleanup: cleanup)
        startOnce(closeHardware)
    }

    fileprivate func startOnce(_ closeHardware: () -> Void) {
        guard startGate.claim() else { return }
        closeHardware()
        startGate.open()
    }

    var task: Task<CleanupResult, Never> { cleanup.task }

    func outcome(
        timeout: TimeInterval
    ) async -> DetachedOperationObservation<CleanupResult> {
        await cleanup.outcome(timeout: timeout)
    }
}

/// Publishes one retained physical-stop operation per exact capture token.
/// Stop, reset, and shutdown callers join the same tap removal instead of
/// issuing concurrent cleanup against one input node.
final class AudioCapturePhysicalStopLedger<
    Token: Equatable & Sendable,
    CleanupResult: Sendable
>: @unchecked Sendable {
    private struct Entry {
        let token: Token
        let stop: AudioCapturePhysicalStop<CleanupResult>
        var isCompleting = false
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func beginOrJoin(
        for token: Token,
        closeHardware: () -> Void,
        cleanup: @escaping @Sendable () -> CleanupResult
    ) -> AudioCapturePhysicalStop<CleanupResult> {
        let stop = lock.withLock {
            if let existing = entries.first(where: { $0.token == token }) {
                return existing.stop
            }
            let stop = AudioCapturePhysicalStop(cleanup: cleanup)
            entries.append(Entry(token: token, stop: stop))
            return stop
        }
        stop.startOnce(closeHardware)
        return stop
    }

    var hasRetainedStops: Bool {
        lock.withLock { !entries.isEmpty }
    }

    /// Elect the only state finalizer while retaining the published stop so a
    /// concurrent caller cannot create a second operation in the cleanup gap.
    @discardableResult
    func claimCompletion(_ token: Token) -> Bool {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.token == token }),
                !entries[index].isCompleting
            else { return false }
            entries[index].isCompleting = true
            return true
        }
    }

    /// Release only the exact retained operation after its cleanup task ends.
    /// A stale finalizer cannot clear another capture generation.
    @discardableResult
    func finish(_ token: Token) -> Bool {
        lock.withLock {
            guard let index = entries.firstIndex(where: {
                $0.token == token && $0.isCompleting
            }) else { return false }
            entries.remove(at: index)
            return true
        }
    }
}

/// Elects the only publisher of the provider's retained shutdown finalizer.
final class AudioCaptureShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    @discardableResult
    func claim() -> Bool {
        lock.withLock {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }
}

#if canImport(AVFoundation)
    /// AVAudioEngine is not Sendable, but this owner never replaces its engine
    /// and serializes stop/remove through one retained physical-stop operation.
    private final class AudioEngineTapControl: @unchecked Sendable {
        let engine: AVAudioEngine

        init(engine: AVAudioEngine) {
            self.engine = engine
        }

        func stopEngine() {
            engine.stop()
        }

        func removeTap() -> AudioCaptureError? {
            let exception = ObjCTryCatch {
                engine.inputNode.removeTap(onBus: 0)
            }
            guard let exception else { return nil }
            return .engineStopFailed(
                exception.reason ?? exception.name.rawValue)
        }
    }
#endif

/// Tracks ownership of an audio-engine start independently of the provider's
/// main state lock. A timeout can therefore invalidate and reach the engine
/// even while `AVAudioEngine.start()` is holding that main lock.
final class AudioEngineStartResetLedger<Engine: AnyObject>: @unchecked Sendable {
    struct Attempt: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    struct Invalidation {
        let attempt: Attempt
        let engine: Engine?
    }

    private struct Entry {
        let attempt: Attempt
        let owner: AudioCaptureOwner?
        var engine: Engine?
        var isValid = true
        var isCaptureReady = false
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var active: Entry?

    func begin() -> Attempt {
        guard let attempt = beginIfIdle(owner: nil) else {
            preconditionFailure("An audio-engine start attempt is already active")
        }
        return attempt
    }

    func beginIfIdle(owner: AudioCaptureOwner? = nil) -> Attempt? {
        lock.withLock {
            guard active == nil else { return nil }
            nextID &+= 1
            let attempt = Attempt(id: nextID)
            active = Entry(attempt: attempt, owner: owner)
            return attempt
        }
    }

    func activeAttempt(ownedBy owner: AudioCaptureOwner) -> Attempt? {
        lock.withLock {
            guard active?.owner == owner else { return nil }
            return active?.attempt
        }
    }

    func hasReadyCapture(ownedBy owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            active?.owner == owner
                && active?.isValid == true
                && active?.isCaptureReady == true
        }
    }

    var hasReadyCapture: Bool {
        lock.withLock {
            active?.isValid == true && active?.isCaptureReady == true
        }
    }

    /// The exact attempt remains published after invalidation until its retained
    /// stop owner finishes hardware, tap, and provider-state cleanup.
    var activeInvalidation: Invalidation? {
        lock.withLock {
            guard let entry = active else { return nil }
            return Invalidation(attempt: entry.attempt, engine: entry.engine)
        }
    }

    @discardableResult
    func publish(_ engine: Engine, for attempt: Attempt) -> Bool {
        lock.withLock {
            guard active?.attempt == attempt, active?.isValid == true else {
                return false
            }
            active?.engine = engine
            return true
        }
    }

    func invalidateActiveAttempt() -> Invalidation? {
        lock.withLock {
            guard let entry = active, entry.isValid else { return nil }
            active?.isValid = false
            return Invalidation(attempt: entry.attempt, engine: entry.engine)
        }
    }

    /// Interrupt only an engine start that has not published capture readiness.
    /// A ready engine belongs to the serialized stop/shutdown transition.
    func invalidateActiveStartingAttempt() -> Invalidation? {
        lock.withLock {
            guard let entry = active,
                entry.isValid,
                !entry.isCaptureReady
            else { return nil }
            active?.isValid = false
            return Invalidation(attempt: entry.attempt, engine: entry.engine)
        }
    }

    func invalidateActiveAttempt(
        ownedBy owner: AudioCaptureOwner
    ) -> Invalidation? {
        lock.withLock {
            guard let entry = active, entry.owner == owner, entry.isValid else {
                return nil
            }
            active?.isValid = false
            return Invalidation(attempt: entry.attempt, engine: entry.engine)
        }
    }

    func isValid(_ attempt: Attempt) -> Bool {
        lock.withLock {
            active?.attempt == attempt && active?.isValid == true
        }
    }

    @discardableResult
    func withValidAttempt(_ attempt: Attempt, _ body: () -> Void) -> Bool {
        lock.withLock {
            guard active?.attempt == attempt, active?.isValid == true else {
                return false
            }
            body()
            return true
        }
    }

    /// Publish capture state and readiness at one reset boundary. A reset can
    /// linearize before both callbacks or after both callbacks, never between
    /// recording becoming live and the pipeline observing that fact.
    @discardableResult
    func commitCaptureReady(
        _ attempt: Attempt,
        publish: () -> Void,
        onCaptureReady: () -> Void
    ) -> Bool {
        withValidAttempt(attempt) {
            publish()
            active?.isCaptureReady = true
            onCaptureReady()
        }
    }

    func end(_ attempt: Attempt) {
        lock.withLock {
            guard active?.attempt == attempt else { return }
            active = nil
        }
    }
}

/// Fences tap callbacks independently of the provider's main state lock.
/// Closing a boundary timestamps release while callbacks remain admissible for
/// pre-release sample classification until normal stop drains them. Reset
/// invalidates all admissions before a replacement can publish state.
final class AudioCapturePublicationLedger<Token: Equatable & Sendable>:
    @unchecked Sendable
{
    struct Publication: Sendable {
        fileprivate let token: Token
        fileprivate let generation: UInt64
    }

    struct CallbackAdmission: Sendable {
        fileprivate let token: Token
        fileprivate let generation: UInt64
    }

    private enum Phase {
        case open
        case draining(releaseHostTime: UInt64)
    }

    private struct Entry {
        let token: Token
        let generation: UInt64
        let releaseBoundary: AudioCaptureReleaseBoundary?
        var phase: Phase
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var entry: Entry?

    var canBegin: Bool {
        lock.withLock { entry == nil }
    }

    var drainingToken: Token? {
        lock.withLock {
            guard let entry else { return nil }
            guard case .draining = entry.phase else { return nil }
            return entry.token
        }
    }

    @discardableResult
    func begin(
        _ token: Token,
        releaseBoundary: AudioCaptureReleaseBoundary? = nil
    ) -> Publication {
        lock.withLock {
            precondition(entry == nil, "An audio capture publication is still owned")
            nextGeneration &+= 1
            entry = Entry(
                token: token,
                generation: nextGeneration,
                releaseBoundary: releaseBoundary,
                phase: .open)
            return Publication(token: token, generation: nextGeneration)
        }
    }

    /// Admit one callback owned by this publication. Draining callbacks remain
    /// admissible because a queued buffer can straddle the release timestamp.
    func admitCallback(for publication: Publication) -> CallbackAdmission? {
        lock.withLock {
            guard let entry,
                entry.token == publication.token,
                entry.generation == publication.generation
            else {
                return nil
            }
            return CallbackAdmission(
                token: publication.token,
                generation: publication.generation)
        }
    }

    /// Timestamp release and enter the drain phase. This is idempotent so
    /// `stopRecording()` can join a boundary closed synchronously earlier.
    @discardableResult
    func beginDraining(
        _ token: Token,
        releaseHostTime: UInt64 = AudioCaptureReleaseFence.currentHostTime()
    ) -> Bool {
        lock.withLock {
            guard var entry, entry.token == token else { return false }
            if case .open = entry.phase {
                entry.phase = .draining(releaseHostTime: releaseHostTime)
                self.entry = entry
            }
            return true
        }
    }

    /// Close whichever capture currently owns publication. This token-free
    /// entry point lets the provider publish the sample-time boundary without
    /// first taking the main engine lock.
    @discardableResult
    func beginDrainingCurrentCapture(
        releaseHostTime: UInt64 = AudioCaptureReleaseFence.currentHostTime()
    ) -> Bool {
        lock.withLock {
            guard var entry else { return false }
            if case .open = entry.phase {
                entry.phase = .draining(releaseHostTime: releaseHostTime)
                self.entry = entry
            }
            return true
        }
    }

    /// Whether a callback admitted before the boundary may still publish.
    /// Reset invalidates its generation; normal draining does not.
    func accepts(_ admission: CallbackAdmission) -> Bool {
        lock.withLock {
            guard let entry else { return false }
            return entry.token == admission.token
                && entry.generation == admission.generation
        }
    }

    /// Return the exact sample prefix owned by this publication. Callbacks may
    /// enter during drain so a queued buffer can retain samples captured before
    /// release while excluding samples at or after the release timestamp.
    func preReleaseFrameCount(
        for admission: CallbackAdmission,
        bufferStartHostTime: UInt64?,
        sampleRate: Double,
        frameLength: Int
    ) -> Int? {
        lock.withLock {
            guard let entry,
                entry.token == admission.token,
                entry.generation == admission.generation
            else { return nil }

            let physicalReleaseHostTime = entry.releaseBoundary?.releaseHostTime
            let releaseHostTime: UInt64?
            switch entry.phase {
            case .open:
                releaseHostTime = physicalReleaseHostTime
            case .draining(let drainedReleaseHostTime):
                releaseHostTime = physicalReleaseHostTime.map {
                    min($0, drainedReleaseHostTime)
                } ?? drainedReleaseHostTime
            }

            guard let releaseHostTime else {
                return frameLength
            }
            // AVAudioEngine normally supplies a valid first-sample host time.
            // If it does not, retain the buffer: preserving dictated speech is
            // more important than excluding an unknowable post-release suffix.
            guard let bufferStartHostTime else { return frameLength }
            return AudioCaptureReleaseFence.preReleaseFrameCount(
                bufferStartHostTime: bufferStartHostTime,
                releaseHostTime: releaseHostTime,
                sampleRate: sampleRate,
                frameLength: frameLength)
        }
    }

    func finishDraining(_ token: Token) {
        lock.withLock {
            guard let entry, entry.token == token else { return }
            guard case .draining = entry.phase else { return }
            self.entry = nil
        }
    }

    func reset() {
        lock.withLock {
            entry = nil
        }
    }

    /// Reset only the named capture. A delayed stop must not invalidate a
    /// replacement capture that has already opened a new generation.
    @discardableResult
    func reset(_ token: Token) -> Bool {
        lock.withLock {
            guard entry?.token == token else { return false }
            entry = nil
            return true
        }
    }
}

/// Capture audio from the default input device via AVAudioEngine.
///
/// Records audio and converts it to 16kHz, mono, 16-bit PCM. On stop,
/// the accumulated samples are WAV-encoded into an `AudioBuffer`.
///
/// The engine is created once on the first `startRecording()` call and
/// kept running across sessions. Start/stop only installs and removes
/// the input tap, avoiding the 0.5-1.2s engine setup cost on each
/// press. The engine is torn down on audio device changes
/// (`AVAudioEngineConfigurationChange`) and rebuilt on the next
/// recording. Call `shutdown()` on app termination.
///
/// Requires microphone permission before calling `startRecording()`.
public final class AudioCaptureProvider: AudioProviding, @unchecked Sendable {

    /// Target audio format for dictation: 16kHz, mono, 16-bit integer PCM.
    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBitsPerSample = 16

    private let lock = NSLock()
    private var _isRecording = false
    private let captureTransitions = AsyncSerialOperationQueue()
    private let captureDemands = AudioCaptureDemandLedger()

    #if canImport(AVFoundation)
        private typealias CaptureAttempt =
            AudioEngineStartResetLedger<AVAudioEngine>.Attempt
        private typealias CaptureCallbackAdmission =
            AudioCapturePublicationLedger<CaptureAttempt>.CallbackAdmission
        private typealias CapturePublication =
            AudioCapturePublicationLedger<CaptureAttempt>.Publication

        private enum PhysicalStopToken: Equatable, Sendable {
            case attempt(CaptureAttempt)
            case shutdownIdleEngine
        }

        private let engineStartResetLedger = AudioEngineStartResetLedger<AVAudioEngine>()
        private var recordingStartAttempt: CaptureAttempt?
        private let publicationLedger =
            AudioCapturePublicationLedger<CaptureAttempt>()
        private let captureSinkOwnership =
            AudioCaptureSinkOwnershipLedger<CaptureAttempt>()
        private let previewPreRollPublication =
            AudioPreviewPreRollPublication<CaptureAttempt>()
        private let physicalStopLedger = AudioCapturePhysicalStopLedger<
            PhysicalStopToken,
            AudioCaptureError?
        >()
        private let shutdownGate = AudioCaptureShutdownGate()
        private var startCleanupInProgress = false

        private struct PhysicalCaptureIdentity {
            let starterOwner: AudioCaptureOwner
            let attempt: CaptureAttempt
            let router: TimestampedAudioFrameRouter
        }

        private struct DictationCaptureIdentity {
            let owner: AudioCaptureOwner
            let sink: DictationAudioSink
            let sinkToken: DictationAudioSinkPublication.Token
            let route: TimestampedAudioFrameRouter.Route
        }

        private struct DictationStopFinalization: Sendable {
            let completion: DictationAudioSink.Completion
            let metrics: AudioCaptureMetrics
        }

        private struct AbortedDictationStop {
            let capture: DictationCaptureIdentity
            let physical: PhysicalCaptureIdentity
            let engine: AVAudioEngine
        }

        private struct PreviewLevelSource {
            let stream: AsyncStream<Float>
            let continuation: AsyncStream<Float>.Continuation
        }

        private enum DemandResetClaim {
            case dictation(
                capture: DictationCaptureIdentity,
                physical: PhysicalCaptureIdentity,
                engineToStop: AVAudioEngine?
            )
            case preview(
                physical: PhysicalCaptureIdentity?,
                engineToStop: AVAudioEngine?
            )
            case none
        }

        final class StopOperation: @unchecked Sendable {
            typealias CaptureResult = Result<AudioBuffer, any Error>

            final class ResultPublication: @unchecked Sendable {
                private enum State {
                    case pending([
                        CheckedContinuation<CaptureResult, Never>
                    ])
                    case published(CaptureResult)
                }

                private let lock = NSLock()
                private var state: State = .pending([])

                func publish(_ result: CaptureResult) {
                    let waiters: [CheckedContinuation<CaptureResult, Never>] =
                        lock.withLock {
                            guard case .pending(let waiters) = state else {
                                return []
                            }
                            state = .published(result)
                            return waiters
                        }
                    waiters.forEach { $0.resume(returning: result) }
                }

                func value() async -> CaptureResult {
                    await withCheckedContinuation { continuation in
                        let published: CaptureResult? = lock.withLock {
                            switch state {
                            case .pending(var waiters):
                                waiters.append(continuation)
                                state = .pending(waiters)
                                return nil
                            case .published(let result):
                                return result
                            }
                        }
                        if let published {
                            continuation.resume(returning: published)
                        }
                    }
                }
            }

            let id = UUID()
            let owner: AudioCaptureOwner

            private let lock = NSLock()
            private let publication = ResultPublication()
            private let operation: @Sendable (ResultPublication) async -> CaptureResult
            private var task: Task<CaptureResult, Never>?
            private var completed = false

            init(
                owner: AudioCaptureOwner,
                operation: @escaping @Sendable (ResultPublication) async ->
                    CaptureResult
            ) {
                self.owner = owner
                self.operation = operation
            }

            var isCompleted: Bool {
                lock.withLock { completed }
            }

            func result() async -> CaptureResult {
                lock.withLock {
                    guard task == nil else { return }
                    let operation = operation
                    let publication = publication
                    task = Task.detached { [weak self] in
                        let result = await operation(publication)
                        publication.publish(result)
                        guard let self else { return result }
                        lock.withLock { self.completed = true }
                        return result
                    }
                }
                return await publication.value()
            }
        }

        private var physicalCapture: PhysicalCaptureIdentity?
        private var previewOwner: AudioCaptureOwner?
        private var previewLevelSource: PreviewLevelSource?
        private var dictationCapture: DictationCaptureIdentity?
        private let dictationSinkPublication = DictationAudioSinkPublication()
        private var metricsOwner: AudioCaptureOwner?
        private var retainedMetrics: AudioCaptureMetrics?

        private var stopOperations: [AudioCaptureOwner: StopOperation] = [:]
        private var isPhysicalStopInProgress = false
    #endif

    private var legacyOwner: AudioCaptureOwner?

    private var _peakRMS: Float = 0
    private var _ambientRMS: Float = 0
    private var _ambientSampleCount: Int = 0
    private var _ambientSumOfSquares: Double = 0
    private var _ambientCalibrated: Bool = false
    private var _micProximity: MicProximity = .nearField
    private var _deviceName: String = "System Default"
    private var pcmChunks: [Data] = []

    /// Software gain factor applied to outbound PCM audio for far-field
    /// (built-in) mics. Lifts quiet speech and whispers into a range
    /// where the server's transcription model works reliably. Computed
    /// once after ambient calibration completes. Near-field mics always
    /// use 1.0 (no gain). Raw peak/ambient RMS values are unaffected
    /// so the silence gate logic is unchanged.
    private var _droppedFrameCount: Int = 0
    private var _gainFactor: Float = 1.0

    /// Target RMS level for gained audio. Quiet speech on a near-field
    /// mic produces RMS ~0.02; lifting far-field audio to this level
    /// gives the transcription model a strong signal without clipping.
    private static let targetGainRMS: Float = 0.02

    /// Maximum gain multiplier. Caps amplification to prevent noise
    /// from being amplified into distortion. At 16x, a sample of
    /// ±2048 (RMS ~0.06, loud speech) reaches ±32768 (Int16 boundary).
    private static let maxGainFactor: Float = 16.0

    /// Optional sound feedback provider for start/stop audio cues.
    private var _soundFeedbackProvider: SoundFeedbackProvider?

    /// Optional device provider for mic selection. When set, the engine
    /// is configured to capture from the selected device instead of the
    /// system default.
    private weak var _audioDeviceProvider: (any AudioInputDeviceSnapshotProviding)?

    /// The device ID the engine was last configured with, or nil for
    /// system default. Used to detect when the device changed and the
    /// engine needs rebuilding.
    private var _configuredDeviceID: UInt32?

    /// Requests a fresh engine at the next start. This covers an active
    /// format change as well as a device-list change observed while idle.
    private var _needsEngineRebuild: Bool = false

    #if canImport(AVFoundation)
        /// Persistent engine, created on first recording and reused.
        private var engine: AVAudioEngine?
        private var converterLifecycle: PCMConverterLifecycle?
        /// The tap format negotiated with the hardware on engine creation.
        private var tapFormat: AVAudioFormat?
        /// Observer token for audio device configuration changes.
        private var configChangeObserver: NSObjectProtocol?
    #endif

    // MARK: - PCM audio stream

    private let pcmStreamSnapshot = AudioCapturePCMStreamSnapshot()
    private var pcmContinuation: AsyncStream<Data>.Continuation?

    public var pcmAudioStream: AsyncStream<Data>? {
        pcmStreamSnapshot.current
    }

    // MARK: - Audio level stream

    private var _audioLevelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    public var audioLevelStream: AsyncStream<Float>? {
        lock.withLock {
            if let legacyOwner,
                dictationCapture?.owner == legacyOwner
            {
                return dictationCapture?.sink.levelStream
            }
            return previewLevelSource?.stream
        }
    }

    /// The highest RMS level observed during the current (or most recent)
    /// recording session. Reset to 0 on each `startRecording()`. The
    /// pipeline reads this after `stopRecording()` to detect silent
    /// presses before sending audio to the server.
    public var peakRMS: Float {
        lock.withLock {
            dictationCapture?.sink.metrics.peakRMS
                ?? retainedMetrics?.peakRMS
                ?? _peakRMS
        }
    }

    /// The ambient (background noise) RMS level measured during the first
    /// ~0.5s of the current or most recent recording session. Used by
    /// the pipeline to compute an adaptive silence threshold.
    ///
    /// Returns 0 if calibration has not completed (recording shorter
    /// than 0.5s or no recording yet).
    public var ambientRMS: Float {
        lock.withLock {
            dictationCapture?.sink.metrics.ambientRMS
                ?? retainedMetrics?.ambientRMS
                ?? _ambientRMS
        }
    }

    /// Mic proximity of the device used for the current or most recent
    /// recording session. Set during engine creation based on the
    /// configured device's transport type. Defaults to `.nearField`.
    public var micProximity: MicProximity {
        lock.withLock {
            dictationCapture?.sink.metrics.micProximity
                ?? retainedMetrics?.micProximity
                ?? _micProximity
        }
    }

    /// The software gain factor applied to outbound audio for the
    /// current or most recent recording session. Far-field mics use
    /// 10-16x; near-field mics use 1.0.
    public var gainFactor: Float {
        lock.withLock {
            dictationCapture?.sink.metrics.gainFactor
                ?? retainedMetrics?.gainFactor
                ?? _gainFactor
        }
    }

    /// The name of the audio device used for the current or most
    /// recent recording session. Set during engine creation.
    public var deviceName: String {
        lock.withLock {
            dictationCapture?.sink.metrics.deviceName
                ?? retainedMetrics?.deviceName
                ?? _deviceName
        }
    }

    public init() {}

    /// Set the device provider used for mic selection.
    ///
    /// Call once during setup, before the first recording session. The
    /// provider is held weakly to avoid retain cycles with `AppDelegate`.
    public func setAudioDeviceProvider(_ provider: any AudioInputDeviceSnapshotProviding) {
        lock.withLock { _audioDeviceProvider = provider }
    }

    /// Set the sound feedback provider for start/stop audio cues.
    ///
    /// Call once during setup. The provider uses its own dedicated
    /// playback engine; this reference lets `startRecording()` and
    /// `stopRecording()` trigger sounds at the exact moments the
    /// capture state changes. Pass `nil` to mute sound cues (e.g.
    /// during mic preview in the settings window).
    public func setSoundFeedbackProvider(_ provider: SoundFeedbackProvider?) {
        lock.withLock { _soundFeedbackProvider = provider }
    }

    deinit {
        #if canImport(AVFoundation)
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            engine?.stop()
        #endif
    }

    // MARK: - AudioProviding

    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    public func isRecording(owner: AudioCaptureOwner) -> Bool {
        #if canImport(AVFoundation)
            lock.withLock {
                _isRecording
                    && (previewOwner == owner || dictationCapture?.owner == owner)
            }
        #else
            false
        #endif
    }

    public func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        #if canImport(AVFoundation)
            lock.withLock {
                guard let capture = dictationCapture,
                    capture.owner == owner
                else { return nil }
                return capture.sink.pcmStream
            }
        #else
            nil
        #endif
    }

    public func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        #if canImport(AVFoundation)
            lock.withLock {
                if previewOwner == owner {
                    return previewLevelSource?.stream
                }
                guard let capture = dictationCapture,
                    capture.owner == owner
                else { return nil }
                return capture.sink.levelStream
            }
        #else
            nil
        #endif
    }

    public func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        #if canImport(AVFoundation)
            lock.withLock {
                guard metricsOwner == owner else { return nil }
                return dictationCapture?.owner == owner
                    ? dictationCapture?.sink.metrics
                    : retainedMetrics
            }
        #else
            nil
        #endif
    }

    public func canRecoverCaptureReleasedBeforeReadiness(
        owner: AudioCaptureOwner,
        pressHostTime: UInt64
    ) -> Bool {
        canAdmitDictationPress(at: pressHostTime)
    }

    /// Synchronously proves that the currently published preview generation
    /// can promote this physical key-down without losing its leading audio.
    /// The hotkey callback checks this before admitting the press so an async
    /// availability update cannot race a capture reset.
    public func canAdmitDictationPress(at pressHostTime: UInt64) -> Bool {
        #if canImport(AVFoundation)
            // Fast key-up can race demand registration. This read-only preview
            // proof is generation-scoped; promotion still validates the owner.
            return previewPreRollPublication.canRecover(at: pressHostTime)
        #else
            return false
        #endif
    }

    public func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    public func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let owner = AudioCaptureOwner.preview()
        lock.withLock { legacyOwner = owner }
        do {
            try await startRecordingOwned(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: nil,
                onCaptureReady: onCaptureReady)
        } catch {
            lock.withLock {
                if legacyOwner == owner { legacyOwner = nil }
            }
            throw error
        }
    }

    public func startRecording(
        releaseBoundary: AudioCaptureReleaseBoundary,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let owner = AudioCaptureOwner.preview()
        lock.withLock { legacyOwner = owner }
        do {
            try await startRecordingOwned(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: releaseBoundary,
                onCaptureReady: onCaptureReady)
        } catch {
            lock.withLock {
                if legacyOwner == owner { legacyOwner = nil }
            }
            throw error
        }
    }

    public func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecordingOwned(
            owner: owner,
            configuration: configuration,
            releaseBoundary: releaseBoundary,
            onCaptureReady: onCaptureReady)
    }

    private func startRecordingOwned(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        guard captureDemands.insert(owner) else {
            throw AudioCaptureError.alreadyRecording
        }
        do {
            try await captureTransitions.run { [self] in
                try Task.checkCancellation()
                guard captureDemands.contains(owner) else {
                    throw CancellationError()
                }
                try startRecordingOwnedSerialized(
                    owner: owner,
                    configuration: configuration,
                    releaseBoundary: releaseBoundary,
                    onCaptureReady: onCaptureReady)
            }
            guard !Task.isCancelled, captureDemands.contains(owner) else {
                _ = forceReset(owner: owner)
                throw CancellationError()
            }
        } catch {
            _ = captureDemands.remove(owner)
            throw error
        }
    }

    private func startRecordingOwnedSerialized(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) throws {
        #if canImport(AVFoundation)
            if lock.withLock({ physicalCapture != nil }) {
                let soundProvider = try attachToPhysicalCapture(
                    owner: owner,
                    configuration: configuration,
                    releaseBoundary: releaseBoundary,
                    onCaptureReady: onCaptureReady)
                soundProvider?.playStartSound()
                return
            }

            // Reserve reset ownership before waiting on the engine lock. A
            // concurrent reset can now invalidate even a start that has not
            // entered provider state yet.
            guard !physicalStopLedger.hasRetainedStops else {
                throw AudioCaptureError.alreadyRecording
            }
            guard let attempt = engineStartResetLedger.beginIfIdle(owner: owner) else {
                throw AudioCaptureError.alreadyRecording
            }
            // Shutdown can seal demand after the queue-level check but before
            // this reservation. Rechecking after reservation guarantees either
            // shutdown can invalidate this exact attempt or this start observes
            // the seal before entering engine.start().
            guard captureDemands.contains(owner) else {
                engineStartResetLedger.end(attempt)
                throw CancellationError()
            }
            var failedEngine: AVAudioEngine?
            var ownsFailedStartCleanup = false
            var claimedProviderState = false
            let soundProvider: SoundFeedbackProvider?
            do {
                soundProvider = try lock.withLock {
                    removeCompletedStopOperationsLocked()
                    guard !_isRecording, !startCleanupInProgress,
                        publicationLedger.canBegin
                    else {
                        throw AudioCaptureError.alreadyRecording
                    }
                    guard captureSinkOwnership.begin(attempt) else {
                        throw AudioCaptureError.alreadyRecording
                    }

                    claimedProviderState = true
                    var didStart = false
                    defer {
                        if !didStart {
                            let invalidated = engineStartResetLedger
                                .invalidateActiveAttempt()
                            failedEngine = invalidated?.engine
                            ownsFailedStartCleanup = invalidated != nil
                            startCleanupInProgress = true
                            discardCaptureStateLocked(ownedBy: attempt)
                        }
                    }

                    let sinkPublication = dictationSinkPublication
                    let router = TimestampedAudioFrameRouter(
                        makeDictationSink: {
                            try sinkPublication.makeRouterSink()
                        })
                    if !configuration.retainsPCM {
                        let levelPair = AsyncStream<Float>.makeStream(
                            bufferingPolicy: .bufferingNewest(1))
                        previewOwner = owner
                        previewLevelSource = PreviewLevelSource(
                            stream: levelPair.stream,
                            continuation: levelPair.continuation)
                    }

                    // Create or reuse the persistent engine.
                    var engine = try ensureEngine(for: attempt)

                    // Open callback admission before installing the tap. A running
                    // engine can invoke the tap immediately; opening later would
                    // discard the first captured buffer while this lock is held.
                    let tapPublication = publicationLedger.begin(attempt)

                    // Install the audio tap. Pass nil as the format so
                    // AVAudioEngine uses the input node's current native
                    // format, avoiding a crash when the hardware sample
                    // rate changes between ensureEngine() and installTap()
                    // (e.g. AirPods finishing Bluetooth negotiation).
                    //
                    // AVAudioEngine throws ObjC exceptions (not Swift
                    // errors) on installTap failures such as stale audio
                    // hardware state after device switches. Catch the
                    // exception, tear down, rebuild, and retry once.
                    let bufferSize: AVAudioFrameCount = 4096
                    let tapException = ObjCTryCatch {
                        engine.inputNode.installTap(
                            onBus: 0,
                            bufferSize: bufferSize,
                            format: nil
                        ) { [weak self] buffer, timestamp in
                            self?.processTapBuffer(
                                buffer,
                                timestamp: timestamp,
                                publication: tapPublication,
                                router: router)
                        }
                    }

                    if let tapException {
                        Log.debug(
                            "[AudioCapture] installTap failed: \(tapException.reason ?? tapException.name.rawValue), "
                                + "rebuilding engine and retrying"
                        )
                        tearDownEngineLocked()
                        engine = try ensureEngine(for: attempt)
                        publicationLedger.reset()
                        let retryTapPublication = publicationLedger.begin(attempt)

                        let retryException = ObjCTryCatch {
                            engine.inputNode.installTap(
                                onBus: 0,
                                bufferSize: bufferSize,
                                format: nil
                            ) { [weak self] buffer, timestamp in
                                self?.processTapBuffer(
                                    buffer,
                                    timestamp: timestamp,
                                    publication: retryTapPublication,
                                    router: router)
                            }
                        }
                        if let retryException {
                            Log.debug(
                                "[AudioCapture] installTap retry failed: "
                                    + "\(retryException.reason ?? retryException.name.rawValue)"
                            )
                            tearDownEngineLocked()
                            throw AudioCaptureError.noInputDevice
                        }
                    }

                    // A dictation may claim only a key-down that happened after
                    // this exact tap was installed. Recording this after a
                    // successful install makes a cold, post-press start fail
                    // explicitly instead of silently omitting its prefix.
                    router.markContinuousCaptureStarted(
                        atHostTime: AudioCaptureReleaseFence.currentHostTime())

                    // Read the actual tap format from the input node after
                    // installation. This is the format buffers will arrive
                    // in, which may differ from what outputFormat(forBus:)
                    // reported during ensureEngine().
                    let actualTapFormat = engine.inputNode.outputFormat(forBus: 0)
                    if self.tapFormat?.sampleRate != actualTapFormat.sampleRate
                        || self.tapFormat?.channelCount != actualTapFormat.channelCount
                    {
                        Log.debug(
                            "[AudioCapture] Tap format updated: "
                                + "sampleRate=\(actualTapFormat.sampleRate), "
                                + "channels=\(actualTapFormat.channelCount)"
                        )
                        self.tapFormat = actualTapFormat
                        self.converterLifecycle = nil
                    }

                    var initialDictation: DictationCaptureIdentity?
                    if configuration.retainsPCM {
                        let sink = try DictationAudioSink(
                            inputFormat: actualTapFormat,
                            micProximity: _micProximity,
                            deviceName: _deviceName)
                        let sinkToken = dictationSinkPublication.publish(sink)
                        do {
                            let boundary = releaseBoundary
                                ?? AudioCaptureReleaseBoundary()
                            let route = try router.promote(
                                releaseBoundary: boundary)
                            initialDictation = DictationCaptureIdentity(
                                owner: owner,
                                sink: sink,
                                sinkToken: sinkToken,
                                route: route)
                        } catch {
                            _ = dictationSinkPublication.clear(sinkToken)
                            sink.discard()
                            throw capturePromotionError(error)
                        }
                    }

                    guard
                        engineStartResetLedger.commitCaptureReady(
                            attempt,
                            publish: {
                                _isRecording = true
                                recordingStartAttempt = attempt
                                _droppedFrameCount = 0
                                let physical = PhysicalCaptureIdentity(
                                    starterOwner: owner,
                                    attempt: attempt,
                                    router: router)
                                physicalCapture = physical
                                if !configuration.retainsPCM {
                                    publishPreviewPreRoll(physical)
                                }
                                if let initialDictation {
                                    dictationCapture = initialDictation
                                    metricsOwner = owner
                                    retainedMetrics = nil
                                    pcmStreamSnapshot.publish(
                                        initialDictation.sink.pcmStream)
                                } else {
                                    pcmStreamSnapshot.clear()
                                }
                            },
                            onCaptureReady: onCaptureReady)
                    else {
                        tearDownEngineLocked()
                        throw resetDuringEngineStartError
                    }
                    didStart = true
                    return configuration.playsSoundFeedback
                        ? _soundFeedbackProvider : nil
                }
            } catch {
                if claimedProviderState {
                    cleanUpFailedStart(
                        for: attempt,
                        engine: failedEngine,
                        ownsAttemptCleanup: ownsFailedStartCleanup)
                } else {
                    engineStartResetLedger.end(attempt)
                }
                throw error
            }

            // Play the start sound after the lock is released. The
            // capture engine is fully running and the tap is installed,
            // so the dedicated playback engine is not contending with
            // engine setup. Calling outside the lock eliminates the
            // intermittent misses caused by lock contention between
            // the capture and playback engines.
            soundProvider?.playStartSound()
        #else
            throw AudioCaptureError.noInputDevice
        #endif
    }

    #if canImport(AVFoundation)
        private func attachToPhysicalCapture(
            owner: AudioCaptureOwner,
            configuration: AudioCaptureConfiguration,
            releaseBoundary: AudioCaptureReleaseBoundary?,
            onCaptureReady: @escaping @Sendable () -> Void
        ) throws -> SoundFeedbackProvider? {
            try lock.withLock {
                guard _isRecording, let physicalCapture,
                    !startCleanupInProgress,
                    !isPhysicalStopInProgress
                else { throw AudioCaptureError.alreadyRecording }

                removeCompletedStopOperationsLocked()

                if configuration.retainsPCM {
                    guard dictationCapture == nil, let tapFormat else {
                        throw AudioCaptureError.alreadyRecording
                    }
                    let sink = try DictationAudioSink(
                        inputFormat: tapFormat,
                        micProximity: _micProximity,
                        deviceName: _deviceName)
                    let sinkToken = dictationSinkPublication.publish(sink)
                    do {
                        let boundary = releaseBoundary
                            ?? AudioCaptureReleaseBoundary()
                        let route = try physicalCapture.router.promote(
                            releaseBoundary: boundary)
                        dictationCapture = DictationCaptureIdentity(
                            owner: owner,
                            sink: sink,
                            sinkToken: sinkToken,
                            route: route)
                        metricsOwner = owner
                        retainedMetrics = nil
                        pcmStreamSnapshot.publish(sink.pcmStream)
                    } catch {
                        _ = dictationSinkPublication.clear(sinkToken)
                        sink.discard()
                        throw capturePromotionError(error)
                    }
                } else {
                    guard previewOwner == nil else {
                        throw AudioCaptureError.alreadyRecording
                    }
                    let levelPair = AsyncStream<Float>.makeStream(
                        bufferingPolicy: .bufferingNewest(1))
                    previewOwner = owner
                    previewLevelSource = PreviewLevelSource(
                        stream: levelPair.stream,
                        continuation: levelPair.continuation)
                }

                onCaptureReady()
                if configuration.retainsPCM {
                    _ = previewPreRollPublication.clear(
                        for: physicalCapture.attempt)
                }
                return configuration.playsSoundFeedback
                    ? _soundFeedbackProvider : nil
            }
        }

        private func publishPreviewPreRoll(
            _ physical: PhysicalCaptureIdentity
        ) {
            previewPreRollPublication.publish(for: physical.attempt) {
                [router = physical.router] pressHostTime in
                router.canPromoteFromContinuousCapture(at: pressHostTime)
            }
        }

        private func capturePromotionError(_ error: any Error) -> AudioCaptureError {
            guard
                let promotion = error
                    as? TimestampedAudioFrameRouter.PromotionError
            else { return .formatError }
            switch promotion {
            case .dictationAlreadyActive:
                return .alreadyRecording
            case .preRollCoverageUnavailable:
                return .captureIntegrity(
                    AudioCaptureIntegrityFailure(
                        stage: .timestampCoverage,
                        affectedFrameCount: nil))
            case .sinkCreationFailed:
                return .formatError
            }
        }
    #endif

    public func closeRecordingBoundary() {
        #if canImport(AVFoundation)
            guard let owner = lock.withLock({ legacyOwner }) else { return }
            _ = closeRecordingBoundary(owner: owner)
        #endif
    }

    public func closeRecordingBoundary(atHostTime releaseHostTime: UInt64) {
        #if canImport(AVFoundation)
            guard let owner = lock.withLock({ legacyOwner }) else { return }
            _ = closeRecordingBoundary(
                owner: owner,
                atHostTime: releaseHostTime)
        #endif
    }

    @discardableResult
    public func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        #if canImport(AVFoundation)
            closeRecordingBoundary(
                owner: owner,
                atHostTime: AudioCaptureReleaseFence.currentHostTime())
        #else
            false
        #endif
    }

    @discardableResult
    public func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        #if canImport(AVFoundation)
            guard let route = lock.withLock({
                dictationCapture?.owner == owner
                    ? dictationCapture?.route : nil
            }) else { return false }
            return route.publishRelease(at: releaseHostTime)
        #else
            return false
        #endif
    }

    public func stopRecording() async throws -> AudioBuffer {
        #if canImport(AVFoundation)
            guard let owner = lock.withLock({ legacyOwner }) else { return .empty }
            let buffer = try await stopRecording(owner: owner)
            lock.withLock {
                if legacyOwner == owner { legacyOwner = nil }
            }
            return buffer
        #else
            return .empty
        #endif
    }

    public func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        #if canImport(AVFoundation)
            let operation: StopOperation = try lock.withLock {
                if let operation = stopOperations[owner] {
                    if !operation.isCompleted {
                        return operation
                    }
                    stopOperations[owner] = nil
                }
                guard previewOwner == owner || dictationCapture?.owner == owner else {
                    throw AudioCaptureError.ownerMismatch
                }

                let operation = StopOperation(owner: owner) {
                    [weak self] resultPublication in
                    guard let self else {
                        return .failure(CancellationError())
                    }
                    do {
                        let buffer = try await self.captureTransitions.run {
                            return try await self.performStopRecording(
                                owner: owner,
                                resultPublication: resultPublication)
                        }
                        return .success(buffer)
                    } catch {
                        return .failure(error)
                    }
                }
                stopOperations[owner] = operation
                return operation
            }
            return try await operation.result().get()
        #else
            return .empty
        #endif
    }

    #if canImport(AVFoundation)
        private func removeCompletedStopOperationsLocked() {
            stopOperations = stopOperations.filter { !$0.value.isCompleted }
        }

        private func performStopRecording(
            owner: AudioCaptureOwner,
            resultPublication: StopOperation.ResultPublication
        ) async throws -> AudioBuffer {
            if lock.withLock({ dictationCapture?.owner == owner }) {
                return try await stopDictation(
                    owner: owner,
                    resultPublication: resultPublication)
            }
            if lock.withLock({ previewOwner == owner && dictationCapture != nil }) {
                guard let termination = captureDemands.beginTermination(owner) else {
                    throw AudioCaptureError.ownerMismatch
                }
                defer { captureDemands.finishTermination(termination) }
                let removedPreviewDuringDictation = lock.withLock { () -> Bool in
                    guard previewOwner == owner, dictationCapture != nil else {
                        return false
                    }
                    previewOwner = nil
                    previewLevelSource?.continuation.finish()
                    previewLevelSource = nil
                    _ = physicalCapture.map {
                        previewPreRollPublication.clear(for: $0.attempt)
                    }
                    return true
                }
                guard removedPreviewDuringDictation else {
                    throw AudioCaptureError.ownerMismatch
                }
                return .empty
            }
            return try await stopPreview(
                owner: owner,
                resultPublication: resultPublication)
        }

        private func releaseDrainTimeout(sampleRate: Double) -> TimeInterval {
            guard sampleRate > 0 else { return 2 }
            let threeCallbackPeriods = 3 * 4_096 / sampleRate
            return min(max(threeCallbackPeriods, 0.25), 2)
        }

        private func stopDictation(
            owner: AudioCaptureOwner,
            resultPublication: StopOperation.ResultPublication
        ) async throws -> AudioBuffer {
            guard let claim = lock.withLock({ () -> (
                capture: DictationCaptureIdentity,
                physical: PhysicalCaptureIdentity,
                engine: AVAudioEngine,
                sound: SoundFeedbackProvider?,
                releaseDrainTimeout: TimeInterval
            )? in
                guard let capture = dictationCapture,
                    capture.owner == owner,
                    let physical = physicalCapture,
                    let engine
                else { return nil }
                return (
                    capture, physical, engine, _soundFeedbackProvider,
                    releaseDrainTimeout(sampleRate: tapFormat?.sampleRate ?? 0))
            }) else {
                throw AudioCaptureError.ownerMismatch
            }

            guard let termination = captureDemands.beginTermination(owner) else {
                throw AudioCaptureError.ownerMismatch
            }
            defer { captureDemands.finishTermination(termination) }

            _ = claim.capture.route.publishRelease(
                at: AudioCaptureReleaseFence.currentHostTime())

            let router = claim.physical.router
            let route = claim.capture.route
            let sink = claim.capture.sink
            let stopDrain = AudioCaptureStopDrain<DictationStopFinalization>(
                observeRelease: {
                    guard await router.waitUntilReleaseObserved(for: route) else {
                        return false
                    }
                    return router.finish(route)
                },
                finalize: {
                    DictationStopFinalization(
                        completion: sink.finishWithIntegrity(),
                        metrics: sink.metrics)
                })
            let drainObservation = await stopDrain.outcome(
                timeout: claim.releaseDrainTimeout)

            switch drainObservation {
            case .completed(.finalized(let finalization)):
                return try await finishSuccessfulDictationStop(
                    owner: owner,
                    claim: claim,
                    finalization: finalization,
                    resultPublication: resultPublication)

            case .completed(.releaseRejected):
                let integrityFailure = sink.integrityPublication.failure
                let failure: any Error = integrityFailure.map {
                    AudioCaptureError.captureIntegrity($0)
                } ?? AudioCaptureError.ownerMismatch
                guard
                    let aborted = claimAbortedDictationStop(
                        owner: owner,
                        capture: claim.capture,
                        physical: claim.physical,
                        engine: claim.engine)
                else {
                    throw failure
                }
                let physicalStop = stopAbortedPhysicalCapture(aborted)
                resultPublication.publish(.failure(failure))
                let releaseWake = DetachedOperation {
                    router.finish(route)
                }
                _ = await releaseWake.task.value
                let physicalStopError = await physicalStop.task.value
                finishAbortedDictationStop(
                    aborted,
                    drainResult: .releaseRejected,
                    physicalStopError: physicalStopError)
                throw failure

            case .deadline, .cancelled:
                let failure = AudioCaptureError.captureIntegrity(
                    stopDrain.timeoutFailure)
                guard
                    let aborted = claimAbortedDictationStop(
                        owner: owner,
                        capture: claim.capture,
                        physical: claim.physical,
                        engine: claim.engine)
                else {
                    resultPublication.publish(.failure(failure))
                    _ = await stopDrain.task.value
                    throw failure
                }

                // Callback admission is already revoked by the claim. Stop the
                // physical device before publishing failure or touching the
                // router/converter that exceeded its deadline.
                let physicalStop = stopAbortedPhysicalCapture(aborted)
                resultPublication.publish(.failure(failure))

                // Stopping the engine means a release waiter may never receive
                // another callback. Exact route closure wakes it when the router
                // is responsive; if conversion is wedged this task retains the
                // same route ownership until that work eventually unwinds.
                let releaseWake = DetachedOperation {
                    router.finish(route)
                }
                let drainResult = await stopDrain.task.value
                _ = await releaseWake.task.value
                let physicalStopError = await physicalStop.task.value
                finishAbortedDictationStop(
                    aborted,
                    drainResult: drainResult,
                    physicalStopError: physicalStopError)
                throw failure
            }
        }

        private func finishSuccessfulDictationStop(
            owner: AudioCaptureOwner,
            claim: (
                capture: DictationCaptureIdentity,
                physical: PhysicalCaptureIdentity,
                engine: AVAudioEngine,
                sound: SoundFeedbackProvider?,
                releaseDrainTimeout: TimeInterval
            ),
            finalization: DictationStopFinalization,
            resultPublication: StopOperation.ResultPublication
        ) async throws -> AudioBuffer {
            let completion = finalization.completion

            let cleanup = lock.withLock { () -> (
                clearedCapture: Bool,
                shouldStopPhysical: Bool
            ) in
                guard dictationCapture?.owner == owner,
                    dictationCapture?.route == claim.capture.route
                else { return (false, false) }
                dictationCapture = nil
                retainedMetrics = finalization.metrics
                metricsOwner = owner
                pcmStreamSnapshot.clear()
                _ = dictationSinkPublication.clear(claim.capture.sinkToken)
                let shouldStopPhysical = previewOwner == nil
                isPhysicalStopInProgress = shouldStopPhysical
                if shouldStopPhysical {
                    _ = publicationLedger.reset(claim.physical.attempt)
                    _ = previewPreRollPublication.clear(
                        for: claim.physical.attempt)
                } else {
                    publishPreviewPreRoll(claim.physical)
                }
                return (true, shouldStopPhysical)
            }

            guard cleanup.clearedCapture else {
                throw AudioCaptureError.ownerMismatch
            }

            let physicalStop = cleanup.shouldStopPhysical
                ? beginPhysicalStop(
                    token: .attempt(claim.physical.attempt),
                    engine: claim.engine)
                : nil
            claim.sound?.playStopSound()

            let result: Result<AudioBuffer, any Error>
            if let integrityFailure = completion.integrityFailure {
                result = .failure(
                    AudioCaptureError.captureIntegrity(integrityFailure))
            } else {
                result = .success(completion.buffer)
            }

            // The finalized audio result does not depend on tap removal. Once
            // callback admission is revoked and engine.stop() has closed the
            // microphone, publish without joining a callback-blocked removeTap.
            if let physicalStop {
                resultPublication.publish(result)
                let physicalStopError = await physicalStop.task.value
                finishPhysicalStop(claim.physical)
                if physicalStopError != nil {
                    discardEngineAfterStopFailure(claim.engine)
                }
            }
            return try result.get()
        }

        private func claimAbortedDictationStop(
            owner: AudioCaptureOwner,
            capture: DictationCaptureIdentity,
            physical: PhysicalCaptureIdentity,
            engine: AVAudioEngine
        ) -> AbortedDictationStop? {
            lock.withLock {
                guard dictationCapture?.owner == owner,
                    dictationCapture?.route == capture.route,
                    physicalCapture?.attempt == physical.attempt,
                    self.engine === engine
                else { return nil }

                dictationCapture = nil
                metricsOwner = nil
                retainedMetrics = nil
                pcmStreamSnapshot.clear()
                _ = dictationSinkPublication.clear(capture.sinkToken)
                _ = publicationLedger.reset(physical.attempt)
                _ = previewPreRollPublication.clear(for: physical.attempt)

                if let previewOwner {
                    _ = captureDemands.remove(previewOwner)
                    self.previewOwner = nil
                    previewLevelSource?.continuation.finish()
                    previewLevelSource = nil
                    if legacyOwner == previewOwner { legacyOwner = nil }
                }
                if legacyOwner == owner { legacyOwner = nil }

                physicalCapture = nil
                recordingStartAttempt = nil
                _isRecording = false
                isPhysicalStopInProgress = true
                return AbortedDictationStop(
                    capture: capture,
                    physical: physical,
                    engine: engine)
            }
        }

        private func stopAbortedPhysicalCapture(
            _ aborted: AbortedDictationStop
        ) -> AudioCapturePhysicalStop<AudioCaptureError?> {
            // A failed drain no longer has usable PCM. Stop input first so a
            // blocked callback cannot keep the microphone live while cleanup
            // waits for exact router/converter ownership.
            return beginPhysicalStop(
                token: .attempt(aborted.physical.attempt),
                engine: aborted.engine)
        }

        private func finishAbortedDictationStop(
            _ aborted: AbortedDictationStop,
            drainResult: AudioCaptureStopDrain<DictationStopFinalization>.Result,
            physicalStopError: (any Error)?
        ) {
            guard
                physicalStopLedger.claimCompletion(
                    .attempt(aborted.physical.attempt))
            else { return }
            if case .releaseRejected = drainResult {
                aborted.capture.sink.discard()
            }
            aborted.physical.router.reset()
            _ = captureSinkOwnership.finish(aborted.physical.attempt)
            engineStartResetLedger.end(aborted.physical.attempt)
            lock.withLock {
                isPhysicalStopInProgress = false
            }
            _ = physicalStopLedger.finish(
                .attempt(aborted.physical.attempt))
            if physicalStopError != nil {
                discardEngineAfterStopFailure(aborted.engine)
            }
        }

        private func stopPreview(
            owner: AudioCaptureOwner,
            resultPublication: StopOperation.ResultPublication
        ) async throws -> AudioBuffer {
            guard let termination = captureDemands.beginTermination(owner) else {
                throw AudioCaptureError.ownerMismatch
            }
            defer { captureDemands.finishTermination(termination) }

            guard let claim = lock.withLock({ () -> (
                physical: PhysicalCaptureIdentity,
                engine: AVAudioEngine
            )? in
                guard previewOwner == owner,
                    dictationCapture == nil,
                    let physical = physicalCapture,
                    let engine
                else { return nil }
                previewOwner = nil
                previewLevelSource?.continuation.finish()
                previewLevelSource = nil
                isPhysicalStopInProgress = true
                _ = previewPreRollPublication.clear(
                    for: physical.attempt)
                return (physical, engine)
            }) else {
                throw AudioCaptureError.ownerMismatch
            }

            _ = publicationLedger.reset(claim.physical.attempt)
            let physicalStop = beginPhysicalStop(
                token: .attempt(claim.physical.attempt),
                engine: claim.engine)
            let result: StopOperation.CaptureResult = .success(.empty)
            resultPublication.publish(result)
            let physicalStopError = await physicalStop.task.value
            finishPhysicalStop(claim.physical)
            if physicalStopError != nil {
                discardEngineAfterStopFailure(claim.engine)
            }
            return .empty
        }

        private func beginPhysicalStop(
            token: PhysicalStopToken,
            engine: AVAudioEngine
        ) -> AudioCapturePhysicalStop<AudioCaptureError?> {
            let tapControl = AudioEngineTapControl(engine: engine)
            return physicalStopLedger.beginOrJoin(
                for: token,
                closeHardware: { tapControl.stopEngine() },
                cleanup: { tapControl.removeTap() })
        }

        private func discardEngineAfterStopFailure(_ stoppedEngine: AVAudioEngine) {
            lock.withLock {
                guard engine === stoppedEngine else { return }
                tearDownEngineLocked()
            }
        }

        private func finishPhysicalStop(_ physical: PhysicalCaptureIdentity) {
            guard
                physicalStopLedger.claimCompletion(
                    .attempt(physical.attempt))
            else { return }
            _ = previewPreRollPublication.clear(for: physical.attempt)
            physical.router.reset()
            lock.withLock {
                guard physicalCapture?.attempt == physical.attempt else { return }
                publicationLedger.reset(physical.attempt)
                captureSinkOwnership.finish(physical.attempt)
                engineStartResetLedger.end(physical.attempt)
                physicalCapture = nil
                recordingStartAttempt = nil
                _isRecording = false
                isPhysicalStopInProgress = false
            }
            _ = physicalStopLedger.finish(.attempt(physical.attempt))
        }
    #endif

    /// Tear down the audio engine. Call on app termination.
    public func shutdown() {
        #if canImport(AVFoundation)
            guard shutdownGate.claim() else { return }
            _ = captureDemands.sealForShutdown()
            previewPreRollPublication.reset()

            // Revoke any published engine without waiting for provider, router,
            // or converter locks. Final retained-resource cleanup remains
            // serialized below, but shutdown itself cannot be held by it.
            let shutdownCapture = engineStartResetLedger.invalidateActiveAttempt()
                ?? engineStartResetLedger.activeInvalidation
            if let attempt = shutdownCapture?.attempt {
                _ = publicationLedger.reset(attempt)
            }
            let activeEngine = shutdownCapture?.engine
            let stoppedAttempt = shutdownCapture?.attempt
            let hardwareStop = shutdownCapture.flatMap { capture in
                capture.engine.map { engine in
                    beginPhysicalStop(
                        token: .attempt(capture.attempt),
                        engine: engine)
                }
            }
            let stoppedEngine = activeEngine.map(AudioEngineTapControl.init)

            Task.detached { [self] in
                _ = try? await captureTransitions.run {
                    await self.finishShutdownAfterTransitions(
                        hardwareStop: hardwareStop,
                        stoppedEngine: stoppedEngine,
                        stoppedAttempt: stoppedAttempt)
                }
            }
        #endif
    }

    #if canImport(AVFoundation)
        /// Final teardown is serialized after every already-admitted start/stop.
        /// The permanent demand seal prevents work from appearing behind it.
        private func finishShutdownAfterTransitions(
            hardwareStop: AudioCapturePhysicalStop<AudioCaptureError?>?,
            stoppedEngine: AudioEngineTapControl?,
            stoppedAttempt: CaptureAttempt?
        ) async {
            _ = await hardwareStop?.task.value
            let ownsInitialStopCompletion = stoppedAttempt.map {
                physicalStopLedger.claimCompletion(.attempt($0))
            } ?? false
            let invalidatedStart = engineStartResetLedger.invalidateActiveAttempt()
                ?? engineStartResetLedger.activeInvalidation

            let teardown: (
                physical: PhysicalCaptureIdentity?,
                dictation: DictationCaptureIdentity?,
                engine: AVAudioEngine?
            ) = lock.withLock {
                let physical = physicalCapture
                let dictation = dictationCapture
                let claimedEngine = engine ?? invalidatedStart?.engine

                publicationLedger.reset()
                captureSinkOwnership.reset()
                previewPreRollPublication.reset()
                dictationSinkPublication.reset()
                pcmStreamSnapshot.clear()
                previewLevelSource?.continuation.finish()
                pcmContinuation?.finish()
                levelContinuation?.finish()

                physicalCapture = nil
                dictationCapture = nil
                previewOwner = nil
                previewLevelSource = nil
                metricsOwner = nil
                retainedMetrics = nil
                legacyOwner = nil
                recordingStartAttempt = nil
                _isRecording = false
                isPhysicalStopInProgress = false
                startCleanupInProgress = false
                stopOperations.removeAll(keepingCapacity: false)
                pcmContinuation = nil
                levelContinuation = nil
                _audioLevelStream = nil
                pcmChunks.removeAll(keepingCapacity: false)

                if let observer = configChangeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    configChangeObserver = nil
                }
                engine = nil
                converterLifecycle?.discard()
                converterLifecycle = nil
                tapFormat = nil
                _configuredDeviceID = nil
                _needsEngineRebuild = false

                return (physical, dictation, claimedEngine)
            }

            teardown.physical?.router.reset()
            teardown.dictation?.sink.discard()
            var finalStopToken: PhysicalStopToken?
            if let engine = teardown.engine, engine !== stoppedEngine?.engine {
                let finalAttempt = invalidatedStart?.attempt
                    ?? teardown.physical?.attempt
                    ?? stoppedAttempt
                let token = finalAttempt.map(PhysicalStopToken.attempt)
                    ?? .shutdownIdleEngine
                let physicalStop = beginPhysicalStop(
                    token: token,
                    engine: engine)
                _ = await physicalStop.task.value
                if physicalStopLedger.claimCompletion(token) {
                    finalStopToken = token
                }
            }
            if let attempt = invalidatedStart?.attempt
                ?? teardown.physical?.attempt
                ?? stoppedAttempt
            {
                engineStartResetLedger.end(attempt)
            }
            if ownsInitialStopCompletion, let stoppedAttempt {
                _ = physicalStopLedger.finish(.attempt(stoppedAttempt))
            }
            if let finalStopToken {
                _ = physicalStopLedger.finish(finalStopToken)
            }
        }
    #endif

    /// Force-reset the audio engine after a timeout.
    ///
    /// When `startRecording()` hangs inside `engine.start()` (BT SCO
    /// negotiation), it holds the lock indefinitely. A ready capture can take
    /// the provider lock normally; a still-starting capture is invalidated
    /// through its independently published engine reservation instead.
    public func forceReset() {
        #if canImport(AVFoundation)
            guard
                let owner = lock.withLock({
                    legacyOwner ?? dictationCapture?.owner ?? previewOwner
                })
            else { return }
            _ = forceReset(owner: owner)
        #endif
    }

    @discardableResult
    public func forceReset(owner: AudioCaptureOwner) -> Bool {
        #if canImport(AVFoundation)
            guard captureDemands.remove(owner) else { return false }

            // Capture readiness is published while holding provider state. Once
            // visible, taking the lock cannot be stranded inside engine.start(),
            // and claiming synchronously prevents a deferred reset from racing a
            // replacement transition.
            if engineStartResetLedger.hasReadyCapture {
                finishDemandReset(owner: owner)
                return true
            }

            if lock.try() {
                let claim = claimDemandResetLocked(owner: owner)
                lock.unlock()
                if case .none = claim {
                    // The demand may still be queued behind another exact
                    // transition. Removing it above makes that start fail closed.
                } else {
                    performDemandReset(claim)
                    return true
                }
            }

            // A start can block while holding provider state. Its independently
            // published engine reservation remains reachable by exact owner.
            guard
                let invalidated = engineStartResetLedger
                    .invalidateActiveAttempt(ownedBy: owner)
            else {
                // A logical demand queued behind another transition has no
                // engine attempt yet. Its queue admission observes removal.
                return true
            }
            let attempt = invalidated.attempt
            publicationLedger.reset(attempt)
            pcmStreamSnapshot.clear()
            if let engine = invalidated.engine {
                let physicalStop = beginPhysicalStop(
                    token: .attempt(attempt),
                    engine: engine)
                Task.detached { [weak self] in
                    _ = await physicalStop.task.value
                    guard let self else { return }
                    guard
                        physicalStopLedger.claimCompletion(
                            .attempt(attempt))
                    else { return }
                    finishForceReset(for: attempt, owner: owner)
                    _ = physicalStopLedger.finish(.attempt(attempt))
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.finishForceReset(for: attempt, owner: owner)
                }
            }
            Log.debug("[AudioCapture] Force reset blocked start owner")
            return true
        #else
            return false
        #endif
    }

    #if canImport(AVFoundation)
        private func clearStopOperationLocked(owner: AudioCaptureOwner) {
            stopOperations[owner] = nil
        }

        private func claimDemandResetLocked(
            owner: AudioCaptureOwner,
            clearStopOperation: Bool = true
        ) -> DemandResetClaim {
            if let capture = dictationCapture,
                capture.owner == owner,
                let physical = physicalCapture
            {
                dictationCapture = nil
                metricsOwner = nil
                retainedMetrics = nil
                pcmStreamSnapshot.clear()
                _ = dictationSinkPublication.clear(capture.sinkToken)
                let shouldStopPhysical = previewOwner == nil
                if shouldStopPhysical {
                    _ = previewPreRollPublication.clear(
                        for: physical.attempt)
                }
                if shouldStopPhysical { isPhysicalStopInProgress = true }
                if clearStopOperation {
                    clearStopOperationLocked(owner: owner)
                }
                if legacyOwner == owner { legacyOwner = nil }
                return .dictation(
                    capture: capture,
                    physical: physical,
                    engineToStop: shouldStopPhysical ? engine : nil)
            }

            if previewOwner == owner {
                previewOwner = nil
                previewLevelSource?.continuation.finish()
                previewLevelSource = nil
                if let physicalCapture {
                    _ = previewPreRollPublication.clear(
                        for: physicalCapture.attempt)
                }
                let shouldStopPhysical = dictationCapture == nil
                let physical = shouldStopPhysical ? physicalCapture : nil
                if shouldStopPhysical { isPhysicalStopInProgress = true }
                if clearStopOperation {
                    clearStopOperationLocked(owner: owner)
                }
                if legacyOwner == owner { legacyOwner = nil }
                return .preview(
                    physical: physical,
                    engineToStop: shouldStopPhysical ? engine : nil)
            }

            return .none
        }

        private func performDemandReset(_ claim: DemandResetClaim) {
            switch claim {
            case .dictation(let capture, let physical, let engineToStop):
                let physicalStop: AudioCapturePhysicalStop<AudioCaptureError?>?
                let stoppedEngine = engineToStop.map(AudioEngineTapControl.init)
                if let engineToStop {
                    _ = publicationLedger.reset(physical.attempt)
                    physicalStop = beginPhysicalStop(
                        token: .attempt(physical.attempt),
                        engine: engineToStop)
                } else {
                    physicalStop = nil
                }
                Task.detached { [self] in
                    _ = physical.router.finish(capture.route)
                    capture.sink.discard()
                    if let physicalStop, let stoppedEngine {
                        let stopError = await physicalStop.task.value
                        finishPhysicalStop(physical)
                        if stopError != nil {
                            discardEngineAfterStopFailure(stoppedEngine.engine)
                        }
                    } else {
                        let canRestorePreview = lock.withLock {
                            physicalCapture?.attempt == physical.attempt
                                && previewOwner != nil
                                && dictationCapture == nil
                        }
                        if canRestorePreview {
                            publishPreviewPreRoll(physical)
                        }
                    }
                }

            case .preview(let physical, let engineToStop):
                if let physical, let engineToStop {
                    _ = publicationLedger.reset(physical.attempt)
                    let physicalStop = beginPhysicalStop(
                        token: .attempt(physical.attempt),
                        engine: engineToStop)
                    let stoppedEngine = AudioEngineTapControl(engine: engineToStop)
                    Task.detached { [self] in
                        let stopError = await physicalStop.task.value
                        finishPhysicalStop(physical)
                        if stopError != nil {
                            discardEngineAfterStopFailure(stoppedEngine.engine)
                        }
                    }
                }

            case .none:
                break
            }
        }

        private func finishDemandReset(owner: AudioCaptureOwner) {
            let claim = lock.withLock {
                claimDemandResetLocked(owner: owner)
            }
            performDemandReset(claim)
        }
    #endif

    /// Mark the engine for rebuild on the next recording session.
    ///
    /// Called by `CoreAudioDeviceProvider` when the device list or
    /// default input device changes. AVAudioEngine does not emit
    /// `AVAudioEngineConfigurationChange` when it is stopped, so
    /// device changes that happen between recording sessions leave
    /// the engine with stale CoreAudio state. Without this, the
    /// next `ensureEngine()` tries to reuse the stopped engine,
    /// and `engine.start()` hangs indefinitely.
    public func markNeedsRebuild() {
        #if canImport(AVFoundation)
            lock.withLock {
                guard !_isRecording else { return }
                guard engine != nil else { return }
                _needsEngineRebuild = true
                Log.debug(
                    "[AudioCapture] Marked for rebuild (external device change while idle)"
                )
            }
        #endif
    }

    // MARK: - Persistent engine management

    #if canImport(AVFoundation)
        /// Return the existing engine or create a new one. Must be called
        /// while `lock` is held. Starts the engine and registers for
        /// configuration change notifications on first creation.
        ///
        /// If a `CoreAudioDeviceProvider` is set and has a selected device,
        /// the engine's input node is configured to capture from that device.
        /// When the selected device changes between sessions, the existing
        /// engine is torn down and rebuilt for the new device.
        private func ensureEngine(
            for attempt: AudioEngineStartResetLedger<AVAudioEngine>.Attempt
        ) throws -> AVAudioEngine {
            let desiredDeviceID = _audioDeviceProvider?.selectedDeviceID

            if let engine {
                guard engineStartResetLedger.publish(engine, for: attempt) else {
                    throw resetDuringEngineStartError
                }
                // If the selected device changed or a config change was
                // deferred during a previous recording, tear down and
                // rebuild with the current hardware.
                if desiredDeviceID != _configuredDeviceID || _needsEngineRebuild {
                    Log.debug(
                        "[AudioCapture] Device changed from \(_configuredDeviceID?.description ?? "default") "
                            + "to \(desiredDeviceID?.description ?? "default")"
                            + "\(_needsEngineRebuild ? " (deferred rebuild)" : "")"
                            + ", rebuilding engine"
                    )
                    _needsEngineRebuild = false
                    tearDownEngineLocked()
                    // Fall through to create a new engine.
                } else {
                    // Engine exists for the correct device. Reuse it
                    // for low latency. Re-query mic proximity in case
                    // the system default device changed while the engine
                    // was stopped (e.g. AirPods connected between
                    // sessions). The engine follows the new default
                    // automatically on restart, but _micProximity was
                    // stale from the previous device.
                    _micProximity =
                        _audioDeviceProvider?.micProximityForDevice(
                            _configuredDeviceID
                        ) ?? .nearField
                    _deviceName =
                        _audioDeviceProvider?.deviceNameForDevice(
                            _configuredDeviceID
                        ) ?? "System Default"
                    if !engine.isRunning {
                        // Validate the hardware format before reusing a
                        // stopped engine. AVAudioEngine does not emit
                        // configurationChange notifications when stopped,
                        // so device changes between sessions can leave
                        // the engine with stale CoreAudio state. If the
                        // hardware format changed (sample rate, channels,
                        // or reports 0), tear down and rebuild.
                        let currentFormat = engine.inputNode.outputFormat(forBus: 0)
                        if currentFormat.sampleRate <= 0
                            || currentFormat.sampleRate != tapFormat?.sampleRate
                            || currentFormat.channelCount != tapFormat?.channelCount
                        {
                            Log.debug(
                                "[AudioCapture] Hardware format changed while stopped "
                                    + "(was \(tapFormat?.sampleRate ?? 0)/\(tapFormat?.channelCount ?? 0), "
                                    + "now \(currentFormat.sampleRate)/\(currentFormat.channelCount)), "
                                    + "rebuilding engine"
                            )
                            tearDownEngineLocked()
                            // Fall through to create a new engine.
                        } else {
                            guard engineStartResetLedger.isValid(attempt) else {
                                throw resetDuringEngineStartError
                            }
                            engine.prepare()
                            var startError: Error?
                            let startException = ObjCTryCatch {
                                do { try engine.start() } catch { startError = error }
                            }
                            if let startException {
                                Log.debug(
                                    "[AudioCapture] engine.start() ObjC exception on reuse: "
                                        + "\(startException.reason ?? startException.name.rawValue), "
                                        + "rebuilding engine"
                                )
                                tearDownEngineLocked()
                                // Fall through to create a new engine.
                            } else if let startError {
                                Log.debug(
                                    "[AudioCapture] engine.start() failed on reuse: "
                                        + "\(startError), rebuilding engine"
                                )
                                tearDownEngineLocked()
                                // Fall through to create a new engine.
                            } else {
                                guard engineStartResetLedger.isValid(attempt) else {
                                    engine.stop()
                                    tearDownEngineLocked()
                                    throw resetDuringEngineStartError
                                }
                                return engine
                            }
                        }
                    } else {
                        guard engineStartResetLedger.isValid(attempt) else {
                            throw resetDuringEngineStartError
                        }
                        return engine
                    }
                }
            }

            guard engineStartResetLedger.isValid(attempt) else {
                throw resetDuringEngineStartError
            }

            let engine = AVAudioEngine()
            guard engineStartResetLedger.publish(engine, for: attempt) else {
                throw resetDuringEngineStartError
            }

            // Configure the input device before accessing inputNode's
            // format. Setting the device after reading the format would
            // use the wrong sample rate and channel count.
            #if canImport(CoreAudio)
                if let deviceID = desiredDeviceID {
                    do {
                        try setInputDevice(deviceID, on: engine)
                    } catch {
                        // Device is no longer available (disconnected
                        // AirPods, unplugged USB mic, etc.). Clear the
                        // selection and fall back to the system default.
                        Log.debug(
                            "[AudioCapture] Device \(deviceID) unavailable, "
                                + "falling back to system default"
                        )
                        _audioDeviceProvider?.clearSelection()
                        // Continue without setInputDevice — the engine
                        // will use the system default input device.
                    }
                }
            #endif
            _configuredDeviceID = _audioDeviceProvider?.selectedDeviceID
            _micProximity =
                _audioDeviceProvider?.micProximityForDevice(
                    _configuredDeviceID
                ) ?? .nearField
            _deviceName =
                _audioDeviceProvider?.deviceNameForDevice(
                    _configuredDeviceID
                ) ?? "System Default"

            let inputNode = engine.inputNode

            let hardwareFormat = inputNode.outputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0 else {
                throw AudioCaptureError.noInputDevice
            }

            // Use a float intermediate for the tap, then convert to int16.
            guard
                let tapFmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: hardwareFormat.sampleRate,
                    channels: hardwareFormat.channelCount,
                    interleaved: false
                )
            else {
                throw AudioCaptureError.formatError
            }

            engine.prepare()
            guard engineStartResetLedger.isValid(attempt) else {
                engine.stop()
                throw resetDuringEngineStartError
            }
            var startError: Error?
            let startException = ObjCTryCatch {
                do { try engine.start() } catch { startError = error }
            }
            if let startException {
                throw AudioCaptureError.engineStartFailed(
                    startException.reason ?? startException.name.rawValue
                )
            }
            if let startError {
                throw startError
            }
            guard engineStartResetLedger.isValid(attempt) else {
                engine.stop()
                throw resetDuringEngineStartError
            }

            self.engine = engine
            self.tapFormat = tapFmt
            // Invalidate the converter so it is rebuilt against the new tap format.
            self.converterLifecycle = nil

            registerConfigChangeObserver()

            Log.debug(
                "[AudioCapture] Engine created (device=\(desiredDeviceID?.description ?? "default"), "
                    + "sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount))"
            )

            return engine
        }

        #if canImport(CoreAudio)
            /// Set the input device on an AVAudioEngine's input node.
            ///
            /// Uses `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice`
            /// to route the engine's input to the specified Core Audio device.
            private func setInputDevice(
                _ deviceID: AudioObjectID, on engine: AVAudioEngine
            ) throws {
                guard let audioUnit = engine.inputNode.audioUnit else {
                    throw AudioCaptureError.deviceSelectionFailed(deviceID)
                }

                var mutableDeviceID = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &mutableDeviceID,
                    UInt32(MemoryLayout<AudioObjectID>.size)
                )

                guard status == noErr else {
                    Log.debug(
                        "[AudioCapture] Failed to set input device \(deviceID): OSStatus \(status)"
                    )
                    throw AudioCaptureError.deviceSelectionFailed(deviceID)
                }

                Log.debug("[AudioCapture] Input device set to \(deviceID)")
            }
        #endif

        /// Return the converter lifecycle matching `tapFormat`.
        /// Must be called while `lock` is held and after `ensureEngine()`.
        private func ensureConverterLifecycle() throws -> PCMConverterLifecycle {
            if let converterLifecycle {
                return converterLifecycle
            }

            guard let tapFormat else {
                throw AudioCaptureError.formatError
            }

            guard
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Self.targetSampleRate,
                    channels: Self.targetChannels,
                    interleaved: true
                )
            else {
                throw AudioCaptureError.formatError
            }

            let lifecycle = PCMConverterLifecycle(
                inputFormat: tapFormat,
                outputFormat: targetFormat
            )
            self.converterLifecycle = lifecycle
            return lifecycle
        }

        /// Register for `AVAudioEngineConfigurationChange` to handle device
        /// switches (e.g. AirPods connect/disconnect). Tears down the engine
        /// so it is rebuilt with the new hardware format on the next recording.
        private func registerConfigChangeObserver() {
            // Remove any previous observer before registering a new one.
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }

            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Log.debug("[AudioCapture] Engine configuration changed (device switch)")
                self.handleConfigChange()
            }
        }

        /// A permanent preview has no later idle start on which to defer a
        /// rebuild. Revoke the exact physical generation when its input format
        /// changes; coordinator lease recovery then constructs and primes a new
        /// tap. Active dictation is marked incomplete before reset so it can
        /// never inject a plausible prefix as a complete result.
        private func handleConfigChange() {
            let ownersToReset: [AudioCaptureOwner] = lock.withLock {
                let inputFormatChanged: Bool
                if let engine, let tapFormat {
                    let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
                    inputFormatChanged =
                        hardwareFormat.sampleRate != tapFormat.sampleRate
                        || hardwareFormat.channelCount != tapFormat.channelCount
                } else {
                    inputFormatChanged = true
                }

                switch AudioCaptureConfigurationChangePolicy.action(
                    isRecording: _isRecording,
                    inputFormatChanged: inputFormatChanged)
                {
                case .ignore:
                    Log.debug(
                        "[AudioCapture] Config change ignored (input format unchanged)")
                    return []

                case .rebuildIdleEngine:
                    tearDownEngineLocked()
                    return []

                case .invalidateActiveCapture:
                    _needsEngineRebuild = true
                    dictationCapture?.sink.integrityPublication.record(
                        AudioCaptureIntegrityFailure(
                            stage: .timestampCoverage,
                            affectedFrameCount: nil))
                    previewLevelSource?.continuation.finish()

                    var owners: [AudioCaptureOwner] = []
                    if let dictationOwner = dictationCapture?.owner {
                        owners.append(dictationOwner)
                    }
                    if let previewOwner, !owners.contains(previewOwner) {
                        owners.append(previewOwner)
                    }
                    Log.debug(
                        "[AudioCapture] Input format changed; invalidating capture generation")
                    return owners
                }
            }

            for owner in ownersToReset {
                _ = forceReset(owner: owner)
            }
        }

        /// Stop the engine and clear cached state. Must be called while
        /// `lock` is held.
        private func tearDownEngineLocked() {
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            engine?.stop()
            engine = nil
            converterLifecycle?.discard()
            converterLifecycle = nil
            tapFormat = nil
            _configuredDeviceID = nil
        }

        private var resetDuringEngineStartError: AudioCaptureError {
            .engineStartFailed("Audio engine was reset while starting")
        }

        /// Finish a reset that could not acquire `lock` synchronously. The
        /// attempt check prevents delayed cleanup from touching a replacement.
        private func finishForceReset(
            for attempt: AudioEngineStartResetLedger<AVAudioEngine>.Attempt,
            owner: AudioCaptureOwner
        ) {
            guard engineStartResetLedger.activeInvalidation?.attempt == attempt else {
                return
            }
            lock.withLock {
                tearDownEngineLocked()
                discardCaptureStateLocked(ownedBy: attempt)
                if metricsOwner == owner { metricsOwner = nil }
                if legacyOwner == owner { legacyOwner = nil }
                clearStopOperationLocked(owner: owner)
                startCleanupInProgress = false
            }
            engineStartResetLedger.end(attempt)
        }

        /// Tear down an engine/tap allocated by a failed start without holding
        /// the provider lock while removeTap drains callbacks. The cleanup flag
        /// prevents a replacement start from claiming the engine in between.
        private func cleanUpFailedStart(
            for attempt: CaptureAttempt,
            engine failedEngine: AVAudioEngine?,
            ownsAttemptCleanup: Bool
        ) {
            guard ownsAttemptCleanup else { return }
            guard let failedEngine else {
                finishFailedStartCleanup(for: attempt, engine: nil)
                return
            }

            let physicalStop = beginPhysicalStop(
                token: .attempt(attempt),
                engine: failedEngine)
            Task.detached { [self] in
                _ = await physicalStop.task.value
                guard
                    physicalStopLedger.claimCompletion(
                        .attempt(attempt))
                else { return }
                finishFailedStartCleanup(
                    for: attempt,
                    engine: failedEngine)
                _ = physicalStopLedger.finish(.attempt(attempt))
            }
        }

        private func finishFailedStartCleanup(
            for attempt: CaptureAttempt,
            engine failedEngine: AVAudioEngine?
        ) {
            guard engineStartResetLedger.activeInvalidation?.attempt == attempt else {
                return
            }
            lock.withLock {
                if let failedEngine, engine === failedEngine {
                    tearDownEngineLocked()
                }
                startCleanupInProgress = false
            }
            engineStartResetLedger.end(attempt)
        }

        /// Clear state allocated before a failed start. Must be called
        /// while `lock` is held.
        private func discardCaptureStateLocked(
            ownedBy attempt: CaptureAttempt? = nil
        ) {
            if let attempt {
                guard captureSinkOwnership.finish(attempt) else { return }
                publicationLedger.reset(attempt)
                if physicalCapture?.attempt == attempt {
                    metricsOwner = nil
                    physicalCapture = nil
                }
                _ = previewPreRollPublication.clear(for: attempt)
            } else {
                captureSinkOwnership.reset()
                publicationLedger.reset()
                previewPreRollPublication.reset()
                physicalCapture = nil
                metricsOwner = nil
            }
            _isRecording = false
            recordingStartAttempt = nil
            dictationCapture?.sink.discard()
            dictationCapture = nil
            dictationSinkPublication.reset()
            previewLevelSource?.continuation.finish()
            previewLevelSource = nil
            previewOwner = nil
            pcmContinuation?.finish()
            pcmContinuation = nil
            pcmStreamSnapshot.clear()
            levelContinuation?.finish()
            levelContinuation = nil
            _audioLevelStream = nil
            pcmChunks = []
            converterLifecycle?.discard()
        }
    #endif

    // MARK: - Audio level metering

    #if canImport(AVFoundation)
        /// Classify the callback against the key-release host timestamp before
        /// either metering or conversion. A callback queued until after release
        /// can still contribute its pre-release prefix, but never its suffix.
        private func processTapBuffer(
            _ buffer: AVAudioPCMBuffer,
            timestamp: AVAudioTime,
            publication: CapturePublication,
            router: TimestampedAudioFrameRouter
        ) {
            guard let admission = publicationLedger.admitCallback(for: publication)
            else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            if let floatData = buffer.floatChannelData {
                let channelCount = max(Int(buffer.format.channelCount), 1)
                let sampleCount = frameLength * channelCount
                var sumOfSquares: Float = 0
                if buffer.format.isInterleaved {
                    for index in 0..<sampleCount {
                        let sample = floatData[0][index]
                        sumOfSquares += sample * sample
                    }
                } else {
                    for channel in 0..<channelCount {
                        for frame in 0..<frameLength {
                            let sample = floatData[channel][frame]
                            sumOfSquares += sample * sample
                        }
                    }
                }
                let rms = sqrtf(sumOfSquares / Float(sampleCount))
                let previewContinuation = lock.withLock { () ->
                    AsyncStream<Float>.Continuation? in
                    guard publicationLedger.accepts(admission) else { return nil }
                    return previewLevelSource?.continuation
                }
                previewContinuation?.yield(min(sqrtf(rms * 25), 1))
            }
            _ = router.ingest(buffer, timestamp: timestamp)
        }
    #endif

    // MARK: - Software gain helpers

    /// Compute the gain factor for a far-field mic given the measured
    /// ambient RMS. Returns 1.0 for near-field mics or when ambient
    /// is zero. Clamps to `[1.0, maxGainFactor]`.
    static func computeGainFactor(
        ambientRMS: Float,
        micProximity: MicProximity
    ) -> Float {
        guard micProximity == .farField, ambientRMS > 0 else {
            return 1.0
        }
        let raw = targetGainRMS / ambientRMS
        return min(max(raw, 1.0), maxGainFactor)
    }

    /// Apply a gain factor to raw Int16 PCM data, clamping each sample
    /// to `Int16.min...Int16.max` to prevent overflow wrapping.
    /// Returns the input unchanged when gain is <= 1.0.
    static func applySoftwareGain(
        _ pcmData: Data,
        gain: Float
    ) -> Data {
        guard gain > 1.0 else { return pcmData }
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return pcmData }

        var output = Data(capacity: pcmData.count)
        pcmData.withUnsafeBytes { rawBuffer in
            for i in 0..<sampleCount {
                let lo = UInt16(rawBuffer[i * 2])
                let hi = UInt16(rawBuffer[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                let amplified = Int32(Float(sample) * gain)
                let clamped = Int16(clamping: amplified)
                var le = clamped.littleEndian
                withUnsafeBytes(of: &le) { output.append(contentsOf: $0) }
            }
        }
        return output
    }
}

// MARK: - Errors

/// Errors that can occur during audio capture.
public enum AudioCaptureError: Error, Sendable, CustomStringConvertible {
    /// `startRecording()` was called while already recording.
    case alreadyRecording
    /// An operation named a stale or different capture owner.
    case ownerMismatch
    /// No audio input device is available.
    case noInputDevice
    /// Failed to create the required audio format or converter.
    case formatError
    /// Failed to set the requested input device on the audio engine.
    case deviceSelectionFailed(UInt32)
    /// The audio engine threw an exception during start.
    case engineStartFailed(String)
    /// The audio engine threw an exception while removing its input tap.
    case engineStopFailed(String)
    /// At least one frame in the owned capture range could not be retained.
    case captureIntegrity(AudioCaptureIntegrityFailure)

    public var description: String {
        switch self {
        case .alreadyRecording:
            return "Audio capture is already in progress"
        case .ownerMismatch:
            return "Audio capture is owned by a different session"
        case .noInputDevice:
            return "No audio input device available"
        case .formatError:
            return "Failed to configure audio format"
        case .deviceSelectionFailed(let id):
            return "Failed to select audio input device \(id)"
        case .engineStartFailed(let reason):
            return "Audio engine failed to start: \(reason)"
        case .engineStopFailed(let reason):
            return "Audio engine failed to stop: \(reason)"
        case .captureIntegrity(let failure):
            return "Audio capture integrity failed at \(failure.stage)"
        }
    }
}
