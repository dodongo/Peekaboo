import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct BrowserCommandStreamTests {
    @Test
    func startupAdvertisesKnownFeaturesWithoutInventingUnknownCapabilities() throws {
        for features: [String]? in [nil, [], ["read:skipNavigationWait"]] {
            let data = try BrowserCommandStream.readyMessage(features: features)
            let message = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(message["ready"] as? Bool == true)
            #expect(message["protocol"] as? String == "peekaboo-browser-stream-1")
            #expect(message["features"] as? [String] == features)
            #expect(data.last == 10)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func readsOneRequestWithoutWaitingForPipeEOF() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("request\n".utf8))
        var reader = BrowserCommandStream.Input(handle: pipe.fileHandleForReading)
        #expect(try reader.next() == Data("request".utf8))
    }

    @Test
    @MainActor
    func validatesBeforeRuntimeWithoutAccessingInjectedServices() throws {
        var command = BrowserCommand()
        command.action = "stream"
        command.pageId = 7
        command.foreground = true
        command.runtimeOptions.jsonOutput = true
        try command.validateBeforeRuntime()
        command.foreground = false
        #expect(throws: (any Error).self) { try command.validateBeforeRuntime() }
    }

    @Test
    func bindsPageAndPolicyWithoutAcceptingScopeOverrides() throws {
        let valid = Data(#"{"action":"click","uid":"7_3","include_snapshot":true}"#.utf8)
        let arguments = try BrowserCommandStream.arguments(from: valid, pageID: 7)
        #expect(arguments["page_id"] as? Int == 7)
        #expect(arguments["background"] as? Bool == false)
        #expect(arguments["uid"] as? String == "7_3")
        for input in [
            #"{"action":"connect"}"#,
            #"{"action":"close_page"}"#,
            #"{"action":"click","page_id":8}"#,
            #"{"action":"click","background":true}"#,
            #"{"action":"call","mcp_tool":"new_page"}"#,
            #"{"action":"snapshot","mcp_tool":"evaluate_script"}"#,
        ] {
            #expect(throws: (any Error).self) {
                try BrowserCommandStream.arguments(from: Data(input.utf8), pageID: 7)
            }
        }
    }

    @Test
    func acceptsOnlyBatchRawToolsAndRejectsOversizedRequests() throws {
        for tool in [
            "navigate_page", "take_snapshot", "evaluate_script", "press_key", "type_text", "wait_for",
            "peekaboo_locator_action", "upload_file",
        ] {
            let input = try JSONSerialization.data(withJSONObject: ["action": "call", "mcp_tool": tool])
            #expect(try BrowserCommandStream.arguments(from: input, pageID: 7)["mcp_tool"] as? String == tool)
        }
        #expect(throws: (any Error).self) {
            try BrowserCommandStream.arguments(
                from: Data(repeating: 32, count: BrowserCommandStream.maximumLineBytes + 1), pageID: 7
            )
        }
    }

    @Test
    func lineReaderRetainsBufferedMessagesAndRejectsPartialEOF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first\nsecond\npartial".utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reader = BrowserCommandStream.Input(handle: handle)
        #expect(try reader.next() == Data("first".utf8))
        #expect(try reader.next() == Data("second".utf8))
        #expect(throws: (any Error).self) { try reader.next() }
    }
}
