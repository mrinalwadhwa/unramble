import CoreML
import Foundation

/// On-device speech-to-text engine using NVIDIA Nemotron ASR 0.6B.
///
/// Run the Nemotron FastConformer-RNNT streaming model via CoreML on
/// the Neural Engine. Four CoreML models form the pipeline:
///
/// 1. **Preprocessor** — raw PCM audio to 128-bin mel spectrogram
/// 2. **Encoder** — mel to contextual embeddings (INT8, ANE)
/// 3. **Decoder** — stateful 2-layer LSTM prediction network
/// 4. **Joint** — combines encoder + decoder, returns logits
///
/// The encoder processes mel spectrograms in fixed chunks (56 frames
/// = 560 ms) with a 9-frame pre-encode cache for temporal context.
/// Encoder caches (attention + convolution) persist across chunks for
/// cache-aware streaming.
///
/// Expected model directory layout:
/// ```
/// nemotron_coreml_560ms/
///   preprocessor.mlmodelc/
///   encoder/encoder_int8.mlmodelc/
///   decoder.mlmodelc/
///   joint.mlmodelc/
///   tokenizer.json
///   metadata.json
/// ```
public final class NemotronEngine: LocalSTTEngine, @unchecked Sendable {

    public let name = "Nemotron ASR 0.6B"

    private let lock = NSLock()
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var vocabulary: [String]?
    private var biasModel: BiasModel?

    private let modelManager: LocalModelManager
    private let modelID: String
    private let modelPathOverride: String?

    // MARK: - Constants

    static let sampleRate = 16000
    static let chunkMelFrames = 56
    static let preEncodeCache = 9
    static let totalMelFrames = 65
    static let melBins = 128
    static let encoderDim = 1024
    static let decoderLayers = 2
    static let decoderHidden = 640
    static let vocabSize = 1024
    static let blankID = 1024
    static let maxSymbolsPerStep = 10
    static let cacheChannelShape: [NSNumber] = [1, 24, 70, 1024]
    static let cacheTimeShape: [NSNumber] = [1, 24, 1024, 8]

    public init(
        modelManager: LocalModelManager,
        modelID: String = "nemotron-speech-streaming-en-0.6b-coreml",
        modelPath: String? = nil
    ) {
        self.modelManager = modelManager
        self.modelID = modelID
        self.modelPathOverride = modelPath
    }

    public var isReady: Bool {
        lock.withLock { encoder != nil && vocabulary != nil }
    }

    // MARK: - Load / Unload

    public func load() async throws {
        guard !isReady else { return }

        let modelDir: URL
        if let override = modelPathOverride {
            modelDir = URL(fileURLWithPath: override)
        } else {
            modelDir = modelManager.modelPath(for: modelID)
        }

        let variantDir = modelDir.appendingPathComponent(
            "nemotron_coreml_560ms")
        let actualDir: URL
        if FileManager.default.fileExists(atPath: variantDir.path) {
            actualDir = variantDir
        } else {
            actualDir = modelDir
        }

        guard FileManager.default.fileExists(atPath: actualDir.path) else {
            throw LocalModelError.modelNotFound(actualDir.path)
        }

        let aneConfig = MLModelConfiguration()
        aneConfig.computeUnits = .cpuAndNeuralEngine

        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly

        Log.debug("[NemotronEngine] Loading Preprocessor...")
        let prep = try MLModel(
            contentsOf: actualDir.appendingPathComponent(
                "preprocessor.mlmodelc"),
            configuration: cpuConfig)

        Log.debug("[NemotronEngine] Loading Encoder...")
        let enc = try MLModel(
            contentsOf: actualDir
                .appendingPathComponent("encoder")
                .appendingPathComponent("encoder_int8.mlmodelc"),
            configuration: aneConfig)

        Log.debug("[NemotronEngine] Loading Decoder...")
        let dec = try MLModel(
            contentsOf: actualDir.appendingPathComponent(
                "decoder.mlmodelc"),
            configuration: cpuConfig)

        Log.debug("[NemotronEngine] Loading Joint...")
        let jnt = try MLModel(
            contentsOf: actualDir.appendingPathComponent(
                "joint.mlmodelc"),
            configuration: cpuConfig)

        let tokenizerPath = actualDir.appendingPathComponent(
            "tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerPath)
        let tokenizerDict = try JSONDecoder().decode(
            [String: String].self, from: tokenizerData)
        var vocab = [String](repeating: "", count: tokenizerDict.count)
        for (key, token) in tokenizerDict {
            if let idx = Int(key), idx >= 0, idx < vocab.count {
                vocab[idx] = token
            }
        }

        let bias = BiasModel.load(vocabulary: vocab)
        lock.withLock {
            preprocessor = prep
            encoder = enc
            decoder = dec
            joint = jnt
            vocabulary = vocab
            biasModel = bias
        }
        Log.debug(
            "[NemotronEngine] All models loaded (\(vocab.count) tokens)")
    }

    public func unload() async {
        lock.withLock {
            preprocessor = nil
            encoder = nil
            decoder = nil
            joint = nil
            vocabulary = nil
        }
        Log.debug("[NemotronEngine] Unloaded")
    }

    // MARK: - Preprocessor

    private func runPreprocessor(
        _ prep: MLModel, samples: [Float]
    ) throws -> (mel: MLMultiArray, frameCount: Int) {
        let sampleCount = samples.count
        let audioArray = try MLMultiArray(
            shape: [1, sampleCount as NSNumber], dataType: .float32)
        let audioPtr = audioArray.dataPointer.assumingMemoryBound(
            to: Float.self)
        samples.withUnsafeBufferPointer { src in
            audioPtr.update(from: src.baseAddress!, count: sampleCount)
        }

        let audioLenArray = try MLMultiArray(
            shape: [1], dataType: .int32)
        audioLenArray[0] = NSNumber(value: Int32(sampleCount))

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: audioLenArray),
        ])
        let output = try prep.prediction(from: input)

        let mel = output.featureValue(for: "mel")!.multiArrayValue!
        let melLen = output.featureValue(
            for: "mel_length")!.multiArrayValue!
        let frameCount = melLen[0].intValue

        return (mel, frameCount)
    }

    // MARK: - RNNT Decode

    private func rnntDecode(
        encoded: MLMultiArray,
        numFrames: Int,
        decoder: MLModel,
        joint: MLModel,
        decoderOut: inout MLMultiArray,
        hState: inout MLMultiArray,
        cState: inout MLMultiArray,
        lastToken: inout Int
    ) throws -> [Int] {
        var tokens: [Int] = []
        var t = 0
        // Contextual biasing state: resets per decode call. In the streaming
        // path that is per-chunk, so a bias phrase must fall within one chunk
        // (fine for utterance-initial names like a greeting).
        var bias = biasModel.map { BiasState(model: $0) }

        while t < numFrames {
            let encStep = try extractEncoderFrame(encoded, at: t)

            var symbolsThisStep = 0
            while symbolsThisStep < Self.maxSymbolsPerStep {
                let tokenID = try runJoint(
                    joint: joint,
                    encoderStep: encStep,
                    decoderStep: decoderOut,
                    boosts: bias?.boosts())

                if tokenID == Self.blankID {
                    t += 1
                    break
                } else {
                    tokens.append(tokenID)
                    bias?.advance(tokenID)
                    lastToken = tokenID
                    symbolsThisStep += 1

                    let (decOut, hNew, cNew) = try runDecoder(
                        decoder: decoder, token: lastToken,
                        hState: hState, cState: cState)
                    decoderOut = decOut
                    hState = hNew
                    cState = cNew
                }
            }

            if symbolsThisStep >= Self.maxSymbolsPerStep {
                t += 1
            }
        }

        return tokens
    }

    // MARK: - Model Calls

    private func runDecoder(
        decoder: MLModel,
        token: Int,
        hState: MLMultiArray,
        cState: MLMultiArray
    ) throws -> (
        decoderOut: MLMultiArray, h: MLMultiArray, c: MLMultiArray
    ) {
        let tokenArr = try MLMultiArray(
            shape: [1, 1], dataType: .int32)
        tokenArr[0] = NSNumber(value: Int32(token))

        let tokenLen = try MLMultiArray(
            shape: [1], dataType: .int32)
        tokenLen[0] = NSNumber(value: Int32(1))

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "token": MLFeatureValue(multiArray: tokenArr),
            "token_length": MLFeatureValue(multiArray: tokenLen),
            "h_in": MLFeatureValue(multiArray: hState),
            "c_in": MLFeatureValue(multiArray: cState),
        ])
        let output = try decoder.prediction(from: input)

        let decOut = output.featureValue(
            for: "decoder_out")!.multiArrayValue!
        let hOut = output.featureValue(
            for: "h_out")!.multiArrayValue!
        let cOut = output.featureValue(
            for: "c_out")!.multiArrayValue!

        return (decOut, hOut, cOut)
    }

    private func runJoint(
        joint: MLModel,
        encoderStep: MLMultiArray,
        decoderStep: MLMultiArray,
        boosts: [Int: Float]? = nil
    ) throws -> Int {
        let normalizedDecoder = try normalizeToShape(
            decoderStep,
            targetShape: [1, Self.decoderHidden, 1],
            hiddenSize: Self.decoderHidden)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "encoder": MLFeatureValue(multiArray: encoderStep),
            "decoder": MLFeatureValue(multiArray: normalizedDecoder),
        ])
        let output = try joint.prediction(from: input)

        let logits = output.featureValue(
            for: "logits")!.multiArrayValue!

        return argmax(logits, count: Self.vocabSize + 1, boosts: boosts)
    }

    // MARK: - Helpers

    private func extractEncoderFrame(
        _ encoder: MLMultiArray, at t: Int
    ) throws -> MLMultiArray {
        let dim = Self.encoderDim
        let shape = encoder.shape.map { $0.intValue }
        let strides = encoder.strides.map { $0.intValue }

        let hiddenAxis: Int
        let timeAxis: Int
        if shape.count == 3 && shape[1] == dim {
            hiddenAxis = 1; timeAxis = 2
        } else if shape.count == 3 && shape[2] == dim {
            hiddenAxis = 2; timeAxis = 1
        } else {
            throw LocalModelError.transcriptionFailed(
                "Encoder shape \(shape) has no axis matching \(dim)")
        }

        let frame = try MLMultiArray(
            shape: [1, dim as NSNumber, 1], dataType: .float32)

        if encoder.dataType == .float16 {
            let srcPtr = encoder.dataPointer.assumingMemoryBound(
                to: UInt16.self)
            let dstPtr = frame.dataPointer.assumingMemoryBound(
                to: Float.self)
            let dstStride = frame.strides[1].intValue
            let baseOffset = t * strides[timeAxis]
            for d in 0..<dim {
                dstPtr[d * dstStride] = Self.float16ToFloat32(
                    srcPtr[baseOffset + d * strides[hiddenAxis]])
            }
        } else {
            let srcPtr = encoder.dataPointer.assumingMemoryBound(
                to: Float.self)
            let dstPtr = frame.dataPointer.assumingMemoryBound(
                to: Float.self)
            let dstStride = frame.strides[1].intValue
            let baseOffset = t * strides[timeAxis]
            for d in 0..<dim {
                dstPtr[d * dstStride] =
                    srcPtr[baseOffset + d * strides[hiddenAxis]]
            }
        }

        return frame
    }

    private func normalizeToShape(
        _ array: MLMultiArray,
        targetShape: [Int],
        hiddenSize: Int
    ) throws -> MLMultiArray {
        let shape = array.shape.map { $0.intValue }

        if shape.count == 3 && shape[1] == hiddenSize
            && shape[2] == 1
        {
            return array
        }

        let strides = array.strides.map { $0.intValue }
        let hiddenAxis: Int
        if shape.count == 3 && shape[1] == hiddenSize {
            hiddenAxis = 1
        } else if shape.count == 3 && shape[2] == hiddenSize {
            hiddenAxis = 2
        } else {
            throw LocalModelError.transcriptionFailed(
                "Array shape \(shape) has no axis matching \(hiddenSize)"
            )
        }

        let result = try MLMultiArray(
            shape: [
                1, hiddenSize as NSNumber, 1,
            ], dataType: .float32)

        if array.dataType == .float16 {
            let srcPtr = array.dataPointer.assumingMemoryBound(
                to: UInt16.self)
            let dstPtr = result.dataPointer.assumingMemoryBound(
                to: Float.self)
            let dstStride = result.strides[1].intValue
            let hiddenStride = strides[hiddenAxis]
            for d in 0..<hiddenSize {
                dstPtr[d * dstStride] = Self.float16ToFloat32(
                    srcPtr[d * hiddenStride])
            }
        } else {
            let srcPtr = array.dataPointer.assumingMemoryBound(
                to: Float.self)
            let dstPtr = result.dataPointer.assumingMemoryBound(
                to: Float.self)
            let dstStride = result.strides[1].intValue
            let hiddenStride = strides[hiddenAxis]
            for d in 0..<hiddenSize {
                dstPtr[d * dstStride] = srcPtr[d * hiddenStride]
            }
        }

        return result
    }

    private func argmax(
        _ logits: MLMultiArray, count: Int, boosts: [Int: Float]? = nil
    ) -> Int {
        var bestIdx = 0
        var bestVal: Float = -.infinity

        if logits.dataType == .float16 {
            let ptr = logits.dataPointer.assumingMemoryBound(
                to: UInt16.self)
            for i in 0..<count {
                let val = Self.float16ToFloat32(ptr[i]) + (boosts?[i] ?? 0)
                if val > bestVal {
                    bestVal = val
                    bestIdx = i
                }
            }
        } else {
            let ptr = logits.dataPointer.assumingMemoryBound(
                to: Float.self)
            for i in 0..<count {
                let val = ptr[i] + (boosts?[i] ?? 0)
                if val > bestVal {
                    bestVal = val
                    bestIdx = i
                }
            }
        }

        return bestIdx
    }

    static func float16ToFloat32(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1f)
        var fraction = UInt32(bits & 0x03ff)
        let floatBits: UInt32

        switch exponent {
        case 0 where fraction == 0:
            floatBits = sign
        case 0:
            var shift = 0
            while fraction & 0x0400 == 0 {
                fraction <<= 1
                shift += 1
            }
            fraction &= 0x03ff
            let floatExponent = UInt32(127 - 15 + 1 - shift)
            floatBits = sign | (floatExponent << 23) | (fraction << 13)
        case 0x1f:
            floatBits = sign | 0x7f80_0000 | (fraction << 13)
        default:
            let floatExponent = UInt32(exponent + (127 - 15))
            floatBits = sign | (floatExponent << 23) | (fraction << 13)
        }
        return Float(bitPattern: floatBits)
    }

    private func zeroArray(
        shape: [NSNumber],
        dataType: MLMultiArrayDataType = .float32
    ) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape, dataType: dataType)
        let byteCount: Int
        switch dataType {
        case .float32:
            byteCount = arr.count * MemoryLayout<Float>.size
        case .int32:
            byteCount = arr.count * MemoryLayout<Int32>.size
        default:
            byteCount = arr.count * MemoryLayout<Float>.size
        }
        memset(arr.dataPointer, 0, byteCount)
        return arr
    }

    /// Detokenize RNNT output IDs to text.
    fileprivate func detokenize(_ tokens: [Int], vocab: [String]) -> String {
        tokens
            .filter { $0 >= 0 && $0 < vocab.count }
            .map { vocab[$0] }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Incremental Streaming

/// Mutable state for one incremental Nemotron transcription session.
///
/// Carries the encoder and decoder streaming caches across audio chunks
/// so a long utterance is transcribed continuously.
fileprivate final class NemotronStreamingState: @unchecked Sendable {
    fileprivate var cacheChannel: MLMultiArray
    fileprivate var cacheTime: MLMultiArray
    fileprivate var cacheLen: MLMultiArray
    fileprivate var hState: MLMultiArray
    fileprivate var cState: MLMultiArray
    fileprivate var decoderOut: MLMultiArray
    fileprivate var lastToken: Int
    /// Last `preEncodeCache` mel frames of the previous chunk, kept as
    /// left context for the next chunk's encoder input.
    fileprivate var melCache: MLMultiArray?
    fileprivate var tokens: [Int] = []
    /// Audio samples buffered below one full chunk.
    fileprivate var pending: [Float] = []

    fileprivate init(
        cacheChannel: MLMultiArray, cacheTime: MLMultiArray,
        cacheLen: MLMultiArray, hState: MLMultiArray, cState: MLMultiArray,
        decoderOut: MLMultiArray, lastToken: Int
    ) {
        self.cacheChannel = cacheChannel
        self.cacheTime = cacheTime
        self.cacheLen = cacheLen
        self.hState = hState
        self.cState = cState
        self.decoderOut = decoderOut
        self.lastToken = lastToken
    }
}

extension NemotronEngine {

    /// Samples per streaming chunk: `chunkMelFrames` × 10ms stride.
    static let chunkSamples = chunkMelFrames * 160  // 56 * 160 = 8960

    /// Open a new incremental streaming session. Requires the models to
    /// be loaded.
    fileprivate func makeStreamingState() throws -> NemotronStreamingState {
        guard isReady else { throw LocalModelError.modelNotLoaded }
        let dec = lock.withLock { decoder! }

        let cacheChannel = try zeroArray(shape: Self.cacheChannelShape)
        let cacheTime = try zeroArray(shape: Self.cacheTimeShape)
        let cacheLen = try zeroArray(shape: [1], dataType: .int32)
        let decoderShape: [NSNumber] = [
            Self.decoderLayers as NSNumber, 1,
            Self.decoderHidden as NSNumber,
        ]
        let hState = try zeroArray(shape: decoderShape)
        let cState = try zeroArray(shape: decoderShape)
        let (decoderOut, _, _) = try runDecoder(
            decoder: dec, token: Self.blankID,
            hState: hState, cState: cState)

        return NemotronStreamingState(
            cacheChannel: cacheChannel, cacheTime: cacheTime,
            cacheLen: cacheLen, hState: hState, cState: cState,
            decoderOut: decoderOut, lastToken: Self.blankID)
    }

    /// Feed audio samples. Complete chunks are transcribed immediately;
    /// a partial remainder is buffered for the next call or `finish`.
    fileprivate func feed(
        _ samples: [Float], into state: NemotronStreamingState
    ) throws {
        guard isReady else { throw LocalModelError.modelNotLoaded }
        state.pending.append(contentsOf: samples)
        while state.pending.count >= Self.chunkSamples {
            let chunk = Array(state.pending.prefix(Self.chunkSamples))
            state.pending.removeFirst(Self.chunkSamples)
            try processStreamingChunk(chunk, state: state)
        }
    }

    /// Flush any buffered remainder (zero-padded to a full chunk) and
    /// return the final transcript.
    fileprivate func finishStreaming(
        _ state: NemotronStreamingState
    ) throws -> String {
        guard isReady else { throw LocalModelError.modelNotLoaded }
        if !state.pending.isEmpty {
            var chunk = state.pending
            state.pending.removeAll()
            if chunk.count < Self.chunkSamples {
                chunk.append(contentsOf: [Float](
                    repeating: 0, count: Self.chunkSamples - chunk.count))
            }
            try processStreamingChunk(chunk, state: state)
        }
        return transcript(state)
    }

    /// The running transcript for everything committed so far.
    fileprivate func transcript(_ state: NemotronStreamingState) -> String {
        let vocab = lock.withLock { vocabulary! }
        return detokenize(state.tokens, vocab: vocab)
    }

    // MARK: - Chunk Processing

    private func processStreamingChunk(
        _ samples: [Float], state: NemotronStreamingState
    ) throws {
        let (prep, enc, dec, jnt) = lock.withLock {
            (preprocessor!, encoder!, decoder!, joint!)
        }

        let (chunkMel, melFrames) = try runPreprocessor(
            prep, samples: samples)

        let inputMel = try buildStreamingMelInput(
            chunkMel: chunkMel, chunkFrames: melFrames,
            melCache: state.melCache)
        state.melCache = try extractMelTail(
            chunkMel, chunkFrames: melFrames)

        let melLen = try MLMultiArray(shape: [1], dataType: .int32)
        melLen[0] = NSNumber(value: Int32(Self.totalMelFrames))

        let encInput = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: inputMel),
            "mel_length": MLFeatureValue(multiArray: melLen),
            "cache_channel": MLFeatureValue(multiArray: state.cacheChannel),
            "cache_time": MLFeatureValue(multiArray: state.cacheTime),
            "cache_len": MLFeatureValue(multiArray: state.cacheLen),
        ])
        let encOutput = try enc.prediction(from: encInput)

        let encoded = encOutput.featureValue(
            for: "encoded")!.multiArrayValue!
        let encodedLen = encOutput.featureValue(
            for: "encoded_length")!.multiArrayValue!
        state.cacheChannel = encOutput.featureValue(
            for: "cache_channel_out")!.multiArrayValue!
        state.cacheTime = encOutput.featureValue(
            for: "cache_time_out")!.multiArrayValue!
        state.cacheLen = encOutput.featureValue(
            for: "cache_len_out")!.multiArrayValue!

        let numFrames = encodedLen[0].intValue

        var decoderOut = state.decoderOut
        var hState = state.hState
        var cState = state.cState
        var lastToken = state.lastToken
        let tokens = try rnntDecode(
            encoded: encoded, numFrames: numFrames,
            decoder: dec, joint: jnt,
            decoderOut: &decoderOut, hState: &hState,
            cState: &cState, lastToken: &lastToken)
        state.decoderOut = decoderOut
        state.hState = hState
        state.cState = cState
        state.lastToken = lastToken
        state.tokens.append(contentsOf: tokens)
    }

    /// Build the `[1, melBins, totalMelFrames]` encoder input: the
    /// previous chunk's `preEncodeCache` mel frames (or zeros on the
    /// first chunk) followed by this chunk's mel frames.
    private func buildStreamingMelInput(
        chunkMel: MLMultiArray, chunkFrames: Int, melCache: MLMultiArray?
    ) throws -> MLMultiArray {
        let result = try zeroArray(shape: [
            1, Self.melBins as NSNumber, Self.totalMelFrames as NSNumber,
        ])
        if let melCache {
            copyMelFrames(
                from: melCache, srcStart: 0, count: Self.preEncodeCache,
                to: result, dstStart: 0)
        }
        let n = min(chunkFrames, Self.chunkMelFrames)
        copyMelFrames(
            from: chunkMel, srcStart: 0, count: n,
            to: result, dstStart: Self.preEncodeCache)
        return result
    }

    /// Extract the last `preEncodeCache` mel frames of a chunk as a
    /// float32 `[1, melBins, preEncodeCache]` array for the next chunk.
    private func extractMelTail(
        _ chunkMel: MLMultiArray, chunkFrames: Int
    ) throws -> MLMultiArray {
        let result = try zeroArray(shape: [
            1, Self.melBins as NSNumber, Self.preEncodeCache as NSNumber,
        ])
        let n = min(chunkFrames, Self.preEncodeCache)
        let srcStart = max(0, chunkFrames - Self.preEncodeCache)
        copyMelFrames(
            from: chunkMel, srcStart: srcStart, count: n,
            to: result, dstStart: 0)
        return result
    }

    /// Copy `count` mel frames between arrays, converting float16 to
    /// float32. The destination is assumed float32.
    private func copyMelFrames(
        from src: MLMultiArray, srcStart: Int, count: Int,
        to dst: MLMultiArray, dstStart: Int
    ) {
        let srcStrides = src.strides.map { $0.intValue }
        let dstStrides = dst.strides.map { $0.intValue }
        let dstPtr = dst.dataPointer.assumingMemoryBound(to: Float.self)
        if src.dataType == .float16 {
            let srcPtr = src.dataPointer.assumingMemoryBound(to: UInt16.self)
            for bin in 0..<Self.melBins {
                for f in 0..<count {
                    let srcIdx = bin * srcStrides[1]
                        + (srcStart + f) * srcStrides[2]
                    let dstIdx = bin * dstStrides[1]
                        + (dstStart + f) * dstStrides[2]
                    dstPtr[dstIdx] = Self.float16ToFloat32(srcPtr[srcIdx])
                }
            }
        } else {
            let srcPtr = src.dataPointer.assumingMemoryBound(to: Float.self)
            for bin in 0..<Self.melBins {
                for f in 0..<count {
                    let srcIdx = bin * srcStrides[1]
                        + (srcStart + f) * srcStrides[2]
                    let dstIdx = bin * dstStrides[1]
                        + (dstStart + f) * dstStrides[2]
                    dstPtr[dstIdx] = srcPtr[srcIdx]
                }
            }
        }
    }
}

extension NemotronEngine: LocalStreamingRecognizer {

    public func makeRecognitionSession() throws -> any LocalRecognitionSession {
        NemotronRecognitionSession(
            engine: self, state: try makeStreamingState())
    }
}

private final class NemotronRecognitionSession: LocalRecognitionSession {
    private let engine: NemotronEngine
    private let state: NemotronStreamingState

    init(engine: NemotronEngine, state: NemotronStreamingState) {
        self.engine = engine
        self.state = state
    }

    func feed(_ samples: [Float]) throws {
        try engine.feed(samples, into: state)
    }

    func transcript() -> String {
        engine.transcript(state)
    }

    func finish() throws -> String {
        try engine.finishStreaming(state)
    }
}

// MARK: - Contextual Biasing (shallow fusion)

/// A trie over the subword-token sequences of a set of bias phrases (names,
/// jargon). During decoding, any token that would extend an active partial
/// match gets its logit boosted before argmax, so the recognizer prefers a
/// known phrase at points the acoustic model is otherwise ambiguous.
///
/// Flag-gated and off by default: built only when `/tmp/unramble-stt-bias`
/// exists (one bias phrase per line). Absent the flag, `biasModel` is nil and
/// decoding is byte-for-byte unchanged.
final class BiasModel {
    final class Node {
        var children: [Int: Node] = [:]
    }

    let root = Node()
    let weight: Float

    private init(weight: Float) {
        self.weight = weight
    }

    static func load(vocabulary: [String]) -> BiasModel? {
        let flagPath = "/tmp/unramble-stt-bias"
        guard let raw = try? String(contentsOfFile: flagPath, encoding: .utf8)
        else { return nil }
        let phrases = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return nil }

        let weight = (try? String(
            contentsOfFile: "/tmp/unramble-stt-bias-weight", encoding: .utf8))
            .flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? 8.0

        guard let model = build(
            phrases: phrases, vocabulary: vocabulary, weight: weight)
        else { return nil }
        Log.debug(
            "[NemotronEngine] Bias on: \(phrases) weight=\(weight)")
        return model
    }

    /// Build a trie from bias phrases and a vocabulary. Returns nil if none of
    /// the phrases tokenize. Separated from `load` so it is testable without
    /// the `/tmp` flag.
    static func build(
        phrases: [String], vocabulary: [String], weight: Float
    ) -> BiasModel? {
        let model = BiasModel(weight: weight)
        var added = false
        for phrase in phrases {
            let ids = tokenize(phrase, vocabulary: vocabulary)
            guard !ids.isEmpty else { continue }
            added = true
            var node = model.root
            for id in ids {
                if let next = node.children[id] {
                    node = next
                } else {
                    let next = Node()
                    node.children[id] = next
                    node = next
                }
            }
        }
        return added ? model : nil
    }

    /// Greedy SentencePiece longest-match over the id→token vocabulary. No
    /// merges file is available, so greedy longest-prefix is the standard
    /// fallback; case is preserved (the vocab is mixed-case, e.g. "▁P").
    static func tokenize(_ phrase: String, vocabulary: [String]) -> [Int] {
        var remaining = Substring("\u{2581}" + phrase)
        var ids: [Int] = []
        while !remaining.isEmpty {
            var bestLen = 0
            var bestID = -1
            for (id, token) in vocabulary.enumerated() where !token.isEmpty {
                let len = token.count
                if len > bestLen, remaining.hasPrefix(token) {
                    bestLen = len
                    bestID = id
                }
            }
            guard bestID >= 0 else { return [] }
            ids.append(bestID)
            remaining = remaining.dropFirst(bestLen)
        }
        return ids
    }
}

/// Per-utterance match state over a `BiasModel`. Tracks only *in-progress*
/// partial matches — a phrase's first token is never boosted from root (that
/// would force the phrase to start everywhere and run away). A match begins
/// only once the recognizer *organically* emits a phrase-initial token; from
/// there the continuation is boosted, which is where biasing helps: it
/// disambiguates the tail ("Prio" → "Priya") without inventing the name.
struct BiasState {
    private let model: BiasModel
    private var active: [BiasModel.Node]

    init(model: BiasModel) {
        self.model = model
        self.active = []
    }

    /// Token → additive logit boost for the next emission (the expected next
    /// tokens of every in-progress partial match).
    func boosts() -> [Int: Float] {
        var result: [Int: Float] = [:]
        for node in active {
            for id in node.children.keys {
                result[id] = model.weight
            }
        }
        return result
    }

    mutating func advance(_ token: Int) {
        var next: [BiasModel.Node] = []
        // Continue any in-progress match.
        for node in active {
            if let child = node.children[token] {
                next.append(child)
            }
        }
        // Start a new match only when the recognizer itself emits a
        // phrase-initial token — never boosted into existence.
        if let child = model.root.children[token] {
            next.append(child)
        }
        active = next
    }
}
