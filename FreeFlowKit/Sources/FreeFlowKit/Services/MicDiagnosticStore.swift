import Foundation

/// A single dictation session's microphone diagnostic data.
public struct MicDiagnosticEntry: Sendable {
    public let timestamp: Date
    public let deviceName: String
    public let proximity: String  // "far_field" or "near_field"
    public let ambientRMS: Float
    public let peakRMS: Float
    public let gain: Float
    public let threshold: Float
    public let duration: TimeInterval
    public let latency: TimeInterval  // total pipeline latency
    public let result: String  // e.g. "ok_realtime", "ok_http_fallback", "silent"

    public init(
        timestamp: Date = Date(),
        deviceName: String,
        proximity: String,
        ambientRMS: Float,
        peakRMS: Float,
        gain: Float,
        threshold: Float,
        duration: TimeInterval,
        latency: TimeInterval,
        result: String
    ) {
        self.timestamp = timestamp
        self.deviceName = deviceName
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

    private var entries: [MicDiagnosticEntry] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 10) {
        self.maxEntries = maxEntries
    }

    /// Record a new session's diagnostics.
    public func record(_ entry: MicDiagnosticEntry) {
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
            "FreeFlow Mic Diagnostics (\(entries.count) session\(entries.count == 1 ? "" : "s"))")
        lines.append("FreeFlow: \(appVersion)")
        lines.append("macOS: \(macOSVersion)")
        lines.append("Mac: \(macModel)")
        lines.append("")

        for (i, entry) in entries.enumerated() {
            let n = i + 1
            lines.append(
                "Session \(n): "
                    + "device=\"\(entry.deviceName)\" "
                    + "proximity=\(entry.proximity) "
                    + "ambient=\(String(format: "%.6f", entry.ambientRMS)) "
                    + "peak=\(String(format: "%.6f", entry.peakRMS)) "
                    + "gain=\(String(format: "%.1f", entry.gain))x "
                    + "threshold=\(String(format: "%.6f", entry.threshold)) "
                    + "duration=\(String(format: "%.2f", entry.duration))s "
                    + "latency=\(String(format: "%.2f", entry.latency))s "
                    + "result=\(entry.result)"
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
