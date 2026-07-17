import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device LLM engine using MLX via mlx-swift-lm.
///
/// Load a model from a local directory and run text completions on
/// Apple Silicon GPU via the MLX runtime.
/// Completion access is serialized through `ModelContainer`.
public final class MLXLLMEngine: LocalLLMEngine, @unchecked Sendable {

    public let name: String
    private let modelDirectory: URL
    private let adapterDirectory: URL?
    private let lock = NSLock()
    private var container: ModelContainer?
    private var loadGeneration: UInt = 0
    private let loadFlight = AsyncSingleFlight<Void>()

    /// - Parameters:
    ///   - name: Display name for diagnostics.
    ///   - modelDirectory: Local directory containing model configuration,
    ///     tokenizer, and weights.
    ///   - adapterDirectory: Optional local LoRA adapter directory
    ///     containing `adapter_config.json` and `adapters.safetensors`.
    public init(
        name: String,
        modelDirectory: URL,
        adapterDirectory: URL? = nil
    ) {
        self.name = name
        self.modelDirectory = modelDirectory
        self.adapterDirectory = adapterDirectory
    }

    public var isReady: Bool { lock.withLock { container != nil } }

    public func load() async throws {
        let generation = lock.withLock { () -> UInt? in
            container == nil ? loadGeneration : nil
        }
        guard let generation else { return }

        try await loadFlight.run { [self] in
            let shouldLoad = lock.withLock {
                container == nil && loadGeneration == generation
            }
            guard shouldLoad else {
                if isReady { return }
                throw CancellationError()
            }

            try Self.validateModelDirectory(modelDirectory)
            try Self.validateAdapterDirectory(adapterDirectory)
            try Task.checkCancellation()

            let loaded = try await loadModelContainer(
                from: modelDirectory,
                using: TokenizerLoaderBridge())
            try Task.checkCancellation()

            if let adapterDirectory {
                let adapter = try LoRAContainer.from(
                    directory: adapterDirectory)
                try await loaded.perform { context in
                    try context.model.load(adapter: adapter)
                }
                Log.debug(
                    "[MLXLLMEngine] \(name) adapter loaded from "
                        + adapterDirectory.path)
            }

            try Task.checkCancellation()
            let installed = lock.withLock {
                guard loadGeneration == generation else { return false }
                container = loaded
                return true
            }
            guard installed else { throw CancellationError() }
            Log.debug("[MLXLLMEngine] \(name) loaded")
        }
    }

    /// Cancel and drain an in-progress load before releasing the container.
    /// A concurrent `load()` may receive `CancellationError` and should retry
    /// after this method returns if it still requires the model.
    public func unload() async {
        lock.withLock {
            loadGeneration &+= 1
            container = nil
        }
        await loadFlight.cancel()
        Log.debug("[MLXLLMEngine] \(name) unloaded")
    }

    private static func validateModelDirectory(_ modelDirectory: URL) throws {
        guard modelDirectory.isFileURL else {
            throw LocalModelError.modelLoadFailed(
                "Model directory must be a local file URL")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: modelDirectory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LocalModelError.modelNotFound(modelDirectory.path)
        }

        let requiredFiles = ["config.json", "tokenizer.json"]
        let missing = requiredFiles.filter {
            !FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent($0).path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: modelDirectory.path)) ?? []
        let hasWeights = files.contains { $0.hasSuffix(".safetensors") }

        guard missing.isEmpty, hasWeights else {
            let details = missing + (hasWeights ? [] : ["*.safetensors"])
            throw LocalModelError.modelLoadFailed(
                "Incomplete local model at \(modelDirectory.path); missing "
                    + details.joined(separator: ", "))
        }
    }

    private static func validateAdapterDirectory(_ adapterDirectory: URL?) throws {
        guard let adapterDirectory else { return }
        guard adapterDirectory.isFileURL else {
            throw LocalModelError.modelLoadFailed(
                "Adapter directory must be a local file URL")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: adapterDirectory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LocalModelError.modelNotFound(adapterDirectory.path)
        }

        let requiredFiles = ["adapter_config.json", "adapters.safetensors"]
        let missing = requiredFiles.filter {
            !FileManager.default.fileExists(
                atPath: adapterDirectory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw LocalModelError.modelLoadFailed(
                "Incomplete local adapter at \(adapterDirectory.path); missing "
                    + missing.joined(separator: ", "))
        }
    }

    public func complete(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 512
    ) async throws -> String {
        try await complete(
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            maxTokens: maxTokens, temperature: 0)
    }

    public func complete(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        guard let container = lock.withLock({ container }) else {
            throw LocalModelError.modelNotLoaded
        }

        let params = GenerateParameters(
            maxTokens: maxTokens, temperature: Float(temperature))
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: params)

        let result = try await session.respond(to: userPrompt)
        var cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Qwen3 adapter sometimes appends a trailing quote.
        // Strip it so it doesn't leak into injected text.
        while cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
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
