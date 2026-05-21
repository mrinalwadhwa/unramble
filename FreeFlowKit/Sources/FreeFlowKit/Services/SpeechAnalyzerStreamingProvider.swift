import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device streaming dictation using Apple SpeechAnalyzer.
///
/// Streams PCM audio chunks to `SpeechTranscriber` in real time
/// and returns the polished transcript when the session ends. Supports
/// the chunk handler for incremental injection during long dictations.
@available(macOS 26, *)
public final class SpeechAnalyzerStreamingProvider: StreamingDictationProviding,
    @unchecked Sendable
{

    // MARK: - Configuration

    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let locale: Locale

    // MARK: - State (guarded by lock)

    private let lock = NSLock()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var collectedText: String = ""
    private var chunkHandler: (@Sendable (String) async -> Void)?
    private var audioBytesSent: Int = 0
    private var inputFormat: AVAudioFormat?
    private var currentContext: AppContext = .empty

    // MARK: - Init

    public init(
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        language: String? = nil
    ) {
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.locale = SpeechAnalyzerDictationProvider.resolveLocale(
            language: language)
    }

    deinit {
        lock.withLock { readerTask }?.cancel()
    }

    // MARK: - StreamingDictationProviding

    public var uncommittedAudioDuration: TimeInterval {
        // 16 kHz, 16-bit mono = 32,000 bytes/sec.
        let bytes = lock.withLock { audioBytesSent }
        return Double(bytes) / 32_000.0
    }

    public func setChunkHandler(
        _ handler: (@Sendable (String) async -> Void)?
    ) {
        lock.withLock { self.chunkHandler = handler }
    }

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        // Warn if a session is already active.
        if lock.withLock({ self.analyzer != nil }) {
            Log.debug("[SpeechAnalyzerStreaming] startStreaming called while a session is active")
            assertionFailure("startStreaming called while a session is active")
        }

        // Use the granular initializer (no preset) so each result
        // is an additive chunk rather than a progressive replacement.
        // This lets us simply concatenate results, avoiding fragile
        // sentence-boundary heuristics.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Create a stream for feeding audio buffers.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // The pipeline sends 16 kHz 16-bit mono PCM — which matches
        // SpeechAnalyzer's preferred format (verified empirically).
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw DictationError.networkError(
                "Failed to create audio format")
        }

        // Start the analyzer with the input stream.
        try await analyzer.start(inputSequence: stream)

        // Spawn a reader that accumulates transcription results.
        // Without .progressiveTranscription, each result is a new
        // chunk of text — just concatenate them all.
        let reader = Task { [weak self] in
            var transcript = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if text.isEmpty { continue }

                    transcript += text

                    let trimmed = transcript.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    self?.lock.withLock {
                        self?.collectedText = trimmed
                    }
                }
            } catch {
                // Analysis cancelled or failed.
            }
        }

        lock.withLock {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputContinuation = continuation
            self.readerTask = reader
            self.inputFormat = fmt
            self.collectedText = ""
            self.audioBytesSent = 0
            self.currentContext = context
        }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        let (continuation, fmt) = lock.withLock {
            (inputContinuation, inputFormat)
        }
        guard let continuation, let fmt else { return }
        guard pcmData.count >= 2 else { return }

        let sampleCount = pcmData.count / 2

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: fmt,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // Copy raw Int16 PCM directly into the buffer.
        if let dest = buffer.int16ChannelData?[0] {
            pcmData.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    dest[i] = src[i]
                }
            }
        }

        continuation.yield(AnalyzerInput(buffer: buffer))

        lock.withLock {
            audioBytesSent += pcmData.count
        }
    }

    public func finishStreaming() async throws -> String {
        // Signal end of audio.
        let (continuation, analyzer, reader) = lock.withLock {
            let c = inputContinuation
            inputContinuation = nil
            return (c, self.analyzer, self.readerTask)
        }
        continuation?.finish()

        // Wait for the analyzer to finalize.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()

        // Wait for the reader to finish collecting results.
        await reader?.value

        let raw = lock.withLock {
            let text = collectedText
            // Clear session state so the next startStreaming sees a
            // clean provider. Without this, the assert in startStreaming
            // fires because analyzer is still non-nil.
            self.analyzer = nil
            self.transcriber = nil
            self.readerTask = nil
            self.collectedText = ""
            self.audioBytesSent = 0
            return text
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        return await polish(trimmed)
    }

    public func cancelStreaming() async {
        let (continuation, analyzer, reader) = lock.withLock {
            let c = inputContinuation
            let a = self.analyzer
            let r = readerTask
            inputContinuation = nil
            self.analyzer = nil
            self.transcriber = nil
            self.inputFormat = nil
            readerTask = nil
            return (c, a, r)
        }
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        reader?.cancel()
    }

    // MARK: - Polishing

    private func polishChunk(_ raw: String) async -> String {
        await polishText(raw)
    }

    private func polish(_ raw: String) async -> String {
        await polishText(raw)
    }

    private func polishText(_ raw: String) async -> String {
        let context: AppContext = lock.withLock { currentContext }
        let casual = PolishPipeline.toneLabel(for: context.bundleID) == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            raw, casual: casual,
            precedingText: context.focusedFieldContent)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)

        guard let polishChatClient else {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }

        let systemPrompt = PolishPipeline.buildQwenSystemPrompt(
            context: context)

        do {
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: systemPrompt,
                userPrompt: stripped)
            if polished.isEmpty {
                return PolishPipeline.normalizeFormatting(
                    stripped, casual: casual)
            }
            return PolishPipeline.normalizeFormatting(
                polished, casual: casual)
        } catch {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }
    }
}
