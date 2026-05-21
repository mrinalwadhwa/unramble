import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device LLM engine using MLX via mlx-swift-lm.
///
/// Load a HuggingFace model (e.g. "mlx-community/Qwen3-0.6B-4bit")
/// and run text completions on Apple Silicon GPU via the MLX runtime.
/// Thread-safe: all model access is serialized through `ModelContainer`.
public final class MLXLLMEngine: LocalLLMEngine, @unchecked Sendable {

    public let name: String
    private let modelID: String
    private let adapterPath: String?
    private let lock = NSLock()
    private var container: ModelContainer?

    /// - Parameters:
    ///   - name: Display name for diagnostics.
    ///   - modelID: HuggingFace model ID (e.g. "mlx-community/Qwen3-0.6B-4bit")
    ///     or absolute path to a local model directory.
    ///   - adapterPath: Optional path to a LoRA adapter directory
    ///     containing `adapter_config.json` and `adapters.safetensors`.
    public init(name: String, modelID: String, adapterPath: String? = nil) {
        self.name = name
        self.modelID = modelID
        self.adapterPath = adapterPath
    }

    public var isReady: Bool { lock.withLock { container != nil } }

    public func load() async throws {
        guard !isReady else { return }

        // Support both HuggingFace repo IDs and local directory paths.
        let configuration: ModelConfiguration
        if modelID.hasPrefix("/") {
            configuration = ModelConfiguration(
                directory: URL(fileURLWithPath: modelID))
        } else {
            configuration = ModelConfiguration(id: modelID)
        }

        let loaded = try await loadModelContainer(
            from: HubDownloaderBridge(),
            using: TokenizerLoaderBridge(),
            configuration: configuration)

        // Apply LoRA adapter if provided.
        if let adapterPath {
            let adapterURL = URL(fileURLWithPath: adapterPath)
            let adapter = try LoRAContainer.from(directory: adapterURL)
            try await loaded.perform { context in
                try context.model.load(adapter: adapter)
            }
            Log.debug("[MLXLLMEngine] \(name) adapter loaded from \(adapterPath)")
        }

        lock.withLock { container = loaded }
        Log.debug("[MLXLLMEngine] \(name) loaded")
    }

    public func unload() async {
        lock.withLock { container = nil }
        Log.debug("[MLXLLMEngine] \(name) unloaded")
    }

    public func complete(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 512
    ) async throws -> String {
        guard let container = lock.withLock({ container }) else {
            throw LocalModelError.modelNotLoaded
        }

        let params = GenerateParameters(maxTokens: maxTokens)
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: params)

        let result = try await session.respond(to: userPrompt)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HuggingFace Bridge Types

/// Bridge `HuggingFace.HubClient` to the `MLXLMCommon.Downloader` protocol.
private struct HubDownloaderBridge: MLXLMCommon.Downloader {
    private let hub = HubClient()

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw LocalModelError.modelLoadFailed(
                "Invalid HuggingFace repository ID: '\(id)'")
        }
        let revision = revision ?? "main"

        return try await hub.downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            })
    }
}

/// Bridge `Tokenizers.AutoTokenizer` to the `MLXLMCommon.TokenizerLoader`
/// protocol.
private struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(
            modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Bridge a `Tokenizers.Tokenizer` to the `MLXLMCommon.Tokenizer` protocol.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools,
                additionalContext: additionalContext)
        } catch {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
