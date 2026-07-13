import Foundation
import Testing

@testable import FreeFlowKit

// MARK: - Dictation error tests

@Suite("Dictation error")
struct DictationErrorTests {

    @Test("DictationError cases are equatable")
    func errorEquatable() {
        #expect(DictationError.emptyAudio == DictationError.emptyAudio)
        #expect(
            DictationError.authenticationFailed
                == DictationError.authenticationFailed)
        #expect(
            DictationError.invalidResponse
                == DictationError.invalidResponse)
        #expect(
            DictationError.requestFailed(statusCode: 500, message: "err")
                == DictationError.requestFailed(statusCode: 500, message: "err"))
        #expect(
            DictationError.networkError("timeout")
                == DictationError.networkError("timeout"))
        #expect(DictationError.emptyAudio != DictationError.authenticationFailed)
    }

    @Test("Different status codes are not equal")
    func errorDifferentStatusCodes() {
        #expect(
            DictationError.requestFailed(statusCode: 500, message: "err")
                != DictationError.requestFailed(statusCode: 502, message: "err"))
    }

    @Test("Different messages are not equal")
    func errorDifferentMessages() {
        #expect(
            DictationError.networkError("timeout")
                != DictationError.networkError("refused"))
    }
}
