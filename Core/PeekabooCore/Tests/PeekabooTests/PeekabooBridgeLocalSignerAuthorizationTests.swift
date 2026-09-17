import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeLocalSignerAuthorizationTests {
    private static let certificateSHA256 = String(repeating: "a", count: 64)

    @Test(arguments: [
        "valid", "unsigned", "missing-pin", "wrong-pin", "wrong-bundle", "wrong-hash",
        "wrong-user", "daemon", "third-party", "custom-socket", "claimed-team",
    ])
    func `local host requires the pinned GUI signer on its canonical socket`(variant: String) throws {
        let trust = try Self.trust()
        let live = try Self.liveIdentity(foreignUser: variant == "wrong-user")
        let hash = try #require(live.codeSignatureHash)
        let signingIdentity: PeekabooBridgeHost.PeerSigningIdentity? = variant == "unsigned" ? nil : .init(
            bundleIdentifier: variant == "wrong-bundle" ? PeekabooBridgeConstants
                .cliBundleIdentifier : "boo.peekaboo.mac",
            teamIdentifier: variant == "claimed-team" ? "FWJYW4S8P8" : nil,
            codeSignatureHash: variant == "wrong-hash" ? "wrong" : hash,
            localCertificateSHA256: variant == "wrong-pin" ? String(repeating: "b", count: 64) : Self.certificateSHA256)
        let socketPath = switch variant {
        case "daemon": PeekabooBridgeConstants.daemonSocketPath
        case "third-party": PeekabooBridgeConstants.claudeSocketPath
        case "custom-socket": "/tmp/custom-local-signer.sock"
        default: PeekabooBridgeConstants.peekabooSocketPath
        }
        #expect(PeekabooBridgeClient.isTrustedConnectedHost(
            .init(liveIdentity: live, signingIdentity: signingIdentity),
            liveCodeSignatureHash: hash,
            trustedHostTeamIDs: PeekabooBridgeConstants.trustedReleaseTeamIDs,
            socketPath: socketPath,
            localSigningTrust: variant == "missing-pin" ? nil : trust) == (variant == "valid"))
    }

    @Test(arguments: ["valid", "unsigned", "missing-pin", "wrong-pin", "wrong-bundle", "wrong-hash", "wrong-user"])
    func `local CLI authorization binds certificate role and kernel executable`(variant: String) throws {
        let trust = try Self.trust()
        let live = try Self.liveIdentity(foreignUser: variant == "wrong-user")
        let signingIdentity: PeekabooBridgeHost.PeerSigningIdentity? = variant == "unsigned" ? nil : .init(
            bundleIdentifier: variant == "wrong-bundle" ? "boo.peekaboo.mac" : PeekabooBridgeConstants
                .cliBundleIdentifier,
            teamIdentifier: nil,
            codeSignatureHash: variant == "wrong-hash" ? "wrong" : live.codeSignatureHash,
            localCertificateSHA256: variant == "wrong-pin" ? String(repeating: "b", count: 64) : Self.certificateSHA256)
        let peer = PeekabooBridgeHost.peerInfoIfAllowed(
            liveIdentity: live,
            allowedTeamIDs: PeekabooBridgeConstants.trustedReleaseTeamIDs,
            signingIdentityProvider: { _ in signingIdentity },
            allowUnsignedSocketClients: false,
            localSigningTrust: variant == "missing-pin" ? nil : trust)
        #expect((peer != nil) == (variant == "valid"))
        if let peer {
            #expect(peer.teamIdentifier == nil)
            #expect(peer.localCertificateSHA256 == Self.certificateSHA256)
            #expect(peer.liveIdentity == live)
        }
    }

    @Test
    func `release host trust does not depend on a local pin`() throws {
        let live = try Self.liveIdentity()
        let hash = try #require(live.codeSignatureHash)
        #expect(PeekabooBridgeClient.isTrustedConnectedHost(
            .init(liveIdentity: live, signingIdentity: .init(
                bundleIdentifier: "boo.peekaboo.mac",
                teamIdentifier: "FWJYW4S8P8",
                codeSignatureHash: hash)),
            liveCodeSignatureHash: hash,
            trustedHostTeamIDs: PeekabooBridgeConstants.trustedReleaseTeamIDs,
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            localSigningTrust: nil))
    }

    @Test
    func `browser caller keeps certificate provenance without fabricating an Apple team`() throws {
        let trust = try Self.trust()
        let live = try Self.liveIdentity()
        let caller = try Self.localPeer(live).browserSessionCaller(
            clientInstanceID: UUID(),
            localSigningTrust: trust)
        #expect(caller.teamIdentifier.isEmpty)
        #expect(caller.signer == .localCertificateSHA256(Self.certificateSHA256))
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try Self.localPeer(live).browserSessionCaller(clientInstanceID: UUID(), localSigningTrust: nil)
        }
        let unsigned = PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: nil)
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try unsigned.browserSessionCaller(clientInstanceID: UUID(), localSigningTrust: trust)
        }
    }

    @Test(arguments: ["valid", "wrong-pin", "missing-pin", "empty-team", "release-team", "wrong-hash", "wrong-user"])
    @MainActor
    func `browser handoff requires matching trusted signer provenance`(variant: String) throws {
        let trust = try Self.trust()
        let live = try Self.liveIdentity()
        let issuer = try Self.localPeer(live).browserSessionCaller(clientInstanceID: UUID(), localSigningTrust: trust)
        let signer: PeekabooBridgeBrowserSessionCaller.Signer = switch variant {
        case "wrong-pin": .localCertificateSHA256(String(repeating: "b", count: 64))
        case "empty-team": .releaseTeam("")
        case "release-team": .releaseTeam("FWJYW4S8P8")
        default: issuer.signer
        }
        let caller = PeekabooBridgeBrowserSessionCaller(
            operationClientInstanceID: UUID(),
            process: .init(
                processIdentifier: issuer.process.processIdentifier + 1,
                processStartIdentity: issuer.process.processStartIdentity + 1,
                codeSignatureHash: variant == "wrong-hash" ? "wrong" : issuer.process.codeSignatureHash),
            processIdentifierVersion: issuer.processIdentifierVersion + 1,
            effectiveUserIdentifier: variant == "wrong-user" ? geteuid() + 1 : geteuid(),
            bundleIdentifier: issuer.bundleIdentifier,
            signer: signer)
        #expect(PeekabooBridgeBrowserHandoffGrantRegistry.mayTransfer(
            from: issuer,
            to: caller,
            localSigningTrust: variant == "missing-pin" ? nil : trust) == (variant == "valid"))
    }

    @Test
    func `hot operation sessions preserve the cold certificate identity`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: root
            .appendingPathComponent("bridge.sock").path)
        let live = try Self.liveIdentity()
        let peer = Self.localPeer(live)
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let authorization = try #require(authority.authorizeSession(
            sessionID: session.attestation.sessionID,
            liveIdentity: live))
        defer { authorization.pin.release() }
        #expect(authorization.peer.localCertificateSHA256 == Self.certificateSHA256)
        #expect(authorization.peer.teamIdentifier == nil)
        let trust = try Self.trust()
        let caller = try authorization.peer.browserSessionCaller(
            clientInstanceID: session.clientInstanceID,
            localSigningTrust: trust)
        #expect(caller.signer == .localCertificateSHA256(Self.certificateSHA256))
        let alteredPeer = PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: peer.bundleIdentifier,
            teamIdentifier: nil,
            localCertificateSHA256: String(repeating: "b", count: 64))
        await #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try await authority.claim(
                session.request(authority: authority, sequence: 0, request: .permissionsStatus),
                peer: alteredPeer)
        }
        let accepted = try await session.acceptedClaim(authority: authority, sequence: 0, request: .permissionsStatus)
        authority.complete(accepted.claim)
    }

    @Test
    func `explicit team policy refuses local handshake without consulting the machine pin`() async throws {
        let trust = try Self.trust()
        let listener = try ScriptedBridgePeer(responses: [
            .error(.init(code: .versionMismatch, message: "Untrusted responses cannot trigger negotiation")),
        ])
        let client = PeekabooBridgeClient(
            socketPath: listener.socketPath,
            requestTimeoutSec: 1,
            trustedHostTeamIDs: PeekabooBridgeConstants.trustedReleaseTeamIDs,
            hostAuthentication: .init(
                signingIdentity: { audit in
                    .init(
                        bundleIdentifier: "boo.peekaboo.mac",
                        teamIdentifier: nil,
                        codeSignatureHash: PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: audit),
                        localCertificateSHA256: Self.certificateSHA256)
                },
                localSigningTrust: {
                    Issue.record("Explicit team policy must not consult local certificate trust")
                    return trust
                }))
        do {
            _ = try await client.handshake(client: .init(
                bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
                teamIdentifier: nil,
                processIdentifier: getpid()))
            Issue.record("Expected local signer refusal under explicit team policy")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .unauthorizedClient)
        } catch {
            await listener.stop()
            throw error
        }
        #expect(await listener.acceptedConnectionCount == 1)
        await listener.stop()
    }

    @Test
    @MainActor
    func `server local authorization honors pin removal without enabling certification`() throws {
        let server = Self.server()
        let peer = try Self.localPeer(Self.liveIdentity())
        try server.validatePeerAuthorization(peer, localSigningTrust: Self.trust())
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try server.validatePeerAuthorization(peer, localSigningTrust: nil)
        }
        let replacement = try Self.trust(certificateSHA256: String(repeating: "b", count: 64))
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try server.validatePeerAuthorization(peer, localSigningTrust: replacement)
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try server.requireCertificationCaller(peer)
        }
        let foreignBundle = try PeekabooBridgePeer(
            liveIdentity: Self.liveIdentity(),
            bundleIdentifier: "boo.peekaboo.mac",
            teamIdentifier: nil,
            localCertificateSHA256: Self.certificateSHA256)
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try server.validatePeerAuthorization(foreignBundle, localSigningTrust: Self.trust())
        }
    }

    @Test
    @MainActor
    func `handshake payload cannot supply a missing signing team or replace the verified bundle`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: root
            .appendingPathComponent("bridge.sock").path)
        let server = Self.server()
        let live = try Self.liveIdentity()
        let peer = Self.localPeer(live)
        try server.validatePeerAuthorization(peer, localSigningTrust: Self.trust())
        let response = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleHandshake(
                .init(
                    protocolVersion: PeekabooBridgeConstants.protocolVersion,
                    client: .init(
                        bundleIdentifier: "forged.bundle",
                        teamIdentifier: "FORGED",
                        processIdentifier: getpid()),
                    operationClientInstanceID: UUID()),
                peer: peer,
                permissions: .init(screenRecording: true, accessibility: true, postEvent: true))
        }
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected authenticated local handshake")
            return
        }
        #expect(!handshake.supportedOperations.contains(.certificationProducerAttestation))
        #expect(handshake.supportedOperations.contains(.permissionsStatus))
        let session = try #require(handshake.operationSessionAttestation)
        let authorized = try #require(authority.authorizeSession(sessionID: session.sessionID, liveIdentity: live))
        defer { authorized.pin.release() }
        #expect(authorized.peer.teamIdentifier == nil)
        #expect(authorized.peer.bundleIdentifier == PeekabooBridgeConstants.cliBundleIdentifier)
        #expect(authorized.peer.localCertificateSHA256 == Self.certificateSHA256)
        let caller = try authorized.peer.browserSessionCaller(clientInstanceID: UUID(), localSigningTrust: Self.trust())
        #expect(caller.signer == .localCertificateSHA256(Self.certificateSHA256))
    }

    @MainActor
    private static func server() -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: PeekabooBridgeConstants.trustedReleaseTeamIDs,
            allowlistedBundles: [PeekabooBridgeConstants.cliBundleIdentifier],
            permissionStatusEvaluator: { _ in
                .init(screenRecording: true, accessibility: true, postEvent: true)
            })
    }

    private static func localPeer(_ live: PeekabooBridgeLivePeerIdentity) -> PeekabooBridgePeer {
        PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: nil,
            localCertificateSHA256: self.certificateSHA256)
    }

    private static func liveIdentity(foreignUser: Bool = false) throws -> PeekabooBridgeLivePeerIdentity {
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        guard foreignUser else { return live }
        return PeekabooBridgeLivePeerIdentity(
            auditToken: live.auditToken,
            processIdentifier: live.processIdentifier,
            processIdentifierVersion: live.processIdentifierVersion,
            effectiveUserIdentifier: live.effectiveUserIdentifier + 1,
            processStartIdentity: live.processStartIdentity,
            codeSignatureHash: live.codeSignatureHash)
    }

    private static func trust(certificateSHA256: String = Self
        .certificateSHA256) throws -> PeekabooBridgeLocalSigningTrust
    {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/local-signer-authorization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bridge-trust.json")
        try Data("{\"version\":1,\"certificateSHA256\":\"\(certificateSHA256)\"}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try PeekabooBridgeLocalSigningTrust.load(from: file)
    }
}
