import Testing

@testable import FreeFlowKit

@Suite("Dictation mode transition")
struct DictationModeTransitionTests {

    @Test("Request remains pending until its exact replacement publishes")
    func publishesExactRequest() throws {
        var transition = DictationModeTransition(effectiveMode: .local)

        let request: DictationModeTransition.Request
        switch transition.request(.cloud) {
        case .accepted(let accepted):
            request = accepted
        default:
            Issue.record("Expected request admission")
            return
        }

        #expect(transition.effectiveMode == .local)
        #expect(transition.requestedMode == .cloud)
        let busyResult = transition.request(.local)
        #expect(busyResult == .busy)

        let stale = DictationModeTransition.Request(mode: .cloud)
        let stalePublished = transition.publish(stale)
        #expect(!stalePublished)
        #expect(transition.effectiveMode == .local)
        #expect(transition.requestedMode == .cloud)

        let published = transition.publish(request)
        #expect(published)
        #expect(transition.effectiveMode == .cloud)
        #expect(transition.requestedMode == nil)
    }

    @Test("Unavailable cloud request leaves local effective and unsealed")
    func unavailableRequest() {
        var transition = DictationModeTransition(effectiveMode: .local)

        let result = transition.request(.cloud, isAvailable: false)
        #expect(result == .unavailable)
        #expect(transition.effectiveMode == .local)
        #expect(transition.requestedMode == nil)
    }

    @Test("Failed replacement preserves effective mode")
    func failedRequest() throws {
        var transition = DictationModeTransition(effectiveMode: .local)
        let request: DictationModeTransition.Request
        switch transition.request(.cloud) {
        case .accepted(let accepted):
            request = accepted
        default:
            Issue.record("Expected request admission")
            return
        }

        let stale = DictationModeTransition.Request(mode: .cloud)
        let staleFailed = transition.fail(stale)
        #expect(!staleFailed)
        #expect(transition.requestedMode == .cloud)

        let failed = transition.fail(request)
        #expect(failed)
        #expect(transition.effectiveMode == .local)
        #expect(transition.requestedMode == nil)
    }

    @Test("Requesting the installed backend is unchanged")
    func unchangedRequest() {
        var transition = DictationModeTransition(effectiveMode: .cloud)

        let result = transition.request(.cloud)
        #expect(result == .unchanged)
        #expect(transition.requestedMode == nil)
    }
}
