import Foundation
import Darwin

/// Prevents two current app processes from saving stale full local collections.
/// Older releases do not honor this lease and require separate storage identities.
final class NativeStorageLease {
    enum LeaseError: Error { case busy, unavailable }
    private let descriptor: Int32

    init(directory: URL? = nil) throws {
        let root: URL
        if let directory { root = directory }
        else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw LeaseError.unavailable
            }
            root = support.appendingPathComponent("Selective Remote", isDirectory: true)
                .appendingPathComponent("CredentialLocks", isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw LeaseError.unavailable }
        let directoryFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw LeaseError.unavailable }
        defer { Darwin.close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(), (directoryInfo.st_mode & 0o077) == 0
        else { throw LeaseError.unavailable }
        var fd: Int32 = -1
        for attempt in 0..<4 {
            fd = openat(directoryFD, "native-app.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd >= 0 || errno != ENOENT { break }
            if attempt < 3 { usleep(1_000) }
        }
        guard fd >= 0 else { throw LeaseError.unavailable }
        var info = stat(), pathInfo = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0, info.st_nlink == 1,
              fstatat(directoryFD, "native-app.lock", &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_ino == info.st_ino, pathInfo.st_dev == info.st_dev
        else { Darwin.close(fd); throw LeaseError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(fd)
            if failure == EWOULDBLOCK || failure == EAGAIN { throw LeaseError.busy }
            throw LeaseError.unavailable
        }
        descriptor = fd
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
