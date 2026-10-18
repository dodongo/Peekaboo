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

/// Confirms literal typing from the baseline value and selection without exposing field contents.
/// Text values stay inside the operation lane and are never added to public results or logs.
struct ExactLiteralTypingEffectConfirmation {
    struct Baseline: Sendable, Equatable {
        let value: String
        let selectedTextRange: NSRange?

        init(value: String, selectedTextRange: NSRange? = nil) {
            self.value = value
            self.selectedTextRange = selectedTextRange
        }
    }

    let focusedElement: FocusedElementIdentity
    let processStartIdentity: UInt64
    private let windowBounds: CGRect
    private let literal: String
    private let clearsFirst: Bool

    static func plan(
        actions: [TypeAction],
        target: UIAutomationTarget.ExactWindow) -> Self?
    {
        guard let focusedElement = target.focusedElement,
              focusedElement.role != "AXSecureTextField",
              TypeAction.hasDeterministicReplacementValue(actions)
        else { return nil }

        let clearsFirst = actions.first?.isClear == true
        let literalActions = clearsFirst ? actions.dropFirst() : actions[...]
        var literal = ""
        for action in literalActions {
            switch action {
            case let .text(text): literal += text
            case .key(.return): literal += "\n"
            case .key(.tab): literal += "\t"
            default: return nil
            }
        }
        return Self(
            focusedElement: focusedElement,
            processStartIdentity: target.identity.ownerProcessStartIdentity,
            windowBounds: target.bounds,
            literal: literal,
            clearsFirst: clearsFirst)
    }

    func readableValue(
        from observation: Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>,
        retainedElement: RetainedFocusElement? = nil) -> String?
    {
        guard case let .success(snapshot) = observation,
              snapshot.role != "AXSecureTextField",
              snapshot.subrole != "AXSecureTextField",
              snapshot.subroleIsReadable,
              let role = snapshot.role,
              let windowID = snapshot.windowID,
              !snapshot.frame.isEmpty,
              self.windowBounds.contains(CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY)),
              retainedElement == nil || snapshot.nativeElement == retainedElement
        else { return nil }
        let actual = FocusedElementIdentity(
            processIdentifier: snapshot.processIdentifier,
            windowID: windowID,
            role: role,
            title: snapshot.title,
            identifier: snapshot.identifier,
            frame: snapshot.frame)
        guard FocusedElementReceiptResolver.matches(
            actual,
            expected: self.focusedElement,
            phase: retainedElement == nil ? .initial : .continuation)
        else { return nil }
        return snapshot.value
    }

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
