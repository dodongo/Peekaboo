import Darwin
import Foundation

enum PeekabooBridgeConnectedHostTrust {
    @discardableResult
    static func validate(
        _ host: PeekabooBridgeConnectedHostIdentity?,
        socketPath: String,
        trustedTeamIDs: Set<String>,
        hostKind: PeekabooBridgeHostKind? = nil,
        unsignedDaemonPolicy: PeekabooBridgeUnsignedDaemonPolicy = .init(),
        currentProcessIsReleaseSigned: () -> Bool = PeekabooBridgeSigningDiagnostics
            .currentProcessIsReleaseSigned,
        localSigningTrust: PeekabooBridgeLocalSigningTrust? = .current) throws -> PeekabooBridgeTrustMode
    {
        let failedCheck: String
        if let host {
            if let liveHash = host.liveIdentity.codeSignatureHash, !liveHash.isEmpty {
                if let signing = host.signingIdentity {
                    if signing.codeSignatureHash != liveHash {
                        failedCheck = "signed executable CDHash does not match the live socket peer"
                    } else if let team = signing.teamIdentifier, signing.localCertificateSHA256 == nil,
                              trustedTeamIDs.contains(team) {
                        return .releaseSignature
                    } else if signing.teamIdentifier == nil,
                              host.liveIdentity.effectiveUserIdentifier == geteuid(),
                              localSigningTrust?.acceptsHost(
                                  socketPath: socketPath,
                                  bundleIdentifier: signing.bundleIdentifier,
                                  certificateSHA256: signing.localCertificateSHA256) == true {
                        return .localCertificate
                    } else {
                        failedCheck = "signing Team ID is missing or not trusted"
                    }
                } else {
                    let reason = host.signingIdentityFailure.map { ": " + $0.localizedDescription } ?? ""
                    failedCheck = "Apple-anchored signing identity could not be bound to the live peer" + reason
                }
            } else {
                failedCheck = "live kernel CDHash is unavailable"
            }
        } else {
            failedCheck = "connected socket peer identity is unavailable"
        }
        if let host, unsignedDaemonPolicy.allows(host.liveIdentity, hostKind: hostKind),
           !currentProcessIsReleaseSigned()
        {
            return .unsignedSameBinaryDeveloperOptIn
        }
        let peer = host.map { " (PID \($0.liveIdentity.processIdentifier))" } ?? ""
        let message = "Bridge host authentication failed at '\(socketPath)'\(peer): \(failedCheck). " +
            "Relaunch the released signed host at this socket; if its executable was replaced, " +
            "stop the old host process and restart it from the current signed app or CLI. " +
            "Chrome approval and browser receipts have not been checked."
        var error = PeekabooBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: PeekabooBridgeSigningDiagnostics.appendingUnsignedBuildHint(
                to: message, currentProcessIsReleaseSigned: currentProcessIsReleaseSigned()),
            context: "connectedHostAuthentication")
        error.isLocalHostAuthenticationFailure = true
        throw error
    }
}
