import AppKit
import Foundation
import PeekabooFoundation
import UniformTypeIdentifiers

/// Representation of a single pasteboard payload.
public struct ClipboardRepresentation: Sendable, Codable, Equatable {
    public let utiIdentifier: String
    public let data: Data

    public init(utiIdentifier: String, data: Data) {
        self.utiIdentifier = utiIdentifier
        self.data = data
    }
}

/// Request to write multiple representations to the clipboard.
public struct ClipboardWriteRequest: Sendable {
    public var representations: [ClipboardRepresentation]
    public var alsoText: String?
    public var allowLarge: Bool

    public init(
        representations: [ClipboardRepresentation],
        alsoText: String? = nil,
        allowLarge: Bool = false)
    {
        self.representations = representations
        self.alsoText = alsoText
        self.allowLarge = allowLarge
    }
}

extension ClipboardWriteRequest {
    public static func textRepresentations(from data: Data) -> [ClipboardRepresentation] {
        [
            ClipboardRepresentation(utiIdentifier: UTType.plainText.identifier, data: data),
            ClipboardRepresentation(utiIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: data),
        ]
    }
}

/// Result returned after reading the clipboard.
public struct ClipboardReadResult: Sendable {
    public let utiIdentifier: String
    public let data: Data
    public let textPreview: String?

    public init(utiIdentifier: String, data: Data, textPreview: String?) {
        self.utiIdentifier = utiIdentifier
        self.data = data
        self.textPreview = textPreview
    }
}

/// Possible errors thrown by the clipboard service.
public enum ClipboardServiceError: LocalizedError, Sendable {
    case empty
    case sizeExceeded(current: Int, limit: Int)
    case slotNotFound(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Clipboard is empty."
        case let .sizeExceeded(current, limit):
            "Clipboard write blocked: size \(current) bytes exceeds \(limit) bytes. Use allowLarge to override."
        case let .slotNotFound(slot):
            "Clipboard slot '\(slot)' not found."
        case let .writeFailed(reason):
            "Failed to write to clipboard: \(reason)"
        }
    }
}

/// Protocol describing clipboard operations.
@MainActor
public protocol ClipboardServiceProtocol: Sendable {
    func get(prefer uti: UTType?) throws -> ClipboardReadResult?
    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult
    func clear()
    func save(slot: String) throws
    /// Restores all saved items; nil represents a successfully restored empty clipboard.
    func restore(slot: String) throws -> ClipboardReadResult?
}

/// Additive capability for clipboard mutations that retain canonical action semantics.
@MainActor
public protocol ClipboardServiceActionResultProviding: ClipboardServiceProtocol {
    func setActionResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult>
    func clearActionResult() throws -> DesktopActionResult<Void>
    func restoreActionResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult?>
}

/// Shared clipboard mutation policy used by services and result consumers.
public enum ClipboardMutationResultSemantics {
    public static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .clipboardTransaction,
        mode: .foreground)

    public static func requireSuccessfulOutcome(
        _ outcome: DesktopActionOutcome?,
        operation: String) throws -> DesktopActionOutcome
    {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: self.delivery,
                evidence: .completionUnknown,
                message: "\(operation) returned without a canonical clipboard outcome.",
                hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.")
        }
        return try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            outcome,
            policy: .confirmedOrDispatched(requiring: self.delivery.mode),
            operation: operation,
            missingOutcomeMessage: "\(operation) returned without a canonical clipboard outcome.",
            rejectedOutcomeMessage: "\(operation) did not return a successful clipboard outcome.",
            missingOutcomeHint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.")
    }

    public static func postWriteFailure(_ error: any Error, operation: String) -> DesktopActionFailure {
        .indeterminate(
            delivery: self.delivery,
            evidence: .completionUnknown,
            message: "\(operation) may have changed the clipboard, but post-write processing failed.",
            hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.",
            causeDescription: error.localizedDescription)
    }
}

extension ClipboardServiceProtocol {
    public func setResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult> {
        if let provider = self as? any ClipboardServiceActionResultProviding {
            return try provider.setActionResult(request)
        }
        guard !request.representations.isEmpty else {
            throw ClipboardMutationResultOwner.preDispatchFailure(
                ClipboardServiceError.writeFailed("No representations provided."),
                operation: "Clipboard set")
        }
        return try ClipboardMutationResultOwner.performLegacy(
            operation: "Clipboard set",
            mutation: { try self.set(request) })
    }

    public func clearResult() throws -> DesktopActionResult<Void> {
        if let provider = self as? any ClipboardServiceActionResultProviding {
            return try provider.clearActionResult()
        }
        self.clear()
        return DesktopActionResult(
            outcome: .dispatchedUnverified(
                delivery: ClipboardMutationResultSemantics.delivery,
                evidence: .deliveryAccepted))
    }

    public func restoreResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult?> {
        if let provider = self as? any ClipboardServiceActionResultProviding {
            return try provider.restoreActionResult(slot: slot)
        }
        guard !slot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardMutationResultOwner.preDispatchFailure(
                ClipboardServiceError.slotNotFound(slot),
                operation: "Clipboard restore")
        }
        return try ClipboardMutationResultOwner.performLegacy(
            operation: "Clipboard restore",
            mutation: { try self.restore(slot: slot) })
    }
}

private enum ClipboardMutationResultOwner {
    static func perform<Payload: Sendable>(
        operation: String,
        mutation: (inout Bool) throws -> Payload,
        verify: (Payload) throws -> Bool) throws -> DesktopActionResult<Payload>
    {
        var didDispatch = false
        do {
            let payload = try mutation(&didDispatch)
            guard didDispatch else {
                throw DesktopActionFailure.indeterminate(
                    delivery: ClipboardMutationResultSemantics.delivery,
                    evidence: .completionUnknown,
                    message: "\(operation) completed without recording clipboard dispatch.",
                    hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.")
            }
            let outcome: DesktopActionOutcome = try verify(payload)
                ? .confirmedChange(
                    delivery: ClipboardMutationResultSemantics.delivery)
                : .dispatchedUnverified(
                    delivery: ClipboardMutationResultSemantics.delivery,
                    evidence: .deliveryAccepted)
            return DesktopActionResult(payload: payload, outcome: outcome)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            if didDispatch {
                throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: operation)
            }
            throw self.preDispatchFailure(error, operation: operation)
        }
    }

    static func performLegacy<Payload: Sendable>(
        operation: String,
        mutation: () throws -> Payload) throws -> DesktopActionResult<Payload>
    {
        do {
            let payload = try mutation()
            return DesktopActionResult(
                payload: payload,
                outcome: .dispatchedUnverified(
                    delivery: ClipboardMutationResultSemantics.delivery,
                    evidence: .deliveryAccepted))
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as ClipboardServiceError {
            switch error {
            case .empty, .sizeExceeded, .slotNotFound:
                throw self.preDispatchFailure(error, operation: operation)
            case .writeFailed:
                throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: operation)
            }
        } catch {
            throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: operation)
        }
    }

    static func preDispatchFailure(_ error: any Error, operation: String) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .invalidRequest,
            message: "\(operation) was refused before dispatch.",
            hint: "Correct the clipboard request before retrying.",
            causeDescription: error.localizedDescription)
    }
}

/// Default implementation backed by NSPasteboard.
@MainActor
public final class ClipboardService: ClipboardServiceActionResultProviding {
    private let pasteboard: NSPasteboard
    private let sizeLimit: Int

    public init(pasteboard: NSPasteboard = .general, sizeLimit: Int = ClipboardPayloadBuilder.defaultSizeLimit) {
        self.pasteboard = pasteboard
        self.sizeLimit = sizeLimit
    }

    // MARK: - Slot storage (cross-process)

    private func slotPasteboardName(for slot: String) -> NSPasteboard.Name {
        let sanitizedSlot = slot
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { scalar -> String in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                return allowed.contains(scalar) ? String(Character(scalar)) : "_"
            }
            .joined()

        return NSPasteboard.Name("\(self.pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.\(sanitizedSlot)")
    }

    // MARK: - Public API

    public func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        guard let types = self.pasteboard.types, !types.isEmpty else { return nil }

        let targetType: NSPasteboard.PasteboardType = if let uti,
                                                         let preferred = types
                                                             .first(where: { $0.rawValue == uti.identifier })
        {
            preferred
        } else if let stringType = types.first(where: { $0 == .string || $0 == .init("public.utf8-plain-text") }) {
            stringType
        } else {
            types[0]
        }

        let data: Data?
        var textPreview: String?

        if targetType == .string, let string = self.pasteboard.string(forType: .string) {
            let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
                of: "\r",
                with: "\n")
            data = normalized.data(using: .utf8)
            textPreview = Self.makePreview(normalized)
        } else {
            data = self.pasteboard.data(forType: targetType)
            if let data, let string = String(data: data, encoding: .utf8) {
                textPreview = Self.makePreview(string)
            }
        }

        guard let data else { return nil }

        return ClipboardReadResult(
            utiIdentifier: targetType.rawValue,
            data: data,
            textPreview: textPreview)
    }

    public func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        var didDispatch = false
        return try self.set(request, didDispatch: &didDispatch)
    }

    public func setActionResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult> {
        try ClipboardMutationResultOwner.perform(
            operation: "Clipboard set",
            mutation: { didDispatch in
                try self.set(request, didDispatch: &didDispatch)
            },
            verify: { _ in self.matches(request: request) })
    }

    private func set(
        _ request: ClipboardWriteRequest,
        didDispatch: inout Bool) throws -> ClipboardReadResult
    {
        guard !request.representations.isEmpty else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }

        let totalSize = request.representations.reduce(0) { $0 + $1.data.count } +
            (request.alsoText?.utf8.count ?? 0)
        if !request.allowLarge, totalSize > self.sizeLimit {
            throw ClipboardServiceError.sizeExceeded(current: totalSize, limit: self.sizeLimit)
        }

        var types = request.representations.map { NSPasteboard.PasteboardType($0.utiIdentifier) }
        let includesTextType = request.representations.contains(where: Self.isPlainTextRepresentation)
        if request.alsoText != nil || includesTextType {
            if !types.contains(.string) {
                types.append(.string)
            }
        }
        self.pasteboard.declareTypes(types, owner: nil)
        didDispatch = true

        for representation in request.representations {
            let pbType = NSPasteboard.PasteboardType(representation.utiIdentifier)
            guard self.pasteboard.setData(representation.data, forType: pbType) else {
                throw ClipboardServiceError.writeFailed("Unable to set type \(representation.utiIdentifier)")
            }
        }

        if let alsoText = request.alsoText {
            self.pasteboard.setString(alsoText, forType: .string)
        } else if let representation = request.representations.first(where: Self.isPlainTextRepresentation),
                  let fallbackText = String(data: representation.data, encoding: .utf8)
        {
            self.pasteboard.setString(fallbackText, forType: .string)
        }

        let primary = request.representations.first!
        let preview: String? = if let text = request.alsoText {
            Self.makePreview(text)
        } else if Self.isPlainTextRepresentation(primary),
                  let string = String(data: primary.data, encoding: .utf8)
        {
            Self.makePreview(string)
        } else {
            nil
        }

        return ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: preview)
    }

    public func clear() {
        self.pasteboard.clearContents()
    }

    public func clearActionResult() throws -> DesktopActionResult<Void> {
        try ClipboardMutationResultOwner.perform(
            operation: "Clipboard clear",
            mutation: { didDispatch in
                self.pasteboard.clearContents()
                didDispatch = true
            },
            verify: { _ in self.pasteboard.types?.isEmpty != false })
    }

    public func save(slot: String) throws {
        let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlot.isEmpty else {
            throw ClipboardServiceError.writeFailed("Slot name must not be empty.")
        }

        let snapshot = try ClipboardSlotSnapshot.capture(self.pasteboard)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        let slotPasteboard = NSPasteboard(name: self.slotPasteboardName(for: trimmedSlot))
        slotPasteboard.clearContents()
        guard slotPasteboard.setData(data, forType: ClipboardSlotSnapshot.type) else {
            throw ClipboardServiceError.writeFailed("Unable to save clipboard slot \(trimmedSlot)")
        }
    }

    /// Returns nil when the saved clipboard was empty.
    public func restore(slot: String) throws -> ClipboardReadResult? {
        var didDispatch = false
        return try self.restore(slot: slot, didDispatch: &didDispatch).result
    }

    public func restoreActionResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult?> {
        var restoredSnapshot: ClipboardSlotSnapshot?
        return try ClipboardMutationResultOwner.perform(
            operation: "Clipboard restore",
            mutation: { didDispatch in
                let restored = try self.restore(slot: slot, didDispatch: &didDispatch)
                restoredSnapshot = restored.snapshot
                return restored.result
            },
            verify: { _ in try ClipboardSlotSnapshot.capture(self.pasteboard) == restoredSnapshot })
    }

    private func restore(
        slot: String,
        didDispatch: inout Bool) throws -> (result: ClipboardReadResult?, snapshot: ClipboardSlotSnapshot)
    {
        let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlot.isEmpty else {
            throw ClipboardServiceError.slotNotFound(slot)
        }
        let slotPasteboard = NSPasteboard(name: self.slotPasteboardName(for: trimmedSlot))
        let slotChangeCount = slotPasteboard.changeCount
        let snapshot = try ClipboardSlotSnapshot.load(slotPasteboard, slot: trimmedSlot)
        // Construct every item before changing the destination pasteboard.
        let items = try snapshot.makeItems()
        self.pasteboard.clearContents()
        didDispatch = true
        if !items.isEmpty, !self.pasteboard.writeObjects(items) {
            throw ClipboardServiceError.writeFailed("Unable to restore all clipboard items")
        }
        let result = try self.get(prefer: nil)
        // Never discard a slot saved by another process during restoration.
        if slotPasteboard.changeCount == slotChangeCount {
            slotPasteboard.clearContents()
        }
        return (result, snapshot)
    }

    // MARK: - Helpers

    private static func isPlainTextRepresentation(_ representation: ClipboardRepresentation) -> Bool {
        representation.utiIdentifier == UTType.plainText.identifier ||
            representation.utiIdentifier == UTType.utf8PlainText.identifier
    }

    private func matches(request: ClipboardWriteRequest) -> Bool {
        self.matches(representations: request.representations, alsoText: request.alsoText)
    }

    private func matches(representations: [ClipboardRepresentation], alsoText: String?) -> Bool {
        for representation in representations {
            let type = NSPasteboard.PasteboardType(representation.utiIdentifier)
            guard let actual = self.pasteboard.data(forType: type),
                  Self.normalizedData(actual, for: representation.utiIdentifier) ==
                  Self.normalizedData(representation.data, for: representation.utiIdentifier)
            else {
                return false
            }
        }
        if let alsoText {
            guard let actual = self.pasteboard.string(forType: .string),
                  Self.normalizedText(actual) == Self.normalizedText(alsoText)
            else {
                return false
            }
        }
        return true
    }

    private static func normalizedData(_ data: Data, for utiIdentifier: String) -> Data {
        guard [UTType.plainText.identifier, UTType.utf8PlainText.identifier].contains(utiIdentifier),
              let text = String(data: data, encoding: .utf8)
        else {
            return data
        }
        return Data(self.normalizedText(text).utf8)
    }

    private static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func makePreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let max = 80
        guard trimmed.count > max else { return trimmed }
        let head = trimmed.prefix(max)
        return "\(head)…"
    }
}
