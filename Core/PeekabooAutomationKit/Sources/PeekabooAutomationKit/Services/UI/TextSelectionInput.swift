import ApplicationServices
import Foundation
import PeekabooFoundation

@MainActor
enum TextSelectionInput {
    static func select(_ request: TextSelectionRequest, on element: any AutomationElementRepresenting)
        throws -> UIInputExecutionResult.Action
    {
        guard element.subrole != "AXSecureTextField",
              element.role == "AXTextField" || element.role == "AXTextArea",
              let value = element.stringValue
        else {
            throw PeekabooError.invalidInput("Text selection requires a readable, non-secure text field or text area")
        }
        let range = try request.range(in: value)
        guard element.isSelectedTextRangeSettable else {
            throw PeekabooError.invalidInput("This element does not expose a settable text selection range")
        }
        if element.selectedTextRange == range {
            return UIInputExecutionResult.Action(
                outcome: .confirmedNoChange(),
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                elementRole: element.role)
        }
        do {
            try element.setAutomationSelectedTextRange(range)
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: self.delivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Accessibility did not acknowledge the text selection",
                hint: "Observe the element before retrying; selection may have occurred.")
        }
        guard element.selectedTextRange == range, element.stringValue == value else {
            throw DesktopActionFailure.indeterminate(
                delivery: self.delivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Text selection was dispatched but its exact range could not be verified",
                hint: "Observe the element before retrying; its value may have changed.")
        }
        return UIInputExecutionResult.Action(
            outcome: .confirmedChange(delivery: self.delivery, unitCount: .one),
            actionName: "AXSelectedTextRange",
            anchorPoint: nil,
            elementRole: element.role)
    }

    private static var delivery: DesktopActionOutcome.Delivery {
        .init(mechanism: .accessibilityValue, mode: .background)
    }
}
