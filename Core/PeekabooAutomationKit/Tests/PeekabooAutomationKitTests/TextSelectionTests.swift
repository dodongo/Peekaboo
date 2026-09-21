import Foundation
import Testing
@testable import PeekabooAutomationKit

struct TextSelectionTests {
    @Test
    func resolvesUnicodeAndContext() throws {
        let value = "😀 first target / second target!"
        let request = TextSelectionRequest(text: "target", prefix: "second ", suffix: "!")
        let range = try request.range(in: value)
        #expect((value as NSString).substring(with: range) == "target")
        #expect(range.location == (value as NSString).range(of: "target", options: .backwards).location)
        #expect(try TextSelectionRequest(text: "target", prefix: "second ", selectionType: .cursorBefore)
            .range(in: value) == NSRange(location: range.location, length: 0))
        #expect(try TextSelectionRequest(text: "target", prefix: "second ", selectionType: .cursorAfter)
            .range(in: value) == NSRange(location: NSMaxRange(range), length: 0))
    }

    @Test
    func rejectsAmbiguousMissingEmptyAndOverlappingMatches() {
        #expect(throws: (any Error).self) { try TextSelectionRequest(text: "a").range(in: "a a") }
        #expect(throws: (any Error).self) { try TextSelectionRequest(text: "aa").range(in: "aaa") }
        #expect(throws: (any Error).self) { try TextSelectionRequest(text: "missing").range(in: "text") }
        #expect(throws: (any Error).self) { try TextSelectionRequest(text: "").range(in: "text") }
        #expect(throws: (any Error).self) { try TextSelectionRequest(text: "a", prefix: "no").range(in: "a") }
    }

    @MainActor @Test
    func selectsWithoutChangingTextAndSkipsAnAlreadyMatchingRange() throws {
        let element = ActionInputMockAutomationElement(role: "AXTextArea", value: "one two three")
        element.isSelectedTextRangeSettable = true
        let request = TextSelectionRequest(text: "two")
        let result = try TextSelectionInput.select(request, on: element)
        #expect(result.actionName == "AXSelectedTextRange")
        #expect(element.selectedTextRange == NSRange(location: 4, length: 3))
        #expect(element.stringValue == "one two three")
        _ = try TextSelectionInput.select(request, on: element)
        #expect(element.selectionSetCalls == 1)
    }

    @MainActor @Test
    func refusesUnsupportedAndSecureFieldsBeforeDispatch() {
        for element in [
            ActionInputMockAutomationElement(role: "AXButton", value: "text"),
            ActionInputMockAutomationElement(role: "AXTextField", subrole: "AXSecureTextField", value: "text"),
            ActionInputMockAutomationElement(role: "AXTextField", value: "text"),
        ] {
            #expect(throws: (any Error).self) { try TextSelectionInput.select(.init(text: "text"), on: element) }
            #expect(element.selectionSetCalls == 0)
        }
    }

    @MainActor @Test
    func rejectsPhantomSelectionSuccess() {
        let element = ActionInputMockAutomationElement(role: "AXTextField", value: "text")
        element.isSelectedTextRangeSettable = true
        element.selectionSetterDoesNotChange = true
        #expect(throws: (any Error).self) { try TextSelectionInput.select(.init(text: "text"), on: element) }
        #expect(element.selectionSetCalls == 1)
    }
}
