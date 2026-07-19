import Foundation
import Testing

@testable import UnrambleKit

@Suite("Injection planner")
struct InjectionPlannerTests {

    private let planner = InjectionPlanner()

    // MARK: - Insert at cursor

    @Test("Insert at a cursor in the middle")
    func insertAtCursorMiddle() {
        let result = planner.plan(
            insert: " there",
            into: "Hello world",
            selectedRange: nil,
            cursorPosition: 5
        )
        #expect(result.newValue == "Hello there world")
        #expect(result.newCursorPosition == 11)
    }

    @Test("Insert at the start")
    func insertAtStart() {
        let result = planner.plan(
            insert: "Hi ",
            into: "world",
            selectedRange: nil,
            cursorPosition: 0
        )
        #expect(result.newValue == "Hi world")
        #expect(result.newCursorPosition == 3)
    }

    @Test("Insert at the end")
    func insertAtEnd() {
        let result = planner.plan(
            insert: "d",
            into: "abc",
            selectedRange: nil,
            cursorPosition: 3
        )
        #expect(result.newValue == "abcd")
        #expect(result.newCursorPosition == 4)
    }

    // MARK: - Append fallback

    @Test("Append when neither cursor nor selection is known")
    func appendWhenNoCursorOrSelection() {
        let result = planner.plan(
            insert: "d",
            into: "abc",
            selectedRange: nil,
            cursorPosition: nil
        )
        #expect(result.newValue == "abcd")
        #expect(result.newCursorPosition == 4)
    }

    // MARK: - Replace selection

    @Test("Replace a selection")
    func replaceSelection() {
        let result = planner.plan(
            insert: "there",
            into: "Hello world",
            selectedRange: (location: 6, length: 5),
            cursorPosition: nil
        )
        #expect(result.newValue == "Hello there")
        #expect(result.newCursorPosition == 11)
    }

    @Test("A zero-length selection falls through to the cursor")
    func zeroLengthSelectionFallsToCursor() {
        let result = planner.plan(
            insert: "X",
            into: "abcdef",
            selectedRange: (location: 3, length: 0),
            cursorPosition: 3
        )
        #expect(result.newValue == "abcXdef")
        #expect(result.newCursorPosition == 4)
    }

    // MARK: - UTF-16 boundaries (emoji)

    @Test("Insert on an emoji boundary")
    func emojiBoundaryInsert() {
        let result = planner.plan(
            insert: "X",
            into: "a😀b",
            selectedRange: nil,
            cursorPosition: 3
        )
        #expect(result.newValue == "a😀Xb")
        #expect(result.newCursorPosition == 4)
    }

    @Test("A mid-surrogate offset rounds the splice down")
    func midSurrogateRoundsDown() {
        let result = planner.plan(
            insert: "X",
            into: "a😀b",
            selectedRange: nil,
            cursorPosition: 2
        )
        // The splice rounds the mid-emoji offset down to before the emoji,
        // while the reported cursor still advances from the raw UTF-16 offset.
        #expect(result.newValue == "aX😀b")
        #expect(result.newCursorPosition == 3)
    }

    // MARK: - Out-of-bounds clamping

    @Test("A cursor past the end clamps the splice but not the cursor")
    func cursorBeyondEndClampsValueNotCursor() {
        let result = planner.plan(
            insert: "Z",
            into: "abc",
            selectedRange: nil,
            cursorPosition: 100
        )
        #expect(result.newValue == "abcZ")
        #expect(result.newCursorPosition == 101)
    }

    @Test("A selection past the end clamps the replaced range")
    func selectionBeyondEndClamps() {
        let result = planner.plan(
            insert: "Y",
            into: "abc",
            selectedRange: (location: 1, length: 100),
            cursorPosition: nil
        )
        #expect(result.newValue == "aY")
        #expect(result.newCursorPosition == 2)
    }
}
