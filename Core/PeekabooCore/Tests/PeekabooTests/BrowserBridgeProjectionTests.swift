import Foundation
import PeekabooAgentRuntime
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct BrowserBridgeProjectionTests {
    @Test
    func numericLocatorArgumentsRemainNumbers() throws {
        let data = Data(#"{"query":{"nth":0},"index":1,"enabled":true,"disabled":false,"fraction":0.5}"#.utf8)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let projected = try PeekabooBridgeJSONValue.fromAny(decoded)
        #expect(projected == .object([
            "query": .object(["nth": .int(0)]), "index": .int(1),
            "enabled": .bool(true), "disabled": .bool(false), "fraction": .double(0.5),
        ]))
        #expect(try PeekabooBridgeJSONValue.fromAny(0) == .int(0))
        #expect(try PeekabooBridgeJSONValue.fromAny(false) == .bool(false))
    }

    @Test
    @MainActor
    func providerFeaturesSurviveBridgeEncoding() throws {
        let source = BrowserMCPStatus(
            isConnected: true, toolCount: 31,
            providerFeatures: ["locator:role", "locator:refinements"], detectedBrowsers: [])
        let projected = PeekabooServices.bridgeStatus(from: source)
        let encoded = try JSONEncoder().encode(projected)
        let decoded = try JSONDecoder().decode(PeekabooBridgeBrowserStatus.self, from: encoded)
        #expect(decoded.providerFeatures == source.providerFeatures)
        let legacy = Data(#"{"isConnected":false,"toolCount":0,"detectedBrowsers":[]}"#.utf8)
        #expect(try JSONDecoder().decode(PeekabooBridgeBrowserStatus.self, from: legacy).providerFeatures == nil)
    }

    @Test
    func olderClientsReceiveOnlyDigestCompatibleFields() throws {
        let status = PeekabooBridgeBrowserStatus(
            isConnected: true, toolCount: 31, providerFeatures: ["locator:role"], detectedBrowsers: [])
        let response = PeekabooBridgeResponse.browserStatus(status)
        let legacy = response.projectingBrowserFeatures(for: .init(major: 1, minor: 38))
        let current = response.projectingBrowserFeatures(for: .init(major: 1, minor: 39))
        let encoder = JSONEncoder()
        let legacyJSON = try String(decoding: encoder.encode(legacy), as: UTF8.self)
        let currentJSON = try String(decoding: encoder.encode(current), as: UTF8.self)
        #expect(!legacyJSON.contains("providerFeatures"))
        #expect(currentJSON.contains("providerFeatures"))
        guard case let .browserStatus(projected) = legacy else {
            Issue.record("Expected browser status")
            return
        }
        #expect(projected.isConnected && projected.toolCount == 31)
        #expect(projected.providerFeatures == nil)
    }
}
