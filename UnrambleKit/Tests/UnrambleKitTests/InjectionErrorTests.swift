import Foundation
import Testing

@testable import UnrambleKit

@Suite("Injection error descriptions")
struct InjectionErrorTests {

    @Test("noFocusedElement error has a description")
    func noFocusedElementDescription() {
        let error = AppTextInjector.InjectionError.noFocusedElement
        #expect(error.description.contains("focused"))
    }

    @Test("allStrategiesFailed error includes the app bundle ID")
    func allStrategiesFailedDescription() {
        let error = AppTextInjector.InjectionError.allStrategiesFailed(
            bundleID: "com.example.TestApp"
        )
        #expect(error.description.contains("com.example.TestApp"))
    }

    @Test("accessibilityNotGranted error has a description")
    func accessibilityNotGrantedDescription() {
        let error = AppTextInjector.InjectionError.accessibilityNotGranted
        #expect(error.description.contains("ccessibility"))
    }

    @Test("pasteNotConsumed error has a description")
    func pasteNotConsumedDescription() {
        let error = AppTextInjector.InjectionError.pasteNotConsumed
        #expect(error.description.contains("not consumed"))
    }

    @Test("All error cases are distinct")
    func errorCasesDistinct() {
        let a = AppTextInjector.InjectionError.noFocusedElement
        let b = AppTextInjector.InjectionError.accessibilityNotGranted
        let c = AppTextInjector.InjectionError.allStrategiesFailed(bundleID: "com.test")
        let d = AppTextInjector.InjectionError.pasteNotConsumed

        #expect(a.description != b.description)
        #expect(a.description != c.description)
        #expect(a.description != d.description)
        #expect(b.description != c.description)
        #expect(b.description != d.description)
        #expect(c.description != d.description)
    }
}

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
