import Foundation
import PeekabooFoundation

extension UIAutomationService: TextSelectionAutomationServiceProtocol {
    public func selectTextWithOutcome(
        target: String,
        selection: TextSelectionRequest,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        let requiredSnapshotID = try Self.requireElementActionSnapshotID(snapshotId)
        let receipt = try await self.elementMutationCaptureReceipt(snapshotId: requiredSnapshotID)
        var resolved: ResolvedElementMutationTarget?
        var selectedText: String?
        let plan = try DesktopOperationPlan(
            verb: .setValue,
            selector: .element(target),
            captureReceipt: receipt,
            strategy: self.inputPolicy.strategy(for: .setValue, bundleIdentifier: receipt.bundleIdentifier),
            prepare: {
                let element = try await self.resolveActionTarget(
                    target, snapshotId: requiredSnapshotID, targetProcessIdentifier: receipt.processIdentifier)
                try self.validateElementMutationTarget(element, receipt: receipt)
                resolved = element
            },
            routing: {
                let bundle = resolved?.bundleIdentifier ?? receipt.bundleIdentifier
                return DesktopOperationPlan.Routing(
                    strategy: self.inputPolicy.strategy(for: .setValue, bundleIdentifier: bundle),
                    bundleIdentifier: bundle)
            },
            action: DesktopOperationPlan.ActionRoute {
                guard let resolved else {
                    throw PeekabooError.operationError(message: "Text selection target was not prepared")
                }
                try self.validateElementMutationTarget(resolved, receipt: receipt)
                return try TextSelectionInput.select(selection, on: resolved.element)
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                throw PeekabooError.invalidInput("Text selection requires direct Accessibility range support")
            },
            postvalidate: { result in
                if let resolved,
                   let value = resolved.element.stringValue,
                   let range = resolved.element.selectedTextRange,
                   range.location <= (value as NSString).length,
                   range.length <= (value as NSString).length - range.location,
                   range == (try? selection.range(in: value))
                {
                    selectedText = (value as NSString).substring(with: range)
                } else {
                    throw DesktopActionFailure.indeterminate(
                        delivery: result.outcome.delivery,
                        evidence: .completionUnknown,
                        unitCount: result.outcome.dispatchState.unitCount,
                        message: "Text selection changed before verification completed",
                        hint: "Observe the element before retrying.")
                }
            },
            finalize: { self.elementDetectionService.invalidateCache() })
        let execution = try await self.normalizingElementMutationErrors {
            try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
        }
        return UIAutomationActionResult(
            payload: ElementActionResult(
                target: target,
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                newValue: selectedText),
            outcome: execution.payload.outcome,
            targetIdentity: execution.targetIdentity)
    }
}
