import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@MainActor
struct SeeMutationTargetingTests {
    @Test
    func `process only observation does not advertise mutation targeting`() {
        let context = self.context(window: WindowContext(
            applicationName: "UserNotificationCenter",
            applicationProcessId: 2257,
            applicationProcessStartIdentity: 123
        ))

        #expect(context.snapshotReusable)
        #expect(!context.mutationTargetingAvailable)
    }

    @Test
    func `window ID without captured identity does not advertise mutation targeting`() {
        let context = self.context(window: WindowContext(
            applicationProcessId: 2257,
            applicationProcessStartIdentity: 123,
            windowID: 170,
            windowBounds: CGRect(x: 626, y: 178, width: 260, height: 234)
        ))

        #expect(!context.mutationTargetingAvailable)
    }

    @Test
    func `untitled window with complete identity advertises mutation targeting`() {
        let bounds = CGRect(x: 626, y: 178, width: 260, height: 234)
        let identity = WindowMutationIdentity(
            windowID: 170,
            ownerProcessIdentifier: 2257,
            ownerProcessStartIdentity: 123,
            capturedBounds: bounds
        )
        let context = self.context(window: WindowContext(
            applicationProcessId: 2257,
            applicationProcessStartIdentity: 123,
            windowTitle: "",
            windowID: 170,
            windowBounds: bounds,
            windowMutationIdentity: identity
        ))

        #expect(context.mutationTargetingAvailable)
    }

    @Test
    func `conflicting window identity does not advertise mutation targeting`() {
        let bounds = CGRect(x: 626, y: 178, width: 260, height: 234)
        let context = self.context(window: WindowContext(
            applicationProcessId: 2257,
            applicationProcessStartIdentity: 123,
            windowID: 170,
            windowBounds: bounds,
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 171,
                ownerProcessIdentifier: 2257,
                ownerProcessStartIdentity: 123,
                capturedBounds: bounds
            )
        ))

        #expect(!context.mutationTargetingAvailable)
    }

    private func context(window: WindowContext) -> SeeCommandRenderContext {
        SeeCommandRenderContext(
            snapshotId: "permission-dialog",
            screenshotPath: "",
            screenshotData: nil,
            annotatedPath: nil,
            annotatedData: nil,
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "accessibility",
                windowContext: window,
                isDialog: true
            ),
            elements: DetectedElements(),
            coordinateContext: nil,
            analysis: nil,
            executionTime: 0,
            observation: nil,
            menuBar: nil,
            receipt: .none
        )
    }
}
