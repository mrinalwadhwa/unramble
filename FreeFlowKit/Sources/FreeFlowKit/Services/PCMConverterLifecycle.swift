import Foundation

#if canImport(AVFoundation)
    import AVFoundation

    /// Serializes access to one converter session. Discard waits for an
    /// in-flight conversion rather than racing the converter reference.
    final class SerializedConverterSession<Converter>: @unchecked Sendable {
        private let lock = NSLock()
        private var converter: Converter?

        func begin(_ makeConverter: () throws -> Converter) rethrows -> Bool {
            try lock.withLock {
                guard converter == nil else { return false }
                converter = try makeConverter()
                return true
            }
        }

        func consume<Output>(
            _ operation: (Converter) throws -> Output
        ) rethrows -> Output? {
            try lock.withLock {
                guard let converter else { return nil }
                return try operation(converter)
            }
        }

        func finish<Output>(
            _ operation: (Converter) throws -> Output
        ) rethrows -> Output? {
            try lock.withLock {
                guard let converter else { return nil }
                defer { self.converter = nil }
                return try operation(converter)
            }
        }

        func discard() {
            lock.withLock { converter = nil }
        }
    }

    /// Owns one AVAudioConverter per capture session. Normal completion drains
    /// the converter before releasing it; discard releases it without emitting
    /// buffered audio.
    final class PCMConverterLifecycle {
        enum LifecycleError: Error {
            case cannotCreateConverter
            case sessionAlreadyActive
            case noActiveSession
            case unsupportedOutputFormat
            case conversionFailed(Error?)
            case conversionDidNotFinish
        }

        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat

        private let session = SerializedConverterSession<AVAudioConverter>()

        init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
            self.inputFormat = inputFormat
            self.outputFormat = outputFormat
        }

        func begin() throws {
            let began = try session.begin {
                guard let converter = AVAudioConverter(
                    from: inputFormat,
                    to: outputFormat
                ) else {
                    throw LifecycleError.cannotCreateConverter
                }
                return converter
            }
            guard began else {
                throw LifecycleError.sessionAlreadyActive
            }
        }

        func consume(_ input: AVAudioPCMBuffer) throws -> Data {
            let converted = try session.consume { converter in
                var inputWasProvided = false
                return try convert(converter: converter) { _, status in
                    guard !inputWasProvided else {
                        status.pointee = .noDataNow
                        return nil
                    }
                    inputWasProvided = true
                    status.pointee = .haveData
                    return input
                }
            }
            guard let converted else {
                throw LifecycleError.noActiveSession
            }
            return converted
        }

        func finish() throws -> Data {
            let tail = try session.finish { converter in
                try convert(converter: converter) { _, status in
                    status.pointee = .endOfStream
                    return nil
                }
            }
            guard let tail else {
                throw LifecycleError.noActiveSession
            }
            return tail
        }

        func discard() {
            session.discard()
        }

        private func convert(
            converter: AVAudioConverter,
            input: @escaping AVAudioConverterInputBlock
        ) throws -> Data {
            var converted = Data()

            // A converter can return several output buffers for one input
            // buffer, especially while flushing its priming/trailing frames.
            for _ in 0..<64 {
                guard
                    let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: 4_096
                    )
                else {
                    throw LifecycleError.unsupportedOutputFormat
                }

                var conversionError: NSError?
                let status = converter.convert(
                    to: outputBuffer,
                    error: &conversionError,
                    withInputFrom: input
                )

                if status == .error || conversionError != nil {
                    throw LifecycleError.conversionFailed(conversionError)
                }

                converted.append(try pcmData(from: outputBuffer))

                switch status {
                case .haveData:
                    continue
                case .inputRanDry, .endOfStream:
                    return converted
                case .error:
                    throw LifecycleError.conversionFailed(conversionError)
                @unknown default:
                    throw LifecycleError.conversionDidNotFinish
                }
            }

            throw LifecycleError.conversionDidNotFinish
        }

        private func pcmData(from buffer: AVAudioPCMBuffer) throws -> Data {
            guard buffer.frameLength > 0 else { return Data() }
            guard outputFormat.commonFormat == .pcmFormatInt16,
                outputFormat.channelCount == 1,
                let samples = buffer.int16ChannelData?[0]
            else {
                throw LifecycleError.unsupportedOutputFormat
            }
            return Data(
                bytes: samples,
                count: Int(buffer.frameLength) * MemoryLayout<Int16>.size
            )
        }
    }
#endif
