import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeTextSelectionTests {
    @Test
    func defaultHostsOfferTextSelection() {
        #expect(PeekabooBridgeOperation.remoteDefaultAllowlist.contains(.selectText))
        #expect(PeekabooBridgeOperation.embeddedDefaultAllowlist.contains(.selectText))
        #expect(PeekabooBridgeOperation.selectText.requiredPermissions == [.accessibility])
    }

    @Test
    func hidesNewOperationFromOlderClients() {
        #expect(PeekabooBridgeOperation.compatible(
            [.selectText, .setValue], with: .init(major: 1, minor: 38)) == [.setValue])
        #expect(PeekabooBridgeOperation.compatible(
            [.selectText], with: PeekabooBridgeConstants.textSelectionVersion) == [.selectText])
    }

    @Test
    func bindsSelectedTextAndCursorResultsToTheRequest() throws {
        for type in [TextSelectionRequest.SelectionType.text, .cursorBefore, .cursorAfter] {
            let selection = TextSelectionRequest(text: "target", selectionType: type)
            let request = PeekabooBridgeRequest.selectText(.init(
                target: "T1", selection: selection, snapshotId: "snapshot"))
            let encoded = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(PeekabooBridgeRequest.self, from: encoded)
            #expect(decoded.operation == .selectText)
            let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: decoded)
            let valid = PeekabooBridgeResponse.elementActionResult(.init(
                target: "T1",
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                newValue: selection.selectedText))
            try plan.validateBoundTypedResponse(valid, outcome: nil)
            for invalid in [
                PeekabooBridgeResponse.elementActionResult(.init(
                    target: "other",
                    actionName: "AXSelectedTextRange",
                    anchorPoint: nil,
                    newValue: selection.selectedText)),
                .elementActionResult(.init(
                    target: "T1",
                    actionName: "AXSetValue",
                    anchorPoint: nil,
                    newValue: selection.selectedText)),
                .elementActionResult(.init(
                    target: "T1",
                    actionName: "AXSelectedTextRange",
                    anchorPoint: nil,
                    newValue: "wrong")),
                .ok,
            ] {
                #expect(throws: (any Error).self) {
                    try plan.validateBoundTypedResponse(invalid, outcome: nil)
                }
            }
        }
    }
}
