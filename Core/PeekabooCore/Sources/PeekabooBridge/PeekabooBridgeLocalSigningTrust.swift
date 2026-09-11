import Darwin
import Foundation
import OSLog

struct PeekabooBridgeLocalSigningTrust: Decodable, Equatable, Sendable {
    let certificateSHA256: String

    private enum PolicyError: Error {
        case missing
        case unsafeFile
        case invalidPolicy
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["version", "certificateSHA256"],
              try container.decode(Int.self, forKey: Key(stringValue: "version")) == 1
        else { throw PolicyError.invalidPolicy }
        let fingerprint = try container.decode(String.self, forKey: Key(stringValue: "certificateSHA256"))
        guard fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw PolicyError.invalidPolicy }
        self.certificateSHA256 = fingerprint
    }

    static var current: Self? {
        let url = URL(fileURLWithPath: PeekabooBridgeConstants.peekabooSocketPath)
            .deletingLastPathComponent().appendingPathComponent("bridge-trust.json")
        // An unprovisioned application directory need not yet have the policy's private permissions.
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT {
            return nil
        }
        do {
            return try self.load(from: url)
        } catch PolicyError.missing {
            return nil
        } catch {
            Logger(subsystem: "boo.peekaboo.bridge", category: "local-signing-trust")
                .error("Local bridge signing policy is invalid or insecure; local signature trust is disabled")
            return nil
        }
    }

    static func load(from url: URL) throws -> Self {
        guard url.isFileURL else { throw PolicyError.unsafeFile }
        let components = url.pathComponents
        guard components.first == "/", components.count > 2,
              !components.contains(".."), !components.contains(".")
        else { throw PolicyError.unsafeFile }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw PolicyError.unsafeFile }
        defer { close(directory) }
        try self.validatePrivateACL(of: directory)
        for (index, component) in components.dropFirst().dropLast().enumerated() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                if errno == ENOENT {
                    throw PolicyError.missing
                }
                throw PolicyError.unsafeFile
            }
            close(directory)
            directory = next
            var info = stat()
            guard fstat(directory, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid() || info.st_uid == 0,
                  info.st_mode & 0o022 == 0
            else { throw PolicyError.unsafeFile }
            try self.validatePrivateACL(of: directory)
            if index == components.count - 3 {
                guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
                    throw PolicyError.unsafeFile
                }
            }
        }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw PolicyError.missing
            }
            throw PolicyError.unsafeFile
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, self.isPrivatePolicyFile(before) else {
            throw PolicyError.unsafeFile
        }
        try self.validatePrivateACL(of: descriptor)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4097)
        while data.count <= 4096 {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw PolicyError.unsafeFile }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count <= 4096, data.count == before.st_size,
              fstat(descriptor, &after) == 0, self.isPrivatePolicyFile(after),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw PolicyError.unsafeFile }
        try self.validatePrivateACL(of: descriptor)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func acceptsClient(bundleIdentifier: String?, certificateSHA256: String?) -> Bool {
        bundleIdentifier == PeekabooBridgeConstants.cliBundleIdentifier && certificateSHA256 == self.certificateSHA256
    }

    func acceptsHost(socketPath: String, bundleIdentifier: String?, certificateSHA256: String?) -> Bool {
        socketPath == PeekabooBridgeConstants.peekabooSocketPath &&
            bundleIdentifier == "boo.peekaboo.mac" && certificateSHA256 == self.certificateSHA256
    }

    static func validatePrivateACL(of descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT for a valid descriptor without an extended ACL.
            guard errno == ENOENT else { throw PolicyError.unsafeFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw PolicyError.unsafeFile }
        var entry: acl_entry_t?
        var position = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            let result = acl_get_entry(acl, position, &entry)
            if result == -1 {
                guard errno == EINVAL else { throw PolicyError.unsafeFile }
                return
            }
            guard result == 0, let entry else { throw PolicyError.unsafeFile }
            var tag = ACL_UNDEFINED_TAG
            // Deny-only ACLs retain normal macOS home-directory protections without adding access grants.
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw PolicyError.unsafeFile
            }
            position = ACL_NEXT_ENTRY.rawValue
        }
    }

    private static func isPrivatePolicyFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() &&
            info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= 4096
    }
}
