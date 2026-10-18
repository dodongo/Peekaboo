import Darwin
import Foundation

/// Private per-process storage for test runners, so tests never read or write the account's live
/// Peekaboo state even when a parallel test restores a process-global override early.
public enum TestRunnerStorage {
    /// Process names of the XCTest and Swift Testing runners that `swift test` and Xcode launch.
    public static let runnerProcessNames: Set<String> = ["xctest", "swiftpm-testing-helper", "swiftpm-xctest-helper"]

    /// The private root for this test runner process, or nil outside a test runner.
    public static let rootURL: URL? = {
        guard runnerProcessNames.contains(ProcessInfo.processInfo.processName) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let temporaryDirectory = length > 0 && length <= buffer.count
            ? URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            : URL(fileURLWithPath: "/var/empty", isDirectory: true)
        return temporaryDirectory
            .appendingPathComponent("peekaboo-test-runner-\(getpid())", isDirectory: true)
            .standardizedFileURL
    }()
}
