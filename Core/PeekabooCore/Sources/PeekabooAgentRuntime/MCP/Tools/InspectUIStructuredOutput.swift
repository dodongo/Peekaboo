import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation

/// Structured AX evidence for clients that retain full state and render their own bounded preview.
enum InspectUIStructuredOutput {
    static func make(snapshotID: String, result: ElementDetectionResult) throws -> Value {
        let metadata = result.metadata
        let reusable = !metadata.isApplicationScopedAccessibilityFallback && !snapshotID.isEmpty
        var fields: [String: Value] = [
            "snapshot_id": reusable ? .string(snapshotID) : .null,
            "snapshot_reusable": .bool(reusable),
            "semantic_scope": .string(reusable ? "exact_or_requested" : "application_partial"),
            "mutation_targeting_available": .bool(reusable),
            "is_dialog": .bool(metadata.isDialog),
            "element_count": .int(result.elements.all.count),
            "warnings": .array(metadata.warnings.map(Value.string)),
            "ui_elements": try Value(result.elements.all.map { UIElementSummary($0, mutationTargetingAvailable: reusable) }),
        ]
        fields["application_name"] = metadata.windowContext?.applicationName.map(Value.string)
        fields["window_title"] = metadata.windowContext?.windowTitle.map(Value.string)
        if let truncation = metadata.truncationInfo {
            fields["truncation"] = .object([
                "truncated": .bool(truncation.isTruncated),
                "max_depth_reached": .bool(truncation.maxDepthReached),
                "max_element_count_reached": .bool(truncation.maxElementCountReached),
                "max_children_per_node_reached": .bool(truncation.maxChildrenPerNodeReached),
                "deadline_reached": .bool(truncation.deadlineReached),
                "incomplete_accessibility_read": .bool(truncation.incompleteAccessibilityRead),
            ])
        }
        return .object(fields)
    }

}
