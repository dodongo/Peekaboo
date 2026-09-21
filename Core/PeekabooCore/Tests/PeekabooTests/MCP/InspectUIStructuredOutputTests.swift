import CoreGraphics
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct InspectUIStructuredOutputTests {
    @Test
    func retainsFullTextAndControlState() throws {
        let longValue = String(repeating: "界", count: 1000)
        let control = DetectedElement(
            id: "field", type: .textField, label: "Name", value: longValue,
            bounds: CGRect(x: 1, y: 2, width: 3, height: 4), isEnabled: false, isSelected: true,
            attributes: ["identifier": "name", "isValueSettable": "true", "actions": "[\"AXShowMenu\"]"])
        let result = ElementDetectionResult(
            snapshotId: "original", screenshotPath: "", elements: DetectedElements(textFields: [control]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "AX"))
        guard case let .object(output) = InspectUIStructuredOutput.make(snapshotID: "bound", result: result),
              case let .array(elements)? = output["ui_elements"],
              case let .object(element)? = elements.first
        else { Issue.record("Expected structured element"); return }
        #expect(output["snapshot_id"] == .string("bound"))
        #expect(output["snapshot_reusable"] == .bool(true))
        #expect(element["value"] == .string(longValue))
        #expect(element["is_enabled"] == .bool(false))
        #expect(element["is_selected"] == .bool(true))
        #expect(element["is_actionable"] == .bool(false))
        #expect(element["is_value_settable"] == .bool(true))
        #expect(element["actions"] == .array([.string("AXShowMenu")]))
    }

    @Test
    func partialEvidenceCannotAdvertiseMutationAuthority() {
        let control = DetectedElement(
            id: "field", type: .textField, bounds: .zero,
            attributes: ["isValueSettable": "true", "axEnabledKnown": "false"])
        let result = ElementDetectionResult(
            snapshotId: "original", screenshotPath: "", elements: DetectedElements(textFields: [control]),
            metadata: DetectionMetadata(
                detectionTime: 0, elementCount: 1, method: "AX",
                warnings: [DetectionMetadata.applicationScopedAccessibilityFallbackWarning],
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true)))
        guard case let .object(output) = InspectUIStructuredOutput.make(snapshotID: "bound", result: result),
              case let .array(elements)? = output["ui_elements"],
              case let .object(element)? = elements.first,
              case let .object(truncation)? = output["truncation"]
        else { Issue.record("Expected structured partial evidence"); return }
        #expect(output["snapshot_id"] == .null)
        #expect(output["snapshot_reusable"] == .bool(false))
        #expect(output["mutation_targeting_available"] == .bool(false))
        #expect(output["semantic_scope"] == .string("application_partial"))
        #expect(truncation["incomplete_accessibility_read"] == .bool(true))
        #expect(element["is_actionable"] == .bool(false))
        #expect(element["is_enabled"] == nil)
        #expect(element["is_value_settable"] == nil)
    }

    @Test
    func outputFormatIsClosedAndDefaultsToText() throws {
        #expect(try InspectUIRequest(arguments: ToolArguments(raw: [:])).outputFormat == .text)
        #expect(try InspectUIRequest(arguments: ToolArguments(raw: ["output_format": "structured"]))
            .outputFormat == .structured)
        for invalid in [true as Any, "xml"] {
            #expect(throws: (any Error).self) {
                try InspectUIRequest(arguments: ToolArguments(raw: ["output_format": invalid]))
            }
        }
    }
}
