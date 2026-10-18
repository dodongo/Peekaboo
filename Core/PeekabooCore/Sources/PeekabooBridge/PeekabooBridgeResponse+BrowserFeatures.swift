extension PeekabooBridgeResponse {
    /// Older clients re-encode decoded fields when checking the signed response digest.
    func projectingBrowserFeatures(for version: PeekabooBridgeProtocolVersion) -> Self {
        guard version < PeekabooBridgeConstants.browserProviderFeaturesVersion else { return self }
        switch self {
        case let .browserStatus(status):
            return .browserStatus(.init(
                isConnected: status.isConnected, toolCount: status.toolCount,
                detectedBrowsers: status.detectedBrowsers, connectionReceipt: status.connectionReceipt,
                error: status.error, providerSessionEpoch: status.providerSessionEpoch,
                observation: status.observation))
        case let .projectedAction(projected):
            return .projectedAction(.init(
                response: projected.response.projectingBrowserFeatures(for: version), outcome: projected.outcome))
        default:
            return self
        }
    }
}
