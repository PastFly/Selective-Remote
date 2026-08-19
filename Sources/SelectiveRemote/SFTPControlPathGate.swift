import Foundation

/// Serializes lifecycle work for one OpenSSH ControlPath without blocking
/// unrelated SFTP connections. The old master manager held one global lock
/// while probing and starting SSH, so a slow server could delay every pane.
final class SFTPControlPathGate: @unchecked Sendable {
    private let registryLock = NSLock()
    private var pathLocks: [String: NSLock] = [:]

    func withLock<Result>(
        _ controlPath: String,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let pathLock = registryLock.withLock { () -> NSLock in
            if let existing = pathLocks[controlPath] {
                return existing
            }
            let created = NSLock()
            pathLocks[controlPath] = created
            return created
        }

        pathLock.lock()
        defer { pathLock.unlock() }
        return try body()
    }
}
