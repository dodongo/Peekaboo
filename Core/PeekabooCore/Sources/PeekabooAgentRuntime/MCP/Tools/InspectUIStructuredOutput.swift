import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation

/// Structured AX evidence for clients that retain full state and render their own bounded preview.
enum InspectUIStructuredOutput {
    static func make(snapshotID: String, result: ElementDetectionResult) -> Value {
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
            "ui_elements": .array(result.elements.all.map { self.element($0, reusable: reusable) }),
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

    private static func element(_ element: DetectedElement, reusable: Bool) -> Value {
        var fields: [String: Value] = [
            "id": .string(element.id),
            "role": .string(element.type.rawValue),
            "is_actionable": .bool(reusable && element.isActionable),
            "bounds": .object([
                "x": .double(element.bounds.origin.x),
                "y": .double(element.bounds.origin.y),
                "width": .double(element.bounds.width),
                "height": .double(element.bounds.height),
            ]),
        ]
        fields["label"] = element.label.map(Value.string)
        fields["value"] = element.value.map(Value.string)
        fields["is_enabled"] = element.knownIsEnabled.map(Value.bool)
        fields["is_selected"] = element.isSelected.map(Value.bool)
        if reusable {
            fields["is_value_settable"] = element.isValueSettable.map(Value.bool)
        }
        for (key, attribute) in [
            ("ax_role", "role"), ("title", "title"), ("description", "description"),
            ("role_description", "roleDescription"), ("help", "help"),
            ("identifier", "identifier"), ("keyboard_shortcut", "keyboardShortcut"),
        ] {
            fields[key] = element.attributes[attribute].map(Value.string)
        }
        if let encodedActions = element.attributes["actions"],
           let actions = try? JSONDecoder().decode([String].self, from: Data(encodedActions.utf8))
        {
            fields["actions"] = .array(actions.map(Value.string))
        }
        return .object(fields)
    }
}
