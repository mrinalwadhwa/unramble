import Foundation
import Testing

@testable import UnrambleKit

@Suite("Injection error isTerminal")
struct InjectionErrorTerminalTests {

    @Test("pasteNotConsumed is terminal")
    func pasteNotConsumedIsTerminal() {
        let error = AppTextInjector.InjectionError.pasteNotConsumed
        #expect(error.isTerminal)
    }

    @Test("noFocusedElement is not terminal")
    func noFocusedElementNotTerminal() {
        let error = AppTextInjector.InjectionError.noFocusedElement
        #expect(!error.isTerminal)
    }

    @Test("allStrategiesFailed is not terminal")
    func allStrategiesFailedNotTerminal() {
        let error = AppTextInjector.InjectionError.allStrategiesFailed(bundleID: "com.test")
        #expect(!error.isTerminal)
    }

    @Test("accessibilityNotGranted is not terminal")
    func accessibilityNotGrantedNotTerminal() {
        let error = AppTextInjector.InjectionError.accessibilityNotGranted
        #expect(!error.isTerminal)
    }
}
