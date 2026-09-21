import AppKit
import Foundation

/// Versioned slot storage preserves item boundaries and distinguishes empty from absent.
struct ClipboardSlotSnapshot: Codable, Equatable {
    static let type = NSPasteboard.PasteboardType("boo.peekaboo.clipboard-slot-v1")
    let version: Int
    let items: [[ClipboardRepresentation]]

    @MainActor
    static func capture(_ pasteboard: NSPasteboard) throws -> Self {
        let changeCount = pasteboard.changeCount
        var items: [[ClipboardRepresentation]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [ClipboardRepresentation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw ClipboardServiceError.writeFailed("Cannot preserve clipboard type \(type.rawValue)")
                }
                representations.append(ClipboardRepresentation(utiIdentifier: type.rawValue, data: data))
            }
            if !representations.isEmpty { items.append(representations) }
        }
        guard !items.isEmpty || pasteboard.types?.isEmpty != false else {
            throw ClipboardServiceError.writeFailed("Clipboard types could not be materialized as items")
        }
        guard pasteboard.changeCount == changeCount else {
            throw ClipboardServiceError.writeFailed("Clipboard changed while saving; no slot was written")
        }
        return Self(version: 1, items: items)
    }

    @MainActor
    static func load(_ pasteboard: NSPasteboard, slot: String) throws -> Self {
        if let data = pasteboard.data(forType: self.type) {
            let snapshot = try PropertyListDecoder().decode(Self.self, from: data)
            guard snapshot.version == 1 else {
                throw ClipboardServiceError.writeFailed("Unsupported clipboard slot version")
            }
            return snapshot
        }
        // Slots written by older hosts contain raw representations.
        let legacy = try self.capture(pasteboard)
        guard !legacy.items.isEmpty else { throw ClipboardServiceError.slotNotFound(slot) }
        return legacy
    }

    @MainActor
    func makeItems() throws -> [NSPasteboardItem] {
        try self.items.map { representations in
            guard !representations.isEmpty,
                  Set(representations.map(\.utiIdentifier)).count == representations.count
            else { throw ClipboardServiceError.writeFailed("Malformed clipboard slot item") }
            let item = NSPasteboardItem()
            for representation in representations {
                guard !representation.utiIdentifier.isEmpty,
                      item.setData(representation.data, forType: .init(representation.utiIdentifier))
                else { throw ClipboardServiceError.writeFailed("Cannot reconstruct clipboard slot item") }
            }
            return item
        }
    }
}
