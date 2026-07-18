import Foundation
import XCTest

@testable import UnrambleKit

final class MainThreadDelayTests: XCTestCase {

    func testRunLoopCallbackFiresDuringDelay() {
        // Schedule a timer on the main run loop that sets a flag.
        var timerFired = false
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            timerFired = true
        }
        RunLoop.main.add(timer, forMode: .default)

        // Call the delay helper (50ms). If this pumps the run loop,
        // the 10ms timer fires during the wait. If it hard-blocks
        // (Thread.sleep), the timer cannot fire.
        AppTextInjector.mainThreadDelay(seconds: 0.05)

        XCTAssertTrue(
            timerFired,
            "Run loop timer must fire during mainThreadDelay — "
                + "Thread.sleep blocks the run loop and prevents this")
    }

    func testDelayWaitsAtLeastRequestedDuration() {
        let start = CFAbsoluteTimeGetCurrent()
        AppTextInjector.mainThreadDelay(seconds: 0.05)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertGreaterThanOrEqual(
            elapsed, 0.04,
            "Delay must wait approximately the requested duration")
    }
}
