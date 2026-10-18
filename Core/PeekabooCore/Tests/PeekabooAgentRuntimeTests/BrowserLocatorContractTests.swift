import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct BrowserLocatorContractTests {
    @Test
    func locatorActionUsesExplicitPageAndMutationAuthority() throws {
        let call = try BrowserMCPCallMapper.mapRawCall(arguments: ToolArguments(raw: [
            "mcp_tool": "peekaboo_locator_action",
            "page_id": 7,
            "mcp_args_json": #"{"query":{"css":"button"},"action":"click","pageId":99}"#,
        ]))
        #expect(call.arguments["pageId"] as? Int == 7)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: call.toolName, arguments: call.arguments) == .mutating)
        #expect(BrowserMCPUserActivationPolicy.decision(for: call).requiresForegroundAuthority)
        let contract = try #require(BrowserMCPPageRoutingContract.capabilityContract(
            for: call.toolName, arguments: ["includeSnapshot": true]))
        #expect(contract.effect == .invalidateSnapshot)
        #expect(contract.responseProjection == .snapshotWhen(true))
        #expect(contract.elementInputs.isEmpty)
    }

    @Test
    func locatorActionWithoutPageFailsBeforeDispatch() {
        #expect(throws: (any Error).self) {
            try BrowserMCPCallMapper.mapRawCall(arguments: ToolArguments(raw: [
                "mcp_tool": "peekaboo_locator_action",
                "mcp_args_json": #"{"query":{"css":"button"},"action":"click"}"#,
            ]))
        }
    }
}
