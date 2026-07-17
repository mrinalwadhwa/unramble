import Foundation

/// Closed outcomes retained by microphone diagnostics.
public enum MicDiagnosticResult: String, Sendable, Equatable {
    case silent
    case empty
    case successLocal = "ok_local"
    case successRealtime = "ok_realtime"
    case successHTTPFallback = "ok_http_fallback"
}

/// A single dictation session's content-free microphone diagnostic data.
public struct MicDiagnosticEntry: Sendable, Equatable {
    public let proximity: MicProximity
    public let ambientRMS: Float
    public let peakRMS: Float
    public let gain: Float
    public let threshold: Float
    public let duration: TimeInterval
    public let latency: TimeInterval  // total pipeline latency
    public let result: MicDiagnosticResult

    public init(
        proximity: MicProximity,
        ambientRMS: Float,
        peakRMS: Float,
        gain: Float,
        threshold: Float,
        duration: TimeInterval,
        latency: TimeInterval,
        result: MicDiagnosticResult
    ) {
        self.proximity = proximity
        self.ambientRMS = ambientRMS
        self.peakRMS = peakRMS
        self.gain = gain
        self.threshold = threshold
        self.duration = duration
        self.latency = latency
        self.result = result
    }
}

/// Stores the last N dictation session diagnostics in memory.
/// Thread-safe via actor isolation.
public actor MicDiagnosticStore {

    /// Hard ceiling even when a test or future caller requests a larger ring.
    public static let maximumCapacity = 10

    private var entries: [MicDiagnosticEntry] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 10) {
        self.maxEntries = min(max(0, maxEntries), Self.maximumCapacity)
    }

    /// Record a new session's diagnostics.
    public func record(_ entry: MicDiagnosticEntry) {
        guard maxEntries > 0 else { return }
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Format all stored entries as a copyable diagnostic string.
    public func formattedDiagnostics() -> String {
        guard !entries.isEmpty else {
            return "No dictation sessions recorded yet."
        }

        let macModel = Self.macModelIdentifier()
        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        var lines: [String] = []
        lines.append(
            "Unramble Mic Diagnostics (\(entries.count) session\(entries.count == 1 ? "" : "s"))")
        lines.append("Unramble: \(appVersion)")
        lines.append("macOS: \(macOSVersion)")
        lines.append("Mac: \(macModel)")
        lines.append("")

        for (i, entry) in entries.enumerated() {
            let n = i + 1
            lines.append(
                "Session \(n): "
                    + "proximity=\(entry.proximity.rawValue) "
                    + "ambient=\(String(format: "%.6f", entry.ambientRMS)) "
                    + "peak=\(String(format: "%.6f", entry.peakRMS)) "
                    + "gain=\(String(format: "%.1f", entry.gain))x "
                    + "threshold=\(String(format: "%.6f", entry.threshold)) "
                    + "duration=\(String(format: "%.2f", entry.duration))s "
                    + "latency=\(String(format: "%.2f", entry.latency))s "
                    + "result=\(entry.result.rawValue)"
            )
        }

        return lines.joined(separator: "\n")
    }

    /// Clear all stored entries.
    public func clear() {
        entries.removeAll()
    }

    /// The number of stored entries.
    public var count: Int {
        entries.count
    }

    // MARK: - Private

    private static func macModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "Unknown"
        }
        return String(cString: model)
    }
}
