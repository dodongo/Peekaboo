import Commander
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct TextSelectionRuntimeCapabilityTests {
    @Test
    func selectionRequiresVersionOperationAndAttestation() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []), commandType: SelectTextCommand.self
        )
        #expect(options.requiredElementActionOperations == [.selectText])
        for version in [38, 39] {
            for supported in [false, true] {
                for attested in [false, true] {
                    let handshake = BridgeTestFixtures.handshake(
                        negotiatedVersion: .init(major: 1, minor: version), hostKind: .gui, build: nil,
                        supportedOperations: supported ? [.selectText] : [],
                        hostCapabilities: attested ? [
                            PeekabooBridgeHostCapability.attestedOperationReceipts,
                            PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
                        ] : []
                    )
                    #expect(CommandRuntime.supportsElementAction(.selectText, for: handshake) ==
                        (version == 39 && supported && attested)
                    )
                }
            }
        }
    }
}
