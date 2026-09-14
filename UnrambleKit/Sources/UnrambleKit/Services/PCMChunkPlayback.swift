import AVFoundation
import Foundation

/// Plays a growing sequence of PCM chunks gaplessly.
///
/// Chunks are scheduled as they finish generating; the player consumes
/// them in order, so playback of early chunks overlaps generation of
/// later ones. `drain` suspends until every scheduled chunk has played
/// or the playback was stopped.
final class PCMChunkPlayback: @unchecked Sendable {

    let player: any PCMChunkPlaying

    private let lock = NSLock()
    // Serialize calls into the player. Completion callbacks only take
    // `lock`, so a synchronous completion cannot deadlock this lock.
    private let playerLock = NSLock()
    private var pendingBuffers = 0
    private var finishedScheduling = false
    private var stopped = false
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    /// Route through the far-end channel when one is active — the
    /// voice-processed capture is running, and audio played there is
    /// cancelled from the microphone as the unit's own reference —
    /// otherwise play through a dedicated engine.
    init(sampleRate: Double, farEndHub: FarEndPlaybackHub? = nil) {
        if let channel = farEndHub?.activeChannel, channel.isActive {
            Log.debug("[FarEnd] playback routed through the reference bus")
            player = FarEndPCMChunkPlayer(
                inputSampleRate: sampleRate,
                channel: channel)
        } else {
            if farEndHub != nil {
                Log.debug("[FarEnd] playback routed through the engine")
            }
            player = AVAudioPCMChunkPlayer(sampleRate: sampleRate)
        }
    }

    init(player: any PCMChunkPlaying) {
        self.player = player
    }

    /// Silence follows the same scheduling, drain, and stop path as speech.
    func scheduleSilence(
        duration: TimeInterval,
        diagnosticLabel: String? = nil
    ) throws {
        guard duration > 0 else { return }
        guard let format = player.format else {
            throw PCMChunkPlaybackError.bufferAllocationFailed
        }
        let frameCount = Int((duration * format.sampleRate).rounded())
        guard frameCount > 0 else { return }
        try schedule(
            samples: [Float](repeating: 0, count: frameCount),
            diagnosticLabel: diagnosticLabel)
    }

    func schedule(samples: [Float], diagnosticLabel: String? = nil) throws {
        guard let format = player.format,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw PCMChunkPlaybackError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0]
                .update(from: source.baseAddress!, count: samples.count)
        }

        try playerLock.withLock {
            let shouldStart: Bool? = lock.withLock {
                guard !stopped else { return nil }
                pendingBuffers += 1
                if !started {
                    started = true
                    return true
                }
                return false
            }
            guard let shouldStart else { return }
            if let diagnosticLabel {
                Log.debug(
                    "[PCMPause] \(diagnosticLabel) queued frames=\(samples.count) "
                        + "sampleRate=\(format.sampleRate) "
                        + "durationMs=\(Double(samples.count) / format.sampleRate * 1000)")
            }

            // Queue the first buffer before playback starts. Starting an empty
            // player lets the audio graph run ahead of the buffer and can clip
            // the opening word from a newly synthesized utterance.
            player.schedule(buffer: buffer) { [weak self] in
                self?.bufferFinished()
                if let self, let diagnosticLabel {
                    let stopped = self.lock.withLock { self.stopped }
                    Log.debug(
                        "[PCMPause] \(diagnosticLabel) completion stopped=\(stopped) "
                            + "uptime=\(ProcessInfo.processInfo.systemUptime)")
                }
            }
            if shouldStart {
                do {
                    try player.start()
                } catch {
                    lock.withLock { pendingBuffers -= 1 }
                    throw error
                }
            }
        }
    }

    /// Suspend until everything scheduled has played, or `stop` ran.
    func drain() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                finishedScheduling = true
                if stopped || pendingBuffers == 0 {
                    return true
                }
                drainContinuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    /// Silence playback immediately and release any drain waiter. The
    /// player's completion handlers may also fire on stop; both paths
    /// resume the waiter at most once.
    func stop() {
        let continuation = playerLock.withLock {
            let (wasStarted, waiter):
                (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                    stopped = true
                    pendingBuffers = 0
                    let waiter = drainContinuation
                    drainContinuation = nil
                    return (started, waiter)
                }
            if wasStarted {
                player.stop()
            }
            return waiter
        }
        continuation?.resume()
    }

    private func bufferFinished() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            pendingBuffers = max(0, pendingBuffers - 1)
            guard pendingBuffers == 0, finishedScheduling else { return nil }
            let waiter = drainContinuation
            drainContinuation = nil
            return waiter
        }
        continuation?.resume()
    }
}

enum PCMChunkPlaybackError: Error {
    case bufferAllocationFailed
}

protocol PCMChunkPlaying: AnyObject {
    var format: AVAudioFormat? { get }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void)
    func start() throws
    func stop()
}

private final class AVAudioPCMChunkPlayer: PCMChunkPlaying,
    @unchecked Sendable
{
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let format: AVAudioFormat?

    init(sampleRate: Double) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false)
        if let format {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) {
        player.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack
        ) { _ in
            completion()
        }
    }

    func start() throws {
        try engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
