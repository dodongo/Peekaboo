import Foundation
import PeekabooFoundation

struct ExactLiteralTypingEffectConfirmationTiming: Sendable {
    static let live = Self(
        timeout: .milliseconds(250),
        interval: .milliseconds(20),
        maximumSampleCount: 32,
        now: { ContinuousClock.now },
        sleep: { try await ContinuousClock().sleep(for: $0) })

    let timeout: Duration
    let interval: Duration
    let maximumSampleCount: Int
    let now: @MainActor @Sendable () -> ContinuousClock.Instant
    let sleep: @MainActor @Sendable (Duration) async throws -> Void

    init(
        timeout: Duration,
        interval: Duration,
        maximumSampleCount: Int = 32,
        now: @escaping @MainActor @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void)
    {
        precondition(timeout > .zero)
        precondition(interval > .zero)
        precondition(maximumSampleCount > 0)
        self.timeout = timeout
        self.interval = interval
        self.maximumSampleCount = maximumSampleCount
        self.now = now
        self.sleep = sleep
    }
}

/// Internal postcondition for literal typing whose final value is deterministic. The typed text
/// replaces the whole value after a clear, or else the selection read with the baseline value; an
/// empty selection is the insertion point. Return and Tab count as literal line breaks and tabs in
/// any role; a field that submits or moves focus instead simply never reads back the expected
/// value. Text values stay inside the operation lane and are never added to public results or logs.
struct ExactLiteralTypingEffectConfirmation {
    /// Focused value and selection read before typing.
    struct Baseline: Sendable, Equatable, ExpressibleByStringLiteral {
        let value: String
        let selectedTextRange: NSRange?

        init(value: String, selectedTextRange: NSRange? = nil) {
            self.value = value
            self.selectedTextRange = selectedTextRange
        }

        init(stringLiteral value: String) {
            self.init(value: value)
        }
    }

    let focusedElement: FocusedElementIdentity
    let processStartIdentity: UInt64
    private let literal: String
    private let clearsFirst: Bool

    static func plan(
        actions: [TypeAction],
        target: UIAutomationTarget.ExactWindow) -> Self?
    {
        guard let focusedElement = target.focusedElement,
              focusedElement.role != "AXSecureTextField",
              let firstAction = actions.first
        else { return nil }

        let clearsFirst = firstAction.isClear
        let literalActions = clearsFirst ? Array(actions.dropFirst()) : actions
        guard clearsFirst || !literalActions.isEmpty else { return nil }
        var literal = ""
        for action in literalActions {
            switch action {
            case let .text(text):
                guard text.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
                }) else { return nil }
                literal += text
            case .key(.return):
                literal += "\n"
            case .key(.tab):
                literal += "\t"
            default:
                return nil
            }
        }
        return Self(
            focusedElement: focusedElement,
            processStartIdentity: target.identity.ownerProcessStartIdentity,
            literal: literal,
            clearsFirst: clearsFirst)
    }

    func readableValue(
        from observation: Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>) -> String?
    {
        self.readableBaseline(from: observation)?.value
    }

    func readableBaseline(
        from observation: Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>) -> Baseline?
    {
        guard case let .success(snapshot) = observation,
              snapshot.role != "AXSecureTextField",
              snapshot.subrole != "AXSecureTextField",
              let value = snapshot.value
        else { return nil }
        return Baseline(value: value, selectedTextRange: snapshot.selectedTextRange)
    }

    /// The value typing must produce from `baseline`, or nil when the insertion point is unknown.
    func expectedValue(after baseline: Baseline) -> String? {
        if self.clearsFirst || baseline.value.isEmpty {
            return self.literal
        }
        guard let selection = baseline.selectedTextRange,
              let range = Range(selection, in: baseline.value)
        else { return nil }
        return baseline.value.replacingCharacters(in: range, with: self.literal)
    }

    func confirmedOutcome(
        from outcome: DesktopActionOutcome,
        previousValue: Baseline,
        observedValue: String) -> DesktopActionOutcome
    {
        guard let delivery = outcome.delivery,
              outcome.state == .dispatchedUnverified,
              Self.supportsExactBackgroundDelivery(delivery),
              let expectedValue = self.expectedValue(after: previousValue),
              !previousValue.value.utf8.elementsEqual(expectedValue.utf8),
              observedValue.utf8.elementsEqual(expectedValue.utf8)
        else { return outcome }
        return .confirmedChange(
            route: outcome.route,
            delivery: delivery,
            unitCount: outcome.dispatchState.unitCount)
    }

    private static func supportsExactBackgroundDelivery(_ delivery: DesktopActionOutcome.Delivery) -> Bool {
        guard delivery.mode == .background else { return false }
        switch delivery.mechanism {
        case .windowTargetedEvents, .accessibilityValue, .composite:
            return true
        default:
            return false
        }
    }
}
