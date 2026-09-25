import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

enum TestChildProcess {
    struct Result {
        let standardOutput: String
        let standardError: String
        let status: TerminationStatus
    }

    static func runPeekaboo(
        _ arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        executablePathOverride: String? = nil,
        workingDirectory: URL? = nil,
        standardInput: String? = nil,
        isolateFromRemoteHosts: Bool = true
    ) async throws -> Result {
        let binaryURL = try Self.peekabooBinaryURL()
        var environmentOverrides: [Environment.Key: String?] = [:]

        // Keep CLI runtime smoke tests deterministic: avoid opportunistically switching to
        // a remote GUI runtime when a bridge socket happens to exist on the machine.
        if let envKey = Environment.Key(rawValue: "PEEKABOO_NO_REMOTE") {
            if isolateFromRemoteHosts, extraEnvironment["PEEKABOO_NO_REMOTE"] == nil {
                environmentOverrides[envKey] = "1"
            } else if !isolateFromRemoteHosts {
                environmentOverrides[envKey] = nil
            }
        }

        for (key, value) in extraEnvironment {
            if let envKey = Environment.Key(rawValue: key) {
                environmentOverrides[envKey] = value
            }
        }
        let environment = Environment.inherit.updating(environmentOverrides)

        if let standardInput {
            let collected = try await Subprocess.run(
                .path(FilePath(binaryURL.path)),
                arguments: Arguments(
                    executablePathOverride: executablePathOverride,
                    remainingValues: arguments
                ),
                environment: environment,
                workingDirectory: workingDirectory.map { FilePath($0.path) },
                input: .string(standardInput, using: UTF8.self),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )
            return Result(
                standardOutput: collected.standardOutput,
                standardError: collected.standardError,
                status: collected.terminationStatus
            )
        }

        let collected = try await Subprocess.run(
            .path(FilePath(binaryURL.path)),
            arguments: Arguments(
                executablePathOverride: executablePathOverride,
                remainingValues: arguments
            ),
            environment: environment,
            workingDirectory: workingDirectory.map { FilePath($0.path) },
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        return Result(
            standardOutput: collected.standardOutput,
            standardError: collected.standardError,
            status: collected.terminationStatus
        )
    }

    static func peekabooBinaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PEEKABOO_CLI_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return try Self.debugBinaryURL(packageRoot: Self.packageRootURL())
    }

    static func debugBinaryURL(packageRoot: URL) throws -> URL {
        let binary = packageRoot.appendingPathComponent(".build/debug/peekaboo")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw RuntimeError("Unable to locate current debug peekaboo binary at \(binary.path)")
        }
        return binary
    }

    static func canLocatePeekabooBinary() -> Bool {
        (try? self.peekabooBinaryURL()) != nil
    }

    private static func packageRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Apps/CLI/Tests/CLIRuntimeTests/Support/TestChildProcess.swift
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var description: String {
        self.message
    }
}
