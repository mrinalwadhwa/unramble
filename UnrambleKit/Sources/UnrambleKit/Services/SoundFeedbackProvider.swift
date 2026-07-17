import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Play short sound cues at recording start and stop transitions.
///
/// Uses a single dedicated `AVAudioEngine` for playback, pre-warmed at
/// init time so the first sound has zero cold-start latency. Previous
/// attempts to share the capture engine for playback crashed because
/// capture-only engines do not have an active output path
/// (`'player started when in a disconnected state'`).
///
/// The dedicated engine approach works during active mic capture because
/// `AVAudioEngine` with a pre-attached `AVAudioPlayerNode` is a low-level
/// Core Audio path that macOS does not deprioritize the way it does
/// `NSSound`, `AudioToolbox`, and `AVAudioPlayer` (all tested and failed
/// in earlier sessions). Sound buffers are pre-loaded from macOS system
/// sounds at init time so playback has zero disk I/O latency.
///
/// Thread-safe: all engine mutations are serialized under an internal lock.
public final class SoundFeedbackProvider: @unchecked Sendable {

    private let lock = NSLock()

    /// Whether sound feedback is enabled. Syncs with Settings on init
    /// and can be toggled at runtime.
    private var _enabled: Bool = true

    /// Observer for settings changes.
    private var settingsObserver: NSObjectProtocol?

    #if canImport(AVFoundation)
        // Pre-loaded sound buffers.
        private var startBuffer: AVAudioPCMBuffer?
        private var stopBuffer: AVAudioPCMBuffer?

        // Dedicated playback engine, pre-warmed at init.
        private var engine: AVAudioEngine?
        private var playerNode: AVAudioPlayerNode?
    #endif

    public var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    // MARK: - System sound paths

    /// Candidate paths for the start-recording sound, in preference order.
    /// The first path that exists on disk is used. The last entry should
    /// always be a stable `/System/Library/Sounds/` file as a fallback.
    public static let startSoundCandidates: [String] = [
        // Preferred: AirPods head-gesture partial nod (macOS 14+).
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/head_gestures_partial_nod.caf",
        // Fallback: Tink — very short, crisp. Stable since macOS 10.0.
        "/System/Library/Sounds/Tink.aiff",
    ]

    /// Candidate paths for the stop-recording sound, in preference order.
    public static let stopSoundCandidates: [String] = [
        // Preferred: AirPods head-gesture partial shake (macOS 14+).
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/head_gestures_partial_shake.caf",
        // Fallback: Morse — short, distinct. Stable since macOS 10.0.
        "/System/Library/Sounds/Morse.aiff",
    ]

    /// Return the first path in `candidates` that exists on disk, or nil.
    public static func resolveSoundPath(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// List all sound files in `/System/Library/Sounds/` for previewing
    /// alternative sound choices.
    public static func availableSystemSounds() -> [String] {
        let dir = "/System/Library/Sounds"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return contents.sorted().map { "\(dir)/\($0)" }
    }

    // MARK: - Init

    public init() {
        // Sync with persisted setting.
        _enabled = Settings.shared.soundFeedbackEnabled

        // Observe settings changes to keep in sync.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: Settings.shared,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.userInfo?["key"] as? String,
                key == "soundFeedbackEnabled"
            else { return }
            self?.syncWithSettings()
        }

        #if canImport(AVFoundation)
            // Resolve the first available sound file from the candidate
            // lists, then pre-load into PCM buffers. If no candidate
            // exists, the buffer stays nil and playback is silently skipped.
            if let path = Self.resolveSoundPath(Self.startSoundCandidates) {
                startBuffer = Self.loadSoundBuffer(from: path)
            }
            if let path = Self.resolveSoundPath(Self.stopSoundCandidates) {
                stopBuffer = Self.loadSoundBuffer(from: path)
            }

            // Pre-warm the playback engine so the first sound has no
            // cold-start latency. The engine stays running and idle,
            // consuming negligible resources (no input tap, no scheduled
            // buffers). After setup, reset the player node so there is
            // nothing to replay if macOS reconfigures the audio route
            // when the capture engine starts for the first time.
            lock.withLock {
                let (player, _) = setupEngineLocked()
                player?.stop()
                player?.reset()
            }
        #endif
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #if canImport(AVFoundation)
            lock.withLock {
                tearDownEngineLocked()
            }
        #endif
    }

    /// Sync the enabled state with the current Settings value.
    private func syncWithSettings() {
        let newValue = Settings.shared.soundFeedbackEnabled
        lock.withLock { _enabled = newValue }
    }

    // MARK: - Playback

    /// Play the start-recording sound cue.
    public func playStartSound() {
        #if canImport(AVFoundation)
            guard lock.withLock({ _enabled }) else { return }
            guard let buffer = startBuffer else { return }
            play(buffer)
        #endif
    }

    /// Play the stop-recording sound cue.
    public func playStopSound() {
        #if canImport(AVFoundation)
            guard lock.withLock({ _enabled }) else { return }
            guard let buffer = stopBuffer else { return }
            play(buffer)
        #endif
    }

    /// Tear down the playback engine. Call on app termination.
    public func shutdown() {
        #if canImport(AVFoundation)
            lock.withLock {
                tearDownEngineLocked()
            }
        #endif
    }

    /// Play an arbitrary sound file for previewing alternative cues.
    /// Use `availableSystemSounds()` to list candidates.
    public func playPreview(path: String) {
        #if canImport(AVFoundation)
            guard let buffer = Self.loadSoundBuffer(from: path) else { return }
            play(buffer)
        #endif
    }

    // MARK: - Internal playback

    #if canImport(AVFoundation)
        private func play(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                let (player, eng) = ensureEngineLocked()
                guard let player, let eng else { return }
                scheduleAndPlayLocked(
                    player: player, buffer: buffer, engine: eng)
            }
        }

        private func scheduleAndPlayLocked(
            player: AVAudioPlayerNode,
            buffer: AVAudioPCMBuffer,
            engine: AVAudioEngine
        ) {
            // Convert the buffer to the engine's output format if needed.
            let targetFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            let playBuffer: AVAudioPCMBuffer
            if buffer.format.sampleRate == targetFormat.sampleRate
                && buffer.format.channelCount == targetFormat.channelCount
                && buffer.format.commonFormat == targetFormat.commonFormat
            {
                playBuffer = buffer
            } else if let converted = Self.convert(buffer, to: targetFormat) {
                playBuffer = converted
            } else {
                return
            }

            player.stop()
            player.scheduleBuffer(
                playBuffer, at: nil, options: [],
                completionHandler: nil)
            player.play()
        }

        // MARK: - Engine management

        /// Create and start the playback engine. Must be called with
        /// `lock` held. Returns (nil, nil) on failure.
        private func ensureEngineLocked()
            -> (AVAudioPlayerNode?, AVAudioEngine?)
        {
            if let engine, let playerNode {
                if !engine.isRunning {
                    engine.prepare()
                    do {
                        try engine.start()
                    } catch {
                        Log.debug(
                            "[SoundFeedback] Engine restart failed: \(error)"
                        )
                        tearDownEngineLocked()
                        return (nil, nil)
                    }
                }
                return (playerNode, engine)
            }

            // Engine does not exist yet — create it.
            return setupEngineLocked()
        }

        /// Build and start a fresh playback engine. Must be called with
        /// `lock` held.
        @discardableResult
        private func setupEngineLocked()
            -> (AVAudioPlayerNode?, AVAudioEngine?)
        {
            let eng = AVAudioEngine()
            let player = AVAudioPlayerNode()

            eng.attach(player)

            let mainMixer = eng.mainMixerNode
            let format = mainMixer.outputFormat(forBus: 0)
            eng.connect(player, to: mainMixer, format: format)

            eng.prepare()
            do {
                try eng.start()
            } catch {
                Log.debug(
                    "[SoundFeedback] Engine start failed: \(error)")
                eng.detach(player)
                return (nil, nil)
            }

            engine = eng
            playerNode = player

            return (player, eng)
        }

        private func tearDownEngineLocked() {
            if let playerNode {
                playerNode.stop()
                engine?.detach(playerNode)
            }
            engine?.stop()
            engine = nil
            playerNode = nil
        }
    #endif

    // MARK: - Sound loading

    #if canImport(AVFoundation)
        /// Load an AIFF (or other audio) file into a PCM buffer.
        /// Returns nil if the file cannot be read.
        private static func loadSoundBuffer(
            from path: String
        ) -> AVAudioPCMBuffer? {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Log.debug(
                    "[SoundFeedback] Sound file not found: \(path)")
                return nil
            }

            guard let file = try? AVAudioFile(forReading: url) else {
                Log.debug(
                    "[SoundFeedback] Cannot open sound file: \(path)")
                return nil
            }

            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0 else { return nil }

            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: frameCount)
            else {
                Log.debug(
                    "[SoundFeedback] Cannot allocate buffer for: \(path)"
                )
                return nil
            }

            do {
                try file.read(into: buffer)
            } catch {
                Log.debug(
                    "[SoundFeedback] Cannot read sound file: \(error)")
                return nil
            }

            return buffer
        }

        /// Convert a PCM buffer to a different format.
        /// Returns nil on failure.
        private static func convert(
            _ buffer: AVAudioPCMBuffer,
            to targetFormat: AVAudioFormat
        ) -> AVAudioPCMBuffer? {
            guard
                let converter = AVAudioConverter(
                    from: buffer.format,
                    to: targetFormat
                )
            else {
                return nil
            }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * ratio
            )
            guard outputFrameCount > 0 else { return nil }

            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrameCount
                )
            else {
                return nil
            }

            var error: NSError?
            var consumed = false
            converter.convert(
                to: outputBuffer, error: &error
            ) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                Log.debug(
                    "[SoundFeedback] Conversion error: \(error)")
                return nil
            }

            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        }
    #endif
}
