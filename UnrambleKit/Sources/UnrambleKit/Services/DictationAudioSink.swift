import Foundation

#if canImport(AVFoundation)
    import AVFoundation

    protocol DictationPCMConverting: AnyObject {
        func begin() throws
        func consume(_ input: AVAudioPCMBuffer) throws -> Data
        func finish() throws -> Data
        func discard()
    }

    extension PCMConverterLifecycle: DictationPCMConverting {}

    /// Owns every unbounded resource for one dictation. The physical input tap
    /// and preview meter remain independent, so finishing this sink can demote
    /// capture back to preview without restarting the audio engine.
    final class DictationAudioSink: @unchecked Sendable {
        typealias ConverterFactory = (
            _ inputFormat: AVAudioFormat,
            _ outputFormat: AVAudioFormat
        ) -> any DictationPCMConverting

        struct Completion: Sendable {
            let buffer: AudioBuffer
            let integrityFailure: AudioCaptureIntegrityFailure?
        }

        private let lock = NSLock()
        private let converter: any DictationPCMConverting
        private let integrity: AudioCaptureIntegrityPublication
        private let micProximity: MicProximity
        private let deviceName: String
        private let ambientCalibrationFrameCount: Int

        private let pcmStreamValue: AsyncStream<Data>
        private let pcmContinuation: AsyncStream<Data>.Continuation
        private let levelStreamValue: AsyncStream<Float>
        private let levelContinuation: AsyncStream<Float>.Continuation

        private var pcmChunks: [Data] = []
        private var peakRMS: Float = 0
        private var ambientRMS: Float = 0
        private var ambientFrameCount = 0
        private var ambientSampleCount = 0
        private var ambientSumOfSquares: Double = 0
        private var ambientCalibrated = false
        private var gainFactor: Float = 1
        private var droppedFrameCount = 0
        private var isOpen = true

        init(
            inputFormat: AVAudioFormat,
            micProximity: MicProximity,
            deviceName: String,
            makeConverter: ConverterFactory = { inputFormat, outputFormat in
                PCMConverterLifecycle(
                    inputFormat: inputFormat,
                    outputFormat: outputFormat)
            },
            integrity: AudioCaptureIntegrityPublication =
                AudioCaptureIntegrityPublication()
        ) throws {
            guard
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: AudioCaptureProvider.targetSampleRate,
                    channels: AudioCaptureProvider.targetChannels,
                    interleaved: true)
            else {
                throw AudioCaptureError.formatError
            }

            self.micProximity = micProximity
            self.deviceName = deviceName
            self.integrity = integrity
            self.ambientCalibrationFrameCount = max(
                Int(inputFormat.sampleRate * 0.5),
                1)
            self.converter = makeConverter(inputFormat, targetFormat)

            let pcmPair = AsyncStream<Data>.makeStream()
            self.pcmStreamValue = pcmPair.stream
            self.pcmContinuation = pcmPair.continuation

            let levelPair = AsyncStream<Float>.makeStream(
                bufferingPolicy: .bufferingNewest(1))
            self.levelStreamValue = levelPair.stream
            self.levelContinuation = levelPair.continuation

            do {
                try converter.begin()
            } catch {
                throw AudioCaptureError.formatError
            }
        }

        var pcmStream: AsyncStream<Data> { pcmStreamValue }
        var levelStream: AsyncStream<Float> { levelStreamValue }
        var integrityPublication: AudioCaptureIntegrityPublication { integrity }

        var metrics: AudioCaptureMetrics {
            lock.withLock {
                AudioCaptureMetrics(
                    peakRMS: peakRMS,
                    ambientRMS: ambientRMS,
                    micProximity: micProximity,
                    gainFactor: gainFactor,
                    deviceName: deviceName)
            }
        }

        func consume(_ buffer: AVAudioPCMBuffer) {
            let measurement = Self.measureLevel(in: buffer)

            let gain: Float? = lock.withLock {
                guard isOpen else { return nil }
                if let measurement {
                    let rms = measurement.rms
                    peakRMS = max(peakRMS, rms)
                    if !ambientCalibrated {
                        ambientSumOfSquares += measurement.sumOfSquares
                        ambientFrameCount += measurement.frameCount
                        ambientSampleCount += measurement.sampleCount
                        if ambientFrameCount >= ambientCalibrationFrameCount {
                            ambientRMS = Float(
                                sqrt(
                                    ambientSumOfSquares
                                        / Double(ambientSampleCount)))
                            ambientCalibrated = true
                            gainFactor = AudioCaptureProvider.computeGainFactor(
                                ambientRMS: ambientRMS,
                                micProximity: micProximity)
                        }
                    }
                    let displayRMS = rms * gainFactor
                    levelContinuation.yield(min(sqrtf(displayRMS * 25), 1))
                }
                return gainFactor
            }
            guard let gain else { return }

            let rawData: Data
            do {
                rawData = try converter.consume(buffer)
            } catch {
                integrity.record(
                    AudioCaptureIntegrityFailure(
                        stage: .pcmConversion,
                        affectedFrameCount: Int(buffer.frameLength)))
                let dropped = lock.withLock { () -> Int? in
                    guard isOpen else { return nil }
                    droppedFrameCount += 1
                    return droppedFrameCount
                }
                if let dropped {
                    Log.debug(
                        "[AudioCapture] Audio conversion error (dropped \(dropped)): \(error)")
                }
                return
            }

            publish(AudioCaptureProvider.applySoftwareGain(rawData, gain: gain))
        }

        private struct LevelMeasurement {
            let frameCount: Int
            let sampleCount: Int
            let sumOfSquares: Double

            var rms: Float {
                Float(sqrt(sumOfSquares / Double(sampleCount)))
            }
        }

        private static func measureLevel(
            in buffer: AVAudioPCMBuffer
        ) -> LevelMeasurement? {
            guard let channelData = buffer.floatChannelData else { return nil }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return nil }

            let sampleCount = frameCount * channelCount
            var sumOfSquares = 0.0
            if buffer.format.isInterleaved {
                let samples = channelData[0]
                for index in 0..<sampleCount {
                    let sample = Double(samples[index])
                    sumOfSquares += sample * sample
                }
            } else {
                for channel in 0..<channelCount {
                    let samples = channelData[channel]
                    for frame in 0..<frameCount {
                        let sample = Double(samples[frame])
                        sumOfSquares += sample * sample
                    }
                }
            }

            return LevelMeasurement(
                frameCount: frameCount,
                sampleCount: sampleCount,
                sumOfSquares: sumOfSquares)
        }

        func finishWithIntegrity() -> Completion {
            let tail: Data
            do {
                let rawTail = try converter.finish()
                let gain = lock.withLock { gainFactor }
                tail = AudioCaptureProvider.applySoftwareGain(rawTail, gain: gain)
            } catch {
                integrity.record(
                    AudioCaptureIntegrityFailure(
                        stage: .converterDrain,
                        affectedFrameCount: nil))
                converter.discard()
                tail = Data()
                Log.debug("[AudioCapture] Audio converter tail drain failed: \(error)")
            }

            let pcmData: Data = lock.withLock {
                guard isOpen else { return Data() }
                isOpen = false
                if !tail.isEmpty {
                    pcmChunks.append(tail)
                    pcmContinuation.yield(tail)
                }
                pcmContinuation.finish()
                levelContinuation.finish()

                let totalSize = pcmChunks.reduce(0) { $0 + $1.count }
                var combined = Data(capacity: totalSize)
                for chunk in pcmChunks { combined.append(chunk) }
                pcmChunks.removeAll(keepingCapacity: false)
                return combined
            }

            let buffer: AudioBuffer
            if pcmData.isEmpty {
                buffer = .empty
            } else {
                let duration = WAVEncoder.duration(
                    byteCount: pcmData.count,
                    sampleRate: Int(AudioCaptureProvider.targetSampleRate),
                    channels: Int(AudioCaptureProvider.targetChannels),
                    bitsPerSample: AudioCaptureProvider.targetBitsPerSample)
                buffer = AudioBuffer(
                    data: WAVEncoder.encode(
                        pcmData: pcmData,
                        sampleRate: Int(AudioCaptureProvider.targetSampleRate),
                        channels: Int(AudioCaptureProvider.targetChannels),
                        bitsPerSample: AudioCaptureProvider.targetBitsPerSample),
                    duration: duration,
                    sampleRate: Int(AudioCaptureProvider.targetSampleRate),
                    channels: Int(AudioCaptureProvider.targetChannels),
                    bitsPerSample: AudioCaptureProvider.targetBitsPerSample)
            }
            return Completion(
                buffer: buffer,
                integrityFailure: integrity.failure)
        }

        func discard() {
            converter.discard()
            lock.withLock {
                guard isOpen else { return }
                isOpen = false
                pcmChunks.removeAll(keepingCapacity: false)
                pcmContinuation.finish()
                levelContinuation.finish()
            }
        }

        private func publish(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.withLock {
                guard isOpen else { return }
                pcmChunks.append(data)
                pcmContinuation.yield(data)
            }
        }
    }

    /// Router sink creation cannot take the provider lock because promotion is
    /// serialized with provider state. This separate publication cell lets the
    /// router capture the exact immutable sink without reversing lock order.
    final class DictationAudioSinkPublication: @unchecked Sendable {
        struct Token: Equatable, Sendable {
            fileprivate let id: UUID
        }

        enum PublicationError: Error {
            case noSink
        }

        private let lock = NSLock()
        private var entry: (token: Token, sink: DictationAudioSink)?

        @discardableResult
        func publish(_ sink: DictationAudioSink) -> Token {
            lock.withLock {
                let token = Token(id: UUID())
                entry = (token, sink)
                return token
            }
        }

        func makeRouterSink() throws -> TimestampedAudioFrameRouter.DictationSink {
            let sink = try lock.withLock {
                guard let sink = entry?.sink else {
                    throw PublicationError.noSink
                }
                return sink
            }
            return TimestampedAudioFrameRouter.DictationSink(
                integrity: sink.integrityPublication,
                consume: { frame in sink.consume(frame.buffer) })
        }

        @discardableResult
        func clear(_ token: Token) -> Bool {
            lock.withLock {
                guard entry?.token == token else { return false }
                entry = nil
                return true
            }
        }

        func reset() {
            lock.withLock { entry = nil }
        }
    }
#endif
