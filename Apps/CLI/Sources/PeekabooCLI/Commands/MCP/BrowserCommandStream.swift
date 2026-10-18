import Commander
import Darwin
import Foundation
import PeekabooCore
import TachikomaMCP

/// A bounded stream of ordinary CLI browser calls, bound to one requested page.
/// This does not create an MCP server or borrow another caller's scoped session.
enum BrowserCommandStream {
    static let maximumRequests = 256
    static let maximumLineBytes = 1_048_576
    static let actions: Set<String> = ["snapshot", "click", "fill", "fill_form", "hover", "call"]
    static let rawTools: Set<String> = [
        "navigate_page", "take_snapshot", "evaluate_script", "press_key", "type_text", "wait_for",
        "peekaboo_locator_action", "upload_file",
    ]

    static func arguments(from line: Data, pageID: Int) throws -> [String: Any] {
        guard !line.isEmpty, line.count <= self.maximumLineBytes,
              let input = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let action = input["action"] as? String, self.actions.contains(action)
        else { throw ValidationError("Invalid browser stream request") }
        let allowed: Set<String> = [
            "action", "uid", "value", "include_snapshot", "mcp_tool", "mcp_args_json",
        ]
        guard Set(input.keys).isSubset(of: allowed) else {
            throw ValidationError("Browser stream cannot change page, channel, connection, or execution policy")
        }
        if action == "call" {
            guard let tool = input["mcp_tool"] as? String, self.rawTools.contains(tool) else {
                throw ValidationError("Unsupported raw browser stream tool")
            }
        } else if input["mcp_tool"] != nil {
            throw ValidationError("mcp_tool requires action call")
        }
        var arguments = input
        arguments["page_id"] = pageID
        arguments["background"] = false
        return arguments
    }

    static func readyMessage(features: [String]?) throws -> Data {
        var message: [String: Any] = ["ready": true, "protocol": "peekaboo-browser-stream-1"]
        if let features { message["features"] = features }
        var encoded = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        encoded.append(10)
        return encoded
    }

    struct Input {
        var buffer = Data()
        let handle: FileHandle

        mutating func next() throws -> Data? {
            while true {
                if let end = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<end])
                    self.buffer.removeSubrange(...end)
                    guard line.count <= BrowserCommandStream.maximumLineBytes else {
                        throw ValidationError("Browser stream request exceeds byte limit")
                    }
                    return line
                }
                guard self.buffer.count <= BrowserCommandStream.maximumLineBytes else {
                    throw ValidationError("Browser stream request exceeds byte limit")
                }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let bytesRead = Darwin.read(self.handle.fileDescriptor, &bytes, bytes.count)
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard bytesRead > 0 else {
                    guard self.buffer.isEmpty else {
                        throw ValidationError("Browser stream ended with an incomplete request")
                    }
                    return nil
                }
                self.buffer.append(contentsOf: bytes.prefix(bytesRead))
            }
        }
    }
}

extension BrowserCommand {
    func validateStream() throws {
        guard self.foreground, self.runtimeOptions.jsonOutput, let pageID = self.pageId, pageID > 0,
              self.handoffFile == nil, self.channel == nil, self.browserUrl == nil
        else {
            throw ValidationError("browser stream requires --page-id, --foreground and --json; no connection options")
        }
    }

    func runStream(using runtime: CommandRuntime) async throws {
        try self.validateStream()
        guard let pageID = self.pageId else { throw ValidationError("Missing stream page ID") }
        let initial = await self.services.browser.status(channel: nil)
        guard initial.observation == .confirmed, initial.isConnected,
              let receipt = initial.connectionReceipt, let epoch = initial.providerSessionEpoch
        else { throw ValidationError("Browser stream requires an existing confirmed connection") }
        let context = MCPToolContext(
            services: self.services,
            snapshotMutationCoordinator: runtime.toolSnapshotMutationCoordinator,
            executionPolicy: self.toolExecutionPolicy,
            capturePreflightRefusal: runtime.toolCapturePreflightRefusal
        )
        let supportsAtomicBinding = if let remote = self.services.browser as? RemoteBrowserMCPClient {
            await remote.supportsRootSessionBinding()
        } else {
            false
        }
        let binding = BrowserMCPExecutionSessionBinding(connectionReceipt: receipt, providerSessionEpoch: epoch)
        let tool = BrowserTool(
            context: context,
            instructionAudience: .commandLine,
            commandLineSessionBinding: supportsAtomicBinding ? binding : nil
        )
        let output = FileHandle.standardOutput
        try output
            .write(contentsOf: BrowserCommandStream
                .readyMessage(features: (initial.providerFeatures ?? []) + ["stream:navigate", "stream:upload"])
            )
        var input = BrowserCommandStream.Input(handle: .standardInput)
        var count = 0
        while let line = try input.next() {
            count += 1
            guard count <= BrowserCommandStream.maximumRequests else {
                throw ValidationError("Browser stream request count exceeded")
            }
            let arguments = try BrowserCommandStream.arguments(from: line, pageID: pageID)
            if !supportsAtomicBinding {
                let current = await self.services.browser.status(channel: nil)
                guard current.observation == .confirmed, current.isConnected,
                      current.connectionReceipt == receipt, current.providerSessionEpoch == epoch
                else { throw ValidationError("Browser connection changed; stream stopped without replay") }
            }
            let response = try await context.execute(tool: tool, arguments: ToolArguments(raw: arguments))
            let envelope = MCPToolCommandOutput.envelope(tool: tool.name, response: response)
            var encoded = try JSONEncoder().encode(envelope)
            encoded.append(10)
            try output.write(contentsOf: encoded)
            guard !response.isError else { throw ExitCode(1) }
        }
    }
}
