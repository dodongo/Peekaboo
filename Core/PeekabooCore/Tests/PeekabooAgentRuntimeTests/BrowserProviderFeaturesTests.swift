import Foundation
import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserProviderFeaturesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PEEKABOO_PROVIDER_SCHEMA_FIXTURE"] != nil))
    func actualProviderWireSchemaProducesAllAdvertisedFeatures() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PEEKABOO_PROVIDER_SCHEMA_FIXTURE"])
        let tools = try JSONDecoder().decode([Tool].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(BrowserMCPProviderFeatures.detect(in: tools) == [
            "assets:capturedBundle", "clipboard:session", "export:workspace",
            "locator:check", "locator:click", "locator:clickOptions", "locator:commit", "locator:composition",
            "locator:copy", "locator:count",
            "locator:dblclick",
            "locator:descendants", "locator:enabledField", "locator:expectDownload", "locator:expectNavigation",
            "locator:fill",
            "locator:hover", "locator:nestedRole", "locator:paste", "locator:press", "locator:read", "locator:read-all",
            "locator:refinements", "locator:regex", "locator:role",
            "locator:select",
            "locator:text", "locator:type", "locator:uncheck", "locator:visibility", "locator:visibleField",
            "locator:wait",
            "read:skipNavigationWait", "upload:multiple", "wait:page",
        ])
    }

    @Test
    func multipleUploadsRequireAnAdvertisedStringArray() {
        for supported in [false, true] {
            let tool = Tool(name: "upload_file", description: "fixture", inputSchema: .object([
                "properties": .object(["filePaths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string(supported ? "string" : "number")]),
                ])]),
            ]))
            #expect(BrowserMCPProviderFeatures.detect(in: [tool]) == (supported ? ["upload:multiple"] : []))
        }
    }

    @Test
    func featuresFollowActualSchemaInsteadOfToolCount() {
        let locator = Tool(name: "peekaboo_locator_action", description: "fixture", inputSchema: .object([
            "properties": .object(["action": .object([
                "enum": .array([.string("fill"), .string("click"), .string("dblclick"), .string("future"), .int(7)]),
            ])]),
        ]))
        let script = Tool(name: "evaluate_script", description: "fixture", inputSchema: .object([
            "properties": .object([
                "skipNavigationWait": .object(["type": .string("boolean")]),
                "waitForStableDom": .object(["type": .string("boolean")]),
            ]),
        ]))
        #expect(BrowserMCPProviderFeatures.detect(in: [script, locator]) == [
            "locator:click", "locator:dblclick", "locator:fill", "read:skipNavigationWait",
        ])
        #expect(BrowserMCPProviderFeatures.detect(in: [
            Tool(name: "evaluate_script", description: "legacy", inputSchema: .object([:])),
            Tool(name: "peekaboo_locator_action", description: "malformed", inputSchema: .null),
        ]).isEmpty)
    }

    @Test
    func clickOptionsRequireAdvertisedButtonsAndModifiers() {
        let buttons = Value.object(["enum": .array([.string("left"), .string("right"), .string("middle")])])
        let modifiers = Value.object(["items": .object(["enum": .array([
            .string("Alt"), .string("Control"), .string("Meta"), .string("Shift"), .string("ControlOrMeta"),
        ])])])
        for complete in [false, true] {
            let tool = Tool(name: "peekaboo_locator_action", description: "fixture", inputSchema: .object([
                "properties": .object(["button": buttons, "modifiers": complete ? modifiers : .null]),
            ]))
            #expect(BrowserMCPProviderFeatures.detect(in: [tool]) == (complete ? ["locator:clickOptions"] : []))
        }
    }

    @Test
    func statusExposesOnlyConfirmedLiveCapabilities() async throws {
        for observation in [BrowserMCPStatusObservation.confirmed, .indeterminate] {
            for connected in [false, true] {
                let status = BrowserMCPStatus(
                    isConnected: connected,
                    toolCount: 31,
                    providerFeatures: ["locator:fill", "read:skipNavigationWait"],
                    detectedBrowsers: [],
                    observation: observation)
                let response = try await BrowserTool(
                    client: MockBrowserMCPClient(status: status), executionPolicy: .unrestricted)
                    .execute(arguments: ToolArguments(raw: ["action": "status"]))
                let features = response.meta?.objectValue?["provider_features"]
                if observation == .indeterminate {
                    #expect(features == .null)
                } else if connected {
                    #expect(features == .array([.string("locator:fill"), .string("read:skipNavigationWait")]))
                } else {
                    #expect(features == .array([]))
                }
            }
        }
    }

    @Test
    func oldConnectedHostsKeepUnknownFeaturesDistinctFromUnsupported() async throws {
        let response = try await BrowserTool(client: MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true, toolCount: 30, detectedBrowsers: [])), executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: ["action": "status"]))
        #expect(response.meta?.objectValue?["provider_features"] == .null)
    }
}
