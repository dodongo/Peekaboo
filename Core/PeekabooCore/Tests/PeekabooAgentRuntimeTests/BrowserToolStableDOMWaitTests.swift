import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct BrowserToolStableDOMWaitTests {
    @Test(arguments: [BrowserAction.click, .fill, .hover, .pressKey])
    func `Browser mapper forwards the stable-DOM wait option to every provider call`(action: BrowserAction) throws {
        let raw: [String: Any] = ["page_id": 4, "uid": "4_1", "value": "value", "key": "Enter"]
        for wait in [false, true] {
            var arguments = raw
            arguments["wait_for_stable_dom"] = wait
            let calls = try BrowserMCPCallMapper.mapSequence(action: action, arguments: ToolArguments(raw: arguments))
            #expect(calls.count == (action == .pressKey ? 2 : 1))
            #expect(calls.allSatisfy { $0.arguments["waitForStableDom"] as? Bool == wait })
        }
        let calls = try BrowserMCPCallMapper.mapSequence(action: action, arguments: ToolArguments(raw: raw))
        #expect(calls.allSatisfy { $0.arguments["waitForStableDom"] == nil })
    }

    @Test(arguments: [BrowserAction.drag, .type, .uploadFile])
    func `Browser mapper keeps the stable-DOM wait for other actions`(action: BrowserAction) throws {
        let calls = try BrowserMCPCallMapper.mapSequence(action: action, arguments: ToolArguments(raw: [
            "page_id": 4, "uid": "4_1", "to_uid": "4_2", "text": "typed", "path": "/tmp/fixture",
            "wait_for_stable_dom": false,
        ]))
        #expect(calls.allSatisfy { $0.arguments["waitForStableDom"] == nil })
    }
}
