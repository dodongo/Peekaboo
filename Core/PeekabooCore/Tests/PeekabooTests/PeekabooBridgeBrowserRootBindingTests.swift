import Darwin
import Foundation
import PeekabooAgentRuntime
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
struct PeekabooBridgeBrowserRootBindingTests {
    @Test(arguments: [false, true])
    func boundReadSkipsStatusAndVerifiesReturnedEpoch(mismatchedEpoch: Bool) async throws {
        let socketPath = "/tmp/peekaboo-root-binding-\(UUID().uuidString).sock"
        let services = StubServices()
        let receipt = PeekabooBridgeBrowserClientTests.browserReceipt
        let epoch = UUID()
        services.browserConnectionReceipt = receipt
        services.browserProviderSessionEpoch = mismatchedEpoch ? UUID() : epoch
        services.browserStatusError = CancellationError() // Any redundant status call fails this test.
        let server = PeekabooBridgeServer(
            services: services, hostKind: .gui, allowlistedTeams: [], allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath, server: server, allowedTeamIDs: [], requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.root-binding", teamIdentifier: nil, processIdentifier: getpid()))
        let remote = RemoteBrowserMCPClient(client: client)
        #expect(await remote.supportsRootSessionBinding())
        let binding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: PeekabooServices.browserReceipt(from: receipt),
            providerSessionEpoch: .init(rawValue: epoch))
        do {
            _ = try await remote.executeSequenceWithOutcome(
                [.init(toolName: "list_pages", arguments: [:])],
                channel: .stable,
                expectedSessionBinding: binding,
                elementPreflight: nil)
            #expect(!mismatchedEpoch)
        } catch let failure as DesktopActionFailure {
            #expect(mismatchedEpoch)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
        }
        #expect(services.lastBrowserExecute?.sessionID == nil)
        #expect(services.lastBrowserExecute?.expectedProviderSessionEpoch == epoch)
        #expect(services.lastExpectedBrowserConnectionReceipt == receipt)
        if !mismatchedEpoch {
            let context = MCPToolContext(services: PeekabooServices(), executionPolicy: .unrestricted)
            let tool = BrowserTool(
                context: context,
                client: remote,
                instructionAudience: .commandLine,
                commandLineSessionBinding: binding)
            let response = try await tool.execute(arguments: ToolArguments(raw: [
                "action": "call", "mcp_tool": "take_snapshot", "page_id": 7, "background": false,
                "mcp_args_json": #"{"filePath":"/tmp/root-binding-fixture.txt"}"#,
            ]))
            #expect(!response.isError)
            #expect(services.lastBrowserExecute?.resolvedCalls.last?.arguments["filePath"] ==
                .string("/tmp/root-binding-fixture.txt"))
            #expect(services.lastBrowserExecute?.expectedProviderSessionEpoch == epoch)
        }
    }

    @Test
    func unnegotiatedHostRejectsRootEpochBeforeTransport() async throws {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/root-binding.sock")
        #expect(await !client.browserRootSessionBindingEnabled)
        do {
            _ = try await client.browserExecuteResult(.init(
                toolName: "list_pages",
                arguments: [:],
                expectedConnectionReceipt: PeekabooBridgeBrowserClientTests.browserReceipt,
                connectionPolicy: .requireExistingLiveReceipt,
                expectedProviderSessionEpoch: UUID()))
            Issue.record("Expected runtime compatibility refusal before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
    }
}
