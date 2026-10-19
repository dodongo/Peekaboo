import Commander
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI

@MainActor
struct BrowserCommandStableDOMWaitTests {
    private func command(_ action: String, flags: Set<String>) throws -> BrowserCommand {
        try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: [action],
                options: ["pageId": ["3"], "uid": ["3_1"], "toUid": ["3_2"], "value": ["v"], "key": ["Enter"]],
                flags: flags.union(["foreground"])
            )
        )
    }

    @Test(arguments: ["click", "fill", "hover", "press-key"])
    func `Browser no-wait-for-stable-dom flag reaches every provider call`(action: String) throws {
        let arguments = try self.command(action, flags: ["noWaitForStableDom"]).arguments()
        #expect(arguments["wait_for_stable_dom"] as? Bool == false)
        let browserAction = try #require(BrowserAction(rawValue: action.replacingOccurrences(of: "-", with: "_")))
        let calls = try BrowserMCPCallMapper.mapSequence(
            action: browserAction,
            arguments: ToolArguments(raw: arguments)
        )
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.arguments["waitForStableDom"] as? Bool == false })
    }

    @Test(arguments: ["click", "fill", "hover", "press-key"])
    func `Browser actions keep the stable-DOM wait without the flag`(action: String) throws {
        let arguments = try self.command(action, flags: []).arguments()
        #expect(arguments["wait_for_stable_dom"] == nil)
        let browserAction = try #require(BrowserAction(rawValue: action.replacingOccurrences(of: "-", with: "_")))
        let calls = try BrowserMCPCallMapper.mapSequence(
            action: browserAction,
            arguments: ToolArguments(raw: arguments)
        )
        #expect(calls.allSatisfy { $0.arguments["waitForStableDom"] == nil })
    }

    @Test(arguments: ["drag", "type", "snapshot", "navigate", "dom-click", "upload-file", "call"])
    func `Browser no-wait-for-stable-dom flag is rejected on other actions`(action: String) throws {
        let command = try self.command(action, flags: ["noWaitForStableDom"])
        #expect(throws: ValidationError.self) { try command.validateBeforeRuntime() }
    }

    @Test
    func `Browser help documents the no-wait-for-stable-dom flag`() {
        #expect(BrowserCommand.helpMessage().contains("--no-wait-for-stable-dom"))
    }
}
