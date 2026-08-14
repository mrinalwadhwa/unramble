import Foundation

/// The mode-specific pieces of a dictation composition: the backend, an
/// optional session-expiry handler (cloud only), and the local model runtime
/// (local only). The app builds the `DictationPipeline` from these plus its own
/// singletons.
public struct DictationComposition {
    public let backend: DictationBackend
    public let onSessionExpired: (@Sendable () -> Void)?
    public let localRuntime: LocalModelRuntime?
}

/// Build the backend for a dictation mode. Cloud construction is inert by
/// default; the running app can opt into an idle Realtime connection so the
/// first dictation does not pay the WebSocket handshake. Local construction
/// resolves the on-device model directories and wires the MLX engines.
public enum DictationCompositionFactory {
    /// Cloud composition: OpenAI streaming transcription with a batch fallback.
    public static func makeCloud(
        apiKey: String,
        onSessionExpired: (@Sendable () -> Void)?,
        turnSignals: TurnSignalHub? = nil,
        prewarmRealtime: Bool = false
    ) -> DictationComposition {
        let realtime = OpenAIStreamingProvider(
            apiKey: apiKey,
            turnSignals: turnSignals)
        if prewarmRealtime {
            realtime.prewarmForNextSession()
        }
        return DictationComposition(
            backend: .cloud(
                realtime: realtime,
                fallback: OpenAIFileTranscriber(apiKey: apiKey)),
            onSessionExpired: onSessionExpired,
            localRuntime: nil)
    }

    #if arch(arm64)
    /// Local composition: on-device Cohere STT with a lazy Qwen list formatter.
    /// Terminates with `fatalError` when a required model directory is missing,
    /// so a corrupt or incomplete install fails loudly at launch.
    public static func makeLocal(
        modelManager: LocalModelManager,
        bundledModelsRoot: URL?,
        cycleInterval: TimeInterval,
        turnSignals: TurnSignalHub? = nil,
        captureGain: @escaping @Sendable () -> Float = { 1 }
    ) -> DictationComposition {
        guard let qwenModelPath = modelManager.resolveModelDirectory(
            modelID: "qwen3-0.6b-4bit", file: "model.safetensors",
            bundledModelsRoot: bundledModelsRoot)
        else {
            fatalError("Required local model is missing: qwen3-0.6b-4bit")
        }
        guard let adapterPath = modelManager.resolveModelDirectory(
            modelID: "qwen3-0.6b-4bit-list-adapter",
            file: "adapters.safetensors",
            bundledModelsRoot: bundledModelsRoot)
        else {
            fatalError(
                "Required local model is missing: "
                    + "qwen3-0.6b-4bit-list-adapter")
        }
        guard let coherePath = modelManager.resolveModelDirectory(
            modelID: "cohere-transcribe-03-2026-mlx-4bit",
            file: "model.safetensors",
            bundledModelsRoot: bundledModelsRoot
        ) else {
            fatalError(
                "Required local model is missing: "
                    + "cohere-transcribe-03-2026-mlx-4bit")
        }
        let sttEngine: any LocalStreamingRecognizer = CohereMLXEngine(
            modelDirectory: URL(
                fileURLWithPath: coherePath, isDirectory: true))
        let llmEngine = MLXLLMEngine(
            name: "Qwen3 0.6B List Formatter",
            modelDirectory: URL(
                fileURLWithPath: qwenModelPath, isDirectory: true),
            adapterDirectory: URL(
                fileURLWithPath: adapterPath, isDirectory: true))
        let polisher: any PolishChatClient = MLXPolishClient(
            engine: llmEngine,
            unloadAfterCompletion: true)
        let runtime = LocalModelRuntime(
            sttEngine: sttEngine, llmEngine: llmEngine, preloadLLM: false)
        let backend: DictationBackend = .local(
            streaming: LocalStreamingProvider(
                sttEngine: sttEngine,
                polishChatClient: nil,
                listFormattingChatClient: polisher,
                cycleInterval: cycleInterval,
                unitPolicy: localUnitPolicy,
                polishBatchTokenLimit: 256,
                loadSTT: { try await runtime.loadSTT() },
                turnSignals: turnSignals,
                captureGain: captureGain))
        return DictationComposition(
            backend: backend,
            onSessionExpired: nil,
            localRuntime: runtime)
    }
    #endif

    // Cohere preserves context across the whole dictation. Bound individual
    // formatting units so the narrow list detector never sends an unbounded
    // transcript to Qwen.
    static let localUnitPolicy = LocalUnitPolicy(maximumUnitSeconds: 90)

    /// Resolve the streaming cycle interval, honoring a positive
    /// `UNRAMBLE_CYCLE_INTERVAL` override and defaulting to three seconds.
    public static func cycleInterval(
        from environment: [String: String]
    ) -> TimeInterval {
        if let raw = environment["UNRAMBLE_CYCLE_INTERVAL"],
            let value = Double(raw), value > 0 {
            return value
        }
        return 3
    }
}
