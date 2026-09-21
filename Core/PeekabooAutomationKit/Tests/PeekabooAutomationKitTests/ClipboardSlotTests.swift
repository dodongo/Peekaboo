import AppKit
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ClipboardSlotTests: XCTestCase {
    func testEmptySlotRestoresAcrossServiceInstancesAndIsConsumed() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = ClipboardService(pasteboard: pasteboard)
        try writer.save(slot: "empty")
        _ = try writer.set(ClipboardPayloadBuilder.textRequest(text: "temporary"))

        let reader = ClipboardService(pasteboard: pasteboard)
        let restored = try reader.restoreResult(slot: "empty")
        XCTAssertNil(restored.payload)
        XCTAssertEqual(restored.outcome, .confirmedChange(delivery: ClipboardMutationResultSemantics.delivery))
        XCTAssertTrue(pasteboard.types?.isEmpty != false)
        let changeCount = pasteboard.changeCount
        XCTAssertThrowsError(try writer.restore(slot: "empty"))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
    }

    func testOrderedItemsAndBinaryRepresentationsRestoreWithoutFlattening() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setData(Data([0, 255, 127]), forType: .init("com.example.binary"))
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        second.setString("<b>second</b>", forType: .html)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let original = try ClipboardSlotSnapshot.capture(pasteboard)
        let writer = ClipboardService(pasteboard: pasteboard)
        try writer.save(slot: "items")
        writer.clear()

        let reader = ClipboardService(pasteboard: pasteboard)
        let result = try reader.restoreResult(slot: "items")
        XCTAssertEqual(result.outcome, .confirmedChange(delivery: ClipboardMutationResultSemantics.delivery))
        XCTAssertEqual(try ClipboardSlotSnapshot.capture(pasteboard), original)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
    }

    func testLatestSavedSlotWinsAcrossInstances() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = ClipboardService(pasteboard: pasteboard)
        let second = ClipboardService(pasteboard: pasteboard)
        _ = try first.set(ClipboardPayloadBuilder.textRequest(text: "old"))
        try first.save(slot: "shared")
        _ = try second.set(ClipboardPayloadBuilder.textRequest(text: "latest"))
        try second.save(slot: "shared")
        first.clear()
        XCTAssertEqual(try first.restore(slot: "shared")?.textPreview, "latest")
    }

    func testMissingAndMalformedSlotsRefuseWithoutChangingDestination() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(pasteboard: pasteboard)
        _ = try service.set(ClipboardPayloadBuilder.textRequest(text: "preserved"))
        let count = pasteboard.changeCount
        XCTAssertThrowsError(try service.restoreResult(slot: "missing"))
        let slot = NSPasteboard(name: .init("\(pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.broken"))
        defer { slot.releaseGlobally() }
        slot.setData(Data("invalid snapshot".utf8), forType: ClipboardSlotSnapshot.type)
        XCTAssertThrowsError(try service.restoreResult(slot: "broken")) { error in
            XCTAssertEqual((error as? DesktopActionFailure)?.outcome, .refused(reason: .invalidRequest))
        }
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), "preserved")
    }

    func testSavedLargePayloadRestoresWithoutChangingSetLimit() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(pasteboard: pasteboard, sizeLimit: 4)
        let request = ClipboardWriteRequest(representations: [
            ClipboardRepresentation(utiIdentifier: "com.example.binary", data: Data(repeating: 255, count: 16)),
        ])
        XCTAssertThrowsError(try service.set(request))
        pasteboard.setData(request.representations[0].data, forType: .init("com.example.binary"))
        try service.save(slot: "large")
        service.clear()
        XCTAssertEqual(try service.restore(slot: "large")?.data, request.representations[0].data)
        XCTAssertThrowsError(try service.set(request))
    }

    func testLegacyRawSlotRemainsRestorable() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let slot = NSPasteboard(name: .init("\(pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.legacy"))
        defer { slot.releaseGlobally() }
        slot.setString("legacy text", forType: .string)
        XCTAssertEqual(try ClipboardService(pasteboard: pasteboard).restore(slot: "legacy")?.textPreview, "legacy text")
    }
}
