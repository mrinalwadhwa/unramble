import CoreML
import Foundation

/// On-device speech-to-text engine using NVIDIA Parakeet TDT 0.6B v3.
///
/// Run the Parakeet FastConformer-TDT model via CoreML on the Neural
/// Engine and GPU. Four CoreML models form the pipeline:
///
/// 1. **Preprocessor** — raw PCM audio to 128-bin mel spectrogram
/// 2. **Encoder** — mel to contextual embeddings (FastConformer, ANE)
/// 3. **Decoder** — stateful LSTM prediction network
/// 4. **JointDecision** — combines encoder + decoder, returns token
///    ID and duration in one step
///
/// Audio is processed in fixed 15-second windows (240,000 samples at
/// 16 kHz). Shorter audio is zero-padded. Longer audio is chunked.
///
/// Expected model directory layout:
/// ```
/// parakeet-tdt-0.6b-v3-coreml/
///   Preprocessor.mlmodelc/
///   Encoder.mlmodelc/
///   Decoder.mlmodelc/
///   JointDecisionv3.mlmodelc/
///   parakeet_v3_vocab.json
/// ```
public final class ParakeetEngine: LocalSTTEngine, @unchecked Sendable {

    public let name = "Parakeet TDT 0.6B v3"

    private let lock = NSLock()
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var vocabulary: [String]?

    private let modelManager: LocalModelManager
    private let modelID: String

    // MARK: - Constants

    static let sampleRate = 16000
    /// Maximum audio samples per window (15 seconds).
    static let maxSamples = 240_000
    /// Encoder output frames for a full 15s window.
    static let maxEncoderFrames = 188
    /// Encoder output dimension.
    static let encoderDim = 1024
    /// Decoder LSTM layers.
    static let decoderLayers = 2
    /// Decoder hidden dimension.
    static let decoderHidden = 640
    /// Blank token ID (vocabulary size).
    static let blankID = 8192
    /// Maximum symbols emitted per encoder frame (safety limit).
    static let maxSymbolsPerStep = 10

    public init(
        modelManager: LocalModelManager,
        modelID: String = "parakeet-tdt-0.6b-v3-coreml"
    ) {
        self.modelManager = modelManager
        self.modelID = modelID
    }

    public var isReady: Bool {
        lock.withLock { encoder != nil && vocabulary != nil }
    }

    // MARK: - Load / Unload

    public func load() async throws {
        guard !isReady else { return }

        let modelDir = modelManager.modelPath(for: modelID)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw LocalModelError.modelNotFound(modelDir.path)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly

        Log.debug("[ParakeetEngine] Loading Preprocessor...")
        let prep = try MLModel(
            contentsOf: modelDir.appendingPathComponent(
                "Preprocessor.mlmodelc"),
            configuration: cpuConfig)

        Log.debug("[ParakeetEngine] Loading Encoder...")
        let enc = try MLModel(
            contentsOf: modelDir.appendingPathComponent(
                "Encoder.mlmodelc"),
            configuration: config)

        Log.debug("[ParakeetEngine] Loading Decoder...")
        let dec = try MLModel(
            contentsOf: modelDir.appendingPathComponent(
                "Decoder.mlmodelc"),
            configuration: cpuConfig)

        Log.debug("[ParakeetEngine] Loading JointDecisionv3...")
        let jnt = try MLModel(
            contentsOf: modelDir.appendingPathComponent(
                "JointDecisionv3.mlmodelc"),
            configuration: cpuConfig)

        // Load vocabulary from JSON (format: {"0": "<unk>", "1": "▁the", ...}).
        let vocabPath = modelDir.appendingPathComponent(
            "parakeet_v3_vocab.json")
        let vocabData = try Data(contentsOf: vocabPath)
        let vocabDict = try JSONDecoder().decode(
            [String: String].self, from: vocabData)
        // Build ordered array from string keys.
        var vocab = [String](repeating: "", count: vocabDict.count)
        for (key, token) in vocabDict {
            if let idx = Int(key), idx >= 0, idx < vocab.count {
                vocab[idx] = token
            }
        }

        lock.withLock {
            preprocessor = prep
            encoder = enc
            decoder = dec
            joint = jnt
            vocabulary = vocab
        }
        Log.debug("[ParakeetEngine] All models loaded (\(vocab.count) tokens)")
    }

    public func unload() async {
        lock.withLock {
            preprocessor = nil
            encoder = nil
            decoder = nil
            joint = nil
            vocabulary = nil
        }
        Log.debug("[ParakeetEngine] Unloaded")
    }

    // MARK: - Transcribe

    public func transcribe(audio: Data) async throws -> String {
        guard isReady else { throw LocalModelError.modelNotLoaded }

        // Decode WAV to float32 samples.
        let samples = try decodeWAV(audio)
        guard samples.count > 160 else { return "" }

        // Process in 15s windows.
        let chunkSize = Self.maxSamples
        var allTokens: [Int] = []

        var offset = 0
        while offset < samples.count {
            let remaining = samples.count - offset
            let windowSize = min(remaining, chunkSize)
            let window = Array(samples[offset..<offset + windowSize])

            let tokens = try transcribeWindow(window)
            allTokens.append(contentsOf: tokens)

            offset += windowSize
        }

        // Map token IDs to text.
        let vocab = lock.withLock { vocabulary! }
        let text = allTokens
            .filter { $0 >= 0 && $0 < vocab.count }
            .map { vocab[$0] }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)

        return text
    }

    // MARK: - Single Window Transcription

    private func transcribeWindow(_ samples: [Float]) throws -> [Int] {
        let (prep, enc, dec, jnt) = lock.withLock {
            (preprocessor!, encoder!, decoder!, joint!)
        }

        // 1. Pad to maxSamples.
        var padded = [Float](repeating: 0, count: Self.maxSamples)
        let actualLen = min(samples.count, Self.maxSamples)
        for i in 0..<actualLen {
            padded[i] = samples[i]
        }

        // 2. Run preprocessor: audio -> mel.
        let audioArray = try MLMultiArray(shape: [1, Self.maxSamples as NSNumber], dataType: .float32)
        let audioPtr = audioArray.dataPointer.assumingMemoryBound(to: Float.self)
        padded.withUnsafeBufferPointer { src in
            audioPtr.update(from: src.baseAddress!, count: Self.maxSamples)
        }

        let audioLenArray = try MLMultiArray(shape: [1], dataType: .int32)
        audioLenArray[0] = NSNumber(value: Int32(actualLen))

        let prepInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: audioLenArray),
        ])
        let prepOutput = try prep.prediction(from: prepInput)

        let mel = prepOutput.featureValue(for: "mel")!.multiArrayValue!
        let melLen = prepOutput.featureValue(for: "mel_length")!.multiArrayValue!
        // 3. Run encoder: mel -> encoder features.
        let encInput = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: melLen),
        ])
        let encOutput = try enc.prediction(from: encInput)

        let encoderFeatures = encOutput.featureValue(for: "encoder")!.multiArrayValue!
        let encoderLen = encOutput.featureValue(for: "encoder_length")!.multiArrayValue!
        let numFrames = encoderLen[0].intValue

        // 4. TDT decode loop.
        return try tdtDecode(
            encoderFeatures: encoderFeatures,
            numFrames: numFrames,
            decoder: dec,
            joint: jnt)
    }

    // MARK: - TDT Decode

    private func tdtDecode(
        encoderFeatures: MLMultiArray,
        numFrames: Int,
        decoder: MLModel,
        joint: MLModel
    ) throws -> [Int] {
        // Initialize LSTM states to zeros. MLMultiArray does not
        // zero-initialize — we must fill explicitly.
        let stateShape: [NSNumber] = [
            Self.decoderLayers as NSNumber,
            1 as NSNumber,
            Self.decoderHidden as NSNumber,
        ]
        var hState = try MLMultiArray(shape: stateShape, dataType: .float32)
        var cState = try MLMultiArray(shape: stateShape, dataType: .float32)
        let stateBytes = Self.decoderLayers * Self.decoderHidden * MemoryLayout<Float>.size
        memset(hState.dataPointer, 0, stateBytes)
        memset(cState.dataPointer, 0, stateBytes)

        // Start with blank token.
        var lastToken = Self.blankID
        var tokens: [Int] = []
        var t = 0

        // Run initial decoder pass.
        var (decoderOut, hNew, cNew) = try runDecoder(
            decoder: decoder, token: lastToken,
            hState: hState, cState: cState)
        hState = hNew
        cState = cNew

        while t < numFrames {
            // Extract encoder frame at time t: [1, 1024, 1].
            let encStep = try extractEncoderFrame(
                encoderFeatures, at: t)

            // Run joint decision.
            var symbolsThisStep = 0

            while symbolsThisStep < Self.maxSymbolsPerStep {
                let (tokenID, duration) = try runJoint(
                    joint: joint,
                    encoderStep: encStep,
                    decoderStep: decoderOut)

                if tokenID == Self.blankID {
                    // Blank: advance by duration (minimum 1).
                    t += max(duration, 1)
                    break
                } else {
                    // Non-blank: emit token, update decoder.
                    tokens.append(tokenID)
                    lastToken = tokenID
                    symbolsThisStep += 1

                    (decoderOut, hNew, cNew) = try runDecoder(
                        decoder: decoder, token: lastToken,
                        hState: hState, cState: cState)
                    hState = hNew
                    cState = cNew

                    // If duration > 0, advance and break to next frame.
                    if duration > 0 {
                        t += duration
                        break
                    }
                    // duration == 0: stay at same frame, emit more tokens.
                }
            }

            // If we hit maxSymbolsPerStep, force advance.
            if symbolsThisStep >= Self.maxSymbolsPerStep {
                t += 1
            }

            // Safety: cap tokens per window.
            if tokens.count >= 150 { break }
        }

        return tokens
    }

    // MARK: - Model Calls

    private func runDecoder(
        decoder: MLModel,
        token: Int,
        hState: MLMultiArray,
        cState: MLMultiArray
    ) throws -> (decoderOut: MLMultiArray, h: MLMultiArray, c: MLMultiArray) {
        let targets = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targets[0] = NSNumber(value: Int32(token))

        let targetLen = try MLMultiArray(shape: [1], dataType: .int32)
        targetLen[0] = NSNumber(value: Int32(1))

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: targets),
            "target_length": MLFeatureValue(multiArray: targetLen),
            "h_in": MLFeatureValue(multiArray: hState),
            "c_in": MLFeatureValue(multiArray: cState),
        ])

        let output = try decoder.prediction(from: input)

        let decOut = output.featureValue(for: "decoder")!.multiArrayValue!
        let hOut = output.featureValue(for: "h_out")!.multiArrayValue!
        let cOut = output.featureValue(for: "c_out")!.multiArrayValue!

        return (decOut, hOut, cOut)
    }

    private func runJoint(
        joint: MLModel,
        encoderStep: MLMultiArray,
        decoderStep: MLMultiArray
    ) throws -> (tokenID: Int, duration: Int) {
        // Normalize decoder output to [1, 640, 1] layout.
        let normalizedDecoder = try normalizeDecoderOutput(decoderStep)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encoderStep),
            "decoder_step": MLFeatureValue(multiArray: normalizedDecoder),
        ])

        let output = try joint.prediction(from: input)

        let tokenID = output.featureValue(for: "token_id")!
            .multiArrayValue![0].intValue
        let duration = output.featureValue(for: "duration")!
            .multiArrayValue![0].intValue

        return (tokenID, duration)
    }

    // MARK: - Helpers

    /// Extract a single encoder frame at time index t into [1, 1024, 1].
    ///
    /// Handle both `[1, 1024, T]` and `[1, T, 1024]` layouts by
    /// detecting which axis matches the expected hidden size and using
    /// strides for correct access.
    private func extractEncoderFrame(
        _ encoder: MLMultiArray, at t: Int
    ) throws -> MLMultiArray {
        let dim = Self.encoderDim
        let shape = encoder.shape.map { $0.intValue }
        let strides = encoder.strides.map { $0.intValue }

        // Determine which axis is hidden (1024) and which is time.
        let hiddenAxis: Int
        let timeAxis: Int
        if shape[1] == dim {
            hiddenAxis = 1; timeAxis = 2
        } else if shape[2] == dim {
            hiddenAxis = 2; timeAxis = 1
        } else {
            throw LocalModelError.transcriptionFailed(
                "Encoder shape \(shape) has no axis matching hidden size \(dim)")
        }

        let hiddenStride = strides[hiddenAxis]
        let timeStride = strides[timeAxis]

        let frame = try MLMultiArray(
            shape: [1, dim as NSNumber, 1], dataType: .float32)
        let srcPtr = encoder.dataPointer.assumingMemoryBound(
            to: Float.self)
        let dstPtr = frame.dataPointer.assumingMemoryBound(
            to: Float.self)
        let dstStride = frame.strides[1].intValue

        let baseOffset = t * timeStride
        for d in 0..<dim {
            dstPtr[d * dstStride] = srcPtr[baseOffset + d * hiddenStride]
        }

        return frame
    }

    /// Normalize decoder output to [1, 640, 1] for the joint network.
    ///
    /// Decoder may output [1, 640, 1] or [1, 1, 640] depending on
    /// CoreML's internal layout.
    private func normalizeDecoderOutput(
        _ decoderOut: MLMultiArray
    ) throws -> MLMultiArray {
        let dim = Self.decoderHidden
        let shape = decoderOut.shape.map { $0.intValue }
        let strides = decoderOut.strides.map { $0.intValue }

        // Already in [1, 640, 1] format.
        if shape.count == 3 && shape[1] == dim && shape[2] == 1 {
            return decoderOut
        }

        // Detect hidden axis.
        let hiddenAxis: Int
        if shape.count == 3 && shape[1] == dim {
            hiddenAxis = 1
        } else if shape.count == 3 && shape[2] == dim {
            hiddenAxis = 2
        } else {
            throw LocalModelError.transcriptionFailed(
                "Decoder output shape \(shape) has no axis matching hidden size \(dim)")
        }

        let hiddenStride = strides[hiddenAxis]
        let result = try MLMultiArray(
            shape: [1, dim as NSNumber, 1], dataType: .float32)
        let srcPtr = decoderOut.dataPointer.assumingMemoryBound(
            to: Float.self)
        let dstPtr = result.dataPointer.assumingMemoryBound(
            to: Float.self)
        let dstStride = result.strides[1].intValue

        for d in 0..<dim {
            dstPtr[d * dstStride] = srcPtr[d * hiddenStride]
        }

        return result
    }

    /// Decode WAV file data to float32 samples normalized to [-1, 1].
    private func decodeWAV(_ data: Data) throws -> [Float] {
        guard data.count > WAVEncoder.headerSize else {
            throw LocalModelError.transcriptionFailed("Audio too short")
        }
        let pcmData = data.subdata(
            in: WAVEncoder.headerSize..<data.count)
        let sampleCount = pcmData.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16s[i]) / 32768.0
            }
        }
        return samples
    }
}
