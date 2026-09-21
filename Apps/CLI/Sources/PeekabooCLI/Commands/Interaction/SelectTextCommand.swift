import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
struct SelectTextCommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
RuntimeBackedCommand {
    @Argument(help: "Substring to select")
    var value: String?
    @Option(help: "Adjacent text before the requested match") var prefix: String?
    @Option(help: "Adjacent text after the requested match") var suffix: String?
    @Option(help: "text, cursor_before, or cursor_after") var selectionType: String = "text"

    @Option(help: "Element ID or query containing the text")
    var on: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        try await ElementActionCommandExecutor.execute(
            context: ElementActionCommandContext(
                runtime: runtime,
                snapshot: self.snapshot,
                invalidationReason: "select-text",
                deliveryMechanism: .accessibilityValue,
                target: self.target,
                focusOptions: self.focusOptions
            ),
            prepare: {
                try (self.requireTarget(), self.requireValue())
            },
            operation: { automation, target, value, snapshotId in
                guard let service = automation as? any TextSelectionAutomationServiceProtocol else {
                    throw PeekabooError.serviceUnavailable("The automation host does not support text selection")
                }
                return try await service.selectTextWithOutcome(
                    target: target, selection: value, snapshotId: snapshotId
                )
            },
            render: { result, outcome, targetIdentity, outputPayload, _ in
                self.output(outputPayload, outcome: outcome, targetIdentity: targetIdentity) {
                    if let outcome {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Select text"))
                        print("🎯 Target: \(result.target)")
                    } else {
                        print("✅ Select text on \(result.target)")
                    }
                    if let newValue = result.newValue {
                        print("📝 Selected text: \(newValue)")
                    }
                }
            },
            handleError: { self.handleError($0) }
        )
    }

    private func requireTarget() throws -> String {
        guard let on = self.on?.trimmingCharacters(in: .whitespacesAndNewlines), !on.isEmpty else {
            throw ValidationError("--on is required")
        }
        return on
    }

    private func requireValue() throws -> TextSelectionRequest {
        guard let value, !value.isEmpty else {
            throw ValidationError("Selection text is required")
        }
        guard let type = TextSelectionRequest.SelectionType(rawValue: self.selectionType) else {
            throw ValidationError("--selection-type must be text, cursor_before, or cursor_after")
        }
        return TextSelectionRequest(text: value, prefix: self.prefix, suffix: self.suffix, selectionType: type)
    }
}

@MainActor
extension SelectTextCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "select-text",
            abstract: "Select text or place its cursor directly",
            discussion: """
                Selects one matching substring in a non-secure text field without changing its contents.
                Supply prefix/suffix to disambiguate repeated text; stale or ambiguous matches fail before mutation.

                EXAMPLES:
                  peekaboo select-text "hello" --on "$ELEMENT_ID"
                  peekaboo select-text "42" --on "Search"
            """,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension SelectTextCommand: AsyncRuntimeCommand {}

extension SelectTextCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        _ = try ElementActionCommandExecutor.validateRequest(
            snapshot: self.snapshot,
            target: self.target,
            prepare: { try (self.requireTarget(), self.requireValue()) }
        )
    }
}

@MainActor
extension SelectTextCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.value = try values.decodeOptionalPositional(0, label: "value") ?? values.singleOption("value")
        self.on = values.singleOption("on")
        self.snapshot = values.singleOption("snapshot")
        self.prefix = values.singleOption("prefix")
        self.suffix = values.singleOption("suffix")
        self.selectionType = values.singleOption("selectionType") ?? "text"
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}

extension SelectTextCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(label: "value", help: "Substring to select", isOptional: true),
            ],
            options: [
                .commandOption("prefix", help: "Adjacent prefix", long: "prefix"),
                .commandOption("suffix", help: "Adjacent suffix", long: "suffix"),
                .commandOption("selectionType", help: "text|cursor_before|cursor_after", long: "selection-type"),
                .commandOption(
                    "value",
                    help: "Substring to select (alternative to positional argument)",
                    long: "value"
                ),
                .commandOption("on", help: "Element ID or query containing the text", long: "on"),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
