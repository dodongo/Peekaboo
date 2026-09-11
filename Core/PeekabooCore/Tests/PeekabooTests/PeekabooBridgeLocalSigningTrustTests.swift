import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeLocalSigningTrustTests {
    private static let fingerprint = String(repeating: "a", count: 64)
    private static var policyJSON: String {
        "{\"version\":1,\"certificateSHA256\":\"\(self.fingerprint)\"}"
    }

    @Test
    func `private policy loads and admits only exact role and canonical host`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try PeekabooBridgeLocalSigningTrust.load(from: Self.writePolicy(in: directory))
        #expect(policy.certificateSHA256 == Self.fingerprint)
        #expect(policy.acceptsClient(
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier, certificateSHA256: Self.fingerprint))
        #expect(!policy.acceptsClient(bundleIdentifier: "boo.peekaboo.mac", certificateSHA256: Self.fingerprint))
        #expect(!policy.acceptsClient(
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier, certificateSHA256: nil))
        #expect(!policy.acceptsClient(
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            certificateSHA256: String(repeating: "b", count: 64)))
        #expect(policy.acceptsHost(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            bundleIdentifier: "boo.peekaboo.mac",
            certificateSHA256: Self.fingerprint))
        for path in [PeekabooBridgeConstants.daemonSocketPath, "/tmp/bridge.sock"] {
            #expect(!policy.acceptsHost(
                socketPath: path, bundleIdentifier: "boo.peekaboo.mac", certificateSHA256: Self.fingerprint))
        }
        #expect(!policy.acceptsHost(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            certificateSHA256: Self.fingerprint))
        #expect(!policy.acceptsHost(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            bundleIdentifier: "boo.peekaboo.mac",
            certificateSHA256: nil))
    }

    @Test(arguments: [
        "{}", "[]", "null", "not json",
        "{\"version\":true,\"certificateSHA256\":\"\(fingerprint)\"}",
        "{\"version\":2,\"certificateSHA256\":\"\(fingerprint)\"}",
        "{\"version\":1,\"certificateSHA256\":\"\(fingerprint)\",\"extra\":1}",
        "{\"version\":1,\"certificateSHA256\":\"\(fingerprint.uppercased())\"}",
        "{\"version\":1,\"certificateSHA256\":\"abc\"}",
        "{\"version\":1,\"certificateSHA256\":null}",
        "{\"version\":1,\"certificateSHA256\":\"\(String(repeating: "g", count: 64))\"}",
    ])
    func `invalid policy schema fails closed`(json: String) throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writePolicy(in: directory, json: json)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
    }

    @Test(arguments: [0o644, 0o660, 0o400, 0o1600])
    func `unsafe file modes fail closed`(mode: Int) throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writePolicy(in: directory)
        #expect(Darwin.chmod(file.path, mode_t(mode)) == 0)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
    }

    @Test(arguments: [0o755, 0o770, 0o1700])
    func `unsafe directory modes fail closed`(mode: Int) throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writePolicy(in: directory)
        #expect(Darwin.chmod(directory.path, mode_t(mode)) == 0)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
    }

    @Test
    func `missing oversized linked and nonregular policy files fail closed`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.json")
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: missing) }
        let file = try Self.writePolicy(in: directory, json: String(repeating: " ", count: 4097))
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
        try Data(Self.policyJSON.utf8).write(to: file)
        let linked = directory.appendingPathComponent("linked.json")
        try FileManager.default.linkItem(at: file, to: linked)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: linked) }
        let fifo = directory.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: fifo) }
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: directory) }
    }

    @Test
    func `symlink and writable ancestor directories fail closed`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = try Self.writePolicy(in: nested)
        let linked = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: nested)
        #expect(throws: (any Error).self) {
            try PeekabooBridgeLocalSigningTrust.load(from: linked.appendingPathComponent(file.lastPathComponent))
        }
        #expect(Darwin.chmod(directory.path, 0o770) == 0)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
    }

    @Test
    func `local requirement pins parsed leaf DER and exact identifier`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try Self.makeCertificate(in: directory)
        for identifier in [PeekabooBridgeConstants.cliBundleIdentifier, "boo.peekaboo.mac"] {
            let requirement = try #require(PeekabooBridgeCodeSignatureIdentity.localCertificateRequirement(
                identifier: identifier, certificateData: certificate))
            var source: CFString?
            #expect(SecRequirementCopyString(requirement, SecCSFlags(), &source) == errSecSuccess)
            let text = try #require(source as String?)
            let sha1 = Insecure.SHA1.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
            #expect(text.contains(identifier))
            #expect(text.lowercased().contains(sha1))
            #expect(!text.contains("anchor apple"))
        }
        for identifier in ["", "boo.peekaboo.impostor", #"boo.peekaboo.mac\" or true"#] {
            #expect(PeekabooBridgeCodeSignatureIdentity.localCertificateRequirement(
                identifier: identifier, certificateData: certificate) == nil)
        }
        #expect(PeekabooBridgeCodeSignatureIdentity.localCertificateRequirement(
            identifier: "boo.peekaboo.mac", certificateData: Data()) == nil)
    }

    @Test
    func `local metadata is accepted only with independent certificate and live hash binding`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificateData = try Self.makeCertificate(in: directory)
        let certificate = try #require(SecCertificateCreateWithData(nil, certificateData as CFData))
        let pin = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
        let hash = Data(repeating: 0xA5, count: 20)
        let key = PeekabooBridgeCodeSignatureIdentity.validatedLocalCertificateSHA256Key
        let metadata: [String: Any] = [
            kSecCodeInfoIdentifier as String: PeekabooBridgeConstants.cliBundleIdentifier,
            kSecCodeInfoUnique as String: hash,
            kSecCodeInfoCertificates as String: [certificate],
            key: "unvalidated spoof",
        ]
        let validated = PeekabooBridgeCodeSignatureIdentity.ValidatedSigningIdentity(
            identifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: nil,
            codeDirectoryHash: hash,
            localCertificateSHA256: pin)
        let result = try Self.validate(metadata: metadata, validated: validated, hashes: [hash, hash])
        #expect(result?[key] as? String == pin)
        #expect(result?[kSecCodeInfoTeamIdentifier as String] == nil)
        #expect(try Self.validate(metadata: metadata, validated: nil, hashes: [hash, hash]) == nil)
        #expect(try Self.validate(
            metadata: metadata,
            validated: validated,
            hashes: [hash, Data(repeating: 0xB5, count: 20)]) == nil)
        for identity in [
            PeekabooBridgeCodeSignatureIdentity.ValidatedSigningIdentity(
                identifier: validated.identifier, teamIdentifier: nil, codeDirectoryHash: hash),
            .init(
                identifier: validated.identifier,
                teamIdentifier: nil,
                codeDirectoryHash: hash,
                localCertificateSHA256: Self.fingerprint),
            .init(
                identifier: "boo.peekaboo.mac",
                teamIdentifier: nil,
                codeDirectoryHash: hash,
                localCertificateSHA256: pin),
            .init(
                identifier: validated.identifier,
                teamIdentifier: nil,
                codeDirectoryHash: Data(repeating: 1, count: 20),
                localCertificateSHA256: pin),
        ] {
            #expect(try Self.validate(metadata: metadata, validated: identity, hashes: [hash, hash]) == nil)
        }
        var unbound = metadata
        unbound.removeValue(forKey: kSecCodeInfoCertificates as String)
        #expect(try Self.validate(metadata: unbound, validated: validated, hashes: [hash, hash]) == nil)
        unbound = metadata
        unbound[kSecCodeInfoTeamIdentifier as String] = "SPOOFEDTEAM"
        #expect(try Self.validate(metadata: unbound, validated: validated, hashes: [hash, hash]) == nil)

        var appleMetadata = metadata
        appleMetadata[kSecCodeInfoTeamIdentifier as String] = "FWJYW4S8P8"
        let appleIdentity = PeekabooBridgeCodeSignatureIdentity.ValidatedSigningIdentity(
            identifier: validated.identifier, teamIdentifier: "FWJYW4S8P8", codeDirectoryHash: hash)
        let appleResult = try #require(try Self.validate(
            metadata: appleMetadata, validated: appleIdentity, hashes: [hash, hash]))
        #expect(appleResult[key] == nil)
    }

    private static func validate(
        metadata: [String: Any],
        validated: PeekabooBridgeCodeSignatureIdentity.ValidatedSigningIdentity?,
        hashes: [Data]) throws -> [String: Any]?
    {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { for fd in sockets {
            close(fd)
        } }
        let audit = try PeekabooBridgeSocketIO.peerAuditIdentity(fd: sockets[0])
        var index = 0
        return PeekabooBridgeCodeSignatureIdentity.signingInformation(
            auditIdentity: audit,
            systemCall: { _, _, address, size, _ in
                guard let address, index < hashes.count, size == hashes[index].count else { return -1 }
                hashes[index].copyBytes(to: address.assumingMemoryBound(to: UInt8.self), count: size)
                index += 1
                return 0
            },
            staticSigningInformationProvider: { _ in metadata },
            anchoredSignatureValidationProvider: { _ in validated })
    }

    @Test(arguments: ["file", "directory", "ancestor", "inherited"])
    func `extended ACL grants cannot bypass private POSIX modes`(target: String) throws {
        let root = try Self.makeDirectory()
        defer {
            try? Self.chmod(["-RN", root.path])
            try? FileManager.default.removeItem(at: root)
        }
        if target == "inherited" {
            try Self.chmod(["+a", "everyone allow read,write,file_inherit,directory_inherit", root.path])
        }
        let directory = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = try Self.writePolicy(in: directory)
        if target != "inherited" {
            let path = target == "file" ? file.path : (target == "directory" ? directory.path : root.path)
            try Self.chmod(["+a", "everyone allow read,write", path])
        }
        try Self.chmod(["600", file.path])
        try Self.chmod(["700", directory.path])
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.load(from: file) }
    }

    @Test
    func `deny only ancestor ACLs preserve private policy access`() throws {
        let root = try Self.makeDirectory()
        defer {
            try? Self.chmod(["-RN", root.path])
            try? FileManager.default.removeItem(at: root)
        }
        let directory = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = try Self.writePolicy(in: directory)
        try Self.chmod(["+a", "everyone deny delete", root.path])
        #expect(try PeekabooBridgeLocalSigningTrust.load(from: file).certificateSHA256 == Self.fingerprint)
    }

    @Test
    func `ACL inspection failures reject the descriptor`() {
        #expect(throws: (any Error).self) { try PeekabooBridgeLocalSigningTrust.validatePrivateACL(of: -1) }
    }

    private static func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private static func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/local-signing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func writePolicy(in directory: URL, json: String = policyJSON) throws -> URL {
        let file = directory.appendingPathComponent("bridge-trust.json")
        try Data(json.utf8).write(to: file)
        #expect(Darwin.chmod(file.path, 0o600) == 0)
        return file
    }

    private static func makeCertificate(in directory: URL) throws -> Data {
        let certificate = directory.appendingPathComponent("certificate.der")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=Peekaboo Test Only",
            "-outform",
            "DER",
            "-out",
            certificate.path,
            "-keyout",
            directory.appendingPathComponent("key.pem").path,
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try Data(contentsOf: certificate)
    }
}
