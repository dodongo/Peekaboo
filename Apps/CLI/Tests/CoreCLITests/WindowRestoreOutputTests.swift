import CoreGraphics
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct WindowRestoreOutputTests {
    private var original: ServiceWindowInfo {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        return ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: bounds,
            isMinimized: true,
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: bounds,
                isMinimized: true
            )
        )
    }

    @Test
    func `transient post-restore inventory failure preserves successful output`() async {
        let selected = await restoredWindowOutputInfo(original: self.original) {
            throw PeekabooError.windowNotFound(criteria: "windowId 101")
        }

        #expect(selected == self.original)
    }

    @Test
    func `exact restore readback treats a briefly missing window as the verified original`() async throws {
        let local = try await validatedRestoredWindowOutputInfo(original: self.original) {
            throw PeekabooError.windowNotFound(criteria: "windowId 101")
        }
        let bridged = try await validatedRestoredWindowOutputInfo(original: self.original) {
            throw PeekabooBridgeErrorEnvelope(
                code: .notFound,
                message: "Window not found: windowId 101",
                kind: .windowNotFound
            )
        }

        #expect(local == self.original)
        #expect(bridged == self.original)
    }

    @Test
    func `exact restore readback still fails on other refresh errors`() async {
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await validatedRestoredWindowOutputInfo(original: self.original) {
                throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "inventory failed")
            }
        }
    }

    @Test
    func `matching post-restore identity replaces stale display metadata within tolerance`() async {
        let restoredBounds = CGRect(x: 10.5, y: 19.5, width: 640.5, height: 479.5)
        let refreshed = ServiceWindowInfo(
            windowID: 101,
            title: "Restored Fixture",
            bounds: restoredBounds,
            isMinimized: false,
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: restoredBounds,
                isMinimized: false
            )
        )

        let selected = await restoredWindowOutputInfo(original: self.original) { refreshed }

        #expect(selected == refreshed)
    }

    @Test
    func `Dock thumbnail refresh never replaces verified restored bounds`() async {
        let thumbnailBounds = CGRect(x: 1694, y: 1039, width: 40, height: 81)
        let thumbnail = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: thumbnailBounds,
            isMinimized: false,
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: thumbnailBounds,
                isMinimized: false
            )
        )

        let selected = await restoredWindowOutputInfo(original: self.original) { thumbnail }

        #expect(selected == self.original)
    }

    @Test
    func `changed owner generation never replaces verified restored identity`() async {
        let replacement = ServiceWindowInfo(
            windowID: 101,
            title: "Replacement",
            bounds: self.original.bounds,
            isMinimized: false,
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 8,
                capturedBounds: self.original.bounds,
                isMinimized: false
            )
        )

        let selected = await restoredWindowOutputInfo(original: self.original) { replacement }

        #expect(selected == self.original)
    }

    @Test
    func `unverified original receipt omits restore bounds honestly`() async {
        let unverified = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: self.original.bounds,
            isMinimized: true
        )

        let selected = await restoredWindowOutputInfo(original: unverified) { self.original }

        #expect(selected == nil)
    }

    @Test
    func `idempotent visible restore retains its verified original receipt`() async {
        let visible = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: self.original.bounds,
            isMinimized: false,
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: self.original.bounds,
                isMinimized: false
            )
        )

        let selected = await restoredWindowOutputInfo(original: visible) { nil }

        #expect(selected == visible)
    }
}
