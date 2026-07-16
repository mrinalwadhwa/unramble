import Foundation

/// Tracks the installed dictation backend separately from one requested
/// replacement. Request identity prevents a stale task from publishing or
/// clearing a newer transition.
public struct DictationModeTransition: Sendable, Equatable {
    public struct Request: Sendable, Equatable {
        fileprivate let id: UUID
        public let mode: DictationMode

        public init(mode: DictationMode) {
            self.id = UUID()
            self.mode = mode
        }
    }

    public enum RequestResult: Sendable, Equatable {
        case accepted(Request)
        case unchanged
        case busy
        case unavailable
    }

    public private(set) var effectiveMode: DictationMode
    public private(set) var requestedRequest: Request?

    public var requestedMode: DictationMode? {
        requestedRequest?.mode
    }

    public init(effectiveMode: DictationMode) {
        self.effectiveMode = effectiveMode
    }

    public mutating func request(
        _ mode: DictationMode,
        isAvailable: Bool = true
    ) -> RequestResult {
        guard requestedRequest == nil else { return .busy }
        guard mode != effectiveMode else { return .unchanged }
        guard isAvailable else { return .unavailable }

        let request = Request(mode: mode)
        requestedRequest = request
        return .accepted(request)
    }

    @discardableResult
    public mutating func publish(_ request: Request) -> Bool {
        guard requestedRequest == request else { return false }
        effectiveMode = request.mode
        requestedRequest = nil
        return true
    }

    @discardableResult
    public mutating func fail(_ request: Request) -> Bool {
        guard requestedRequest == request else { return false }
        requestedRequest = nil
        return true
    }

    public mutating func cancelPendingRequest() {
        requestedRequest = nil
    }
}
