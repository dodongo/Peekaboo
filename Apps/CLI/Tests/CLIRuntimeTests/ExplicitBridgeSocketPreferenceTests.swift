import Commander
import Testing
@testable import PeekabooCLI

struct ExplicitBridgeSocketPreferenceTests {
    @Test(arguments: ["flag", "environment"])
    func `verify honors explicit bridge socket instead of preferring local execution`(source: String) throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: source == "flag" ? ["bridge-socket": ["/tmp/explicit-host.sock"]] : [:],
                flags: []),
            commandType: VerifyCommand.self,
            environment: source == "environment" ? ["PEEKABOO_BRIDGE_SOCKET": "/tmp/explicit-host.sock"] : [:])

        #expect(options.preferRemote)
        #expect(!CommandRuntime.shouldAutoStartDaemon(
            options: options,
            environment: source == "environment" ? ["PEEKABOO_BRIDGE_SOCKET": "/tmp/explicit-host.sock"] : [:]))
    }

    @Test
    func `verify defaults to local execution without a configured socket`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: VerifyCommand.self,
            environment: [:])

        #expect(!options.preferRemote)
    }

    @Test
    func `explicit no remote still wins over configured socket`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["no-remote"]),
            commandType: VerifyCommand.self,
            environment: ["PEEKABOO_BRIDGE_SOCKET": "/tmp/explicit-host.sock"])

        #expect(!options.preferRemote)
        #expect(options.remoteIsolationRequested)
    }
}
