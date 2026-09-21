import Foundation
import PeekabooFoundation

/// An unambiguous substring selection, resolved against the live value at dispatch.
public struct TextSelectionRequest: Codable, Sendable, Equatable {
    public enum SelectionType: String, Codable, Sendable {
        case text
        case cursorBefore = "cursor_before"
        case cursorAfter = "cursor_after"
    }

    public let text: String
    public let prefix: String?
    public let suffix: String?
    public let selectionType: SelectionType

    public init(text: String, prefix: String? = nil, suffix: String? = nil, selectionType: SelectionType = .text) {
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.selectionType = selectionType
    }

    public var selectedText: String {
        self.selectionType == .text ? self.text : ""
    }

    public func range(in value: String) throws -> NSRange {
        guard !self.text.isEmpty else {
            throw PeekabooError.invalidInput("Selection text must not be empty")
        }
        let source = value as NSString
        var cursor = 0
        var selected: NSRange?
        while cursor < source.length {
            let match = source.range(of: self.text, range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound else { break }
            if self.matchesContext(source, range: match) {
                guard selected == nil else {
                    throw PeekabooError
                        .invalidInput("Selection text is ambiguous; provide an adjacent prefix or suffix")
                }
                selected = match
            }
            cursor = match.location + 1
        }
        guard let selected else {
            throw PeekabooError.invalidInput("Selection text and context were not found in the live element value")
        }
        switch self.selectionType {
        case .text: return selected
        case .cursorBefore: return NSRange(location: selected.location, length: 0)
        case .cursorAfter: return NSRange(location: NSMaxRange(selected), length: 0)
        }
    }

    private func matchesContext(_ source: NSString, range: NSRange) -> Bool {
        if let prefix = self.prefix {
            let length = (prefix as NSString).length
            guard range.location >= length,
                  source.substring(with: NSRange(location: range.location - length, length: length)) == prefix
            else { return false }
        }
        if let suffix = self.suffix {
            let length = (suffix as NSString).length
            guard source.length - NSMaxRange(range) >= length,
                  source.substring(with: NSRange(location: NSMaxRange(range), length: length)) == suffix
            else { return false }
        }
        return true
    }
}

@MainActor
public protocol TextSelectionAutomationServiceProtocol: UIAutomationServiceProtocol {
    func selectTextWithOutcome(
        target: String,
        selection: TextSelectionRequest,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
}
