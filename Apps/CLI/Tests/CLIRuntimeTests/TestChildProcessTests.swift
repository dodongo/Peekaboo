import Foundation
import Testing

struct TestChildProcessTests {
    @Test
    func `child tests use current SwiftPM output and refuse stale architecture binaries`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for relativePath in [
            ".build/arm64-apple-macosx/debug/peekaboo",
            ".build/x86_64-apple-macosx/debug/peekaboo",
            ".build/out/Products/Debug/peekaboo",
        ] {
            let binary = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: binary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        #expect(throws: RuntimeError.self) {
            try TestChildProcess.debugBinaryURL(packageRoot: root)
        }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(".build/debug").path,
            withDestinationPath: "out/Products/Debug"
        )
        let selected = try TestChildProcess.debugBinaryURL(packageRoot: root)
        #expect(selected.resolvingSymlinksInPath() ==
            root.appendingPathComponent(".build/out/Products/Debug/peekaboo").resolvingSymlinksInPath())
    }
}
