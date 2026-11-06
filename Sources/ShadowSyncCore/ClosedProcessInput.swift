import Darwin
import Foundation

/// A bounded stdin snapshot with no remaining pathname or writable descriptor.
/// The caller supplies an already verified owner-private scratch directory.
final class ClosedProcessInput {
    static let maximumBytes = 262_144
    let descriptor: Int32

    init(data: Data, directory: Int32, owner: uid_t) throws {
        var directoryInfo = stat()
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              owner == geteuid(), fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == owner,
              directoryInfo.st_mode & 0o777 == 0o700 else {
            throw GitSafetyError.unsafeRepository("closed input scratch is unsafe")
        }
        let name = ".shadow-sync-input-" + UUID().uuidString
        let writer = openat(directory, name,
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writer >= 0 else {
            throw SecureStateError.systemCall("create closed input", errno)
        }
        var reader: Int32 = -1
        var unlinked = false
        var accepted = false
        var original = stat()
        defer {
            close(writer)
            if !accepted, reader >= 0 { close(reader) }
            if !unlinked {
                var named = stat()
                if fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   named.st_dev == original.st_dev, named.st_ino == original.st_ino,
                   named.st_uid == owner, named.st_mode & S_IFMT == S_IFREG {
                    _ = unlinkat(directory, name, 0)
                }
            }
        }
        guard fstat(writer, &original) == 0, original.st_uid == owner,
              original.st_mode & S_IFMT == S_IFREG, original.st_nlink == 1 else {
            throw GitSafetyError.unsafeRepository("closed input identity is unsafe")
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(writer, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SecureStateError.systemCall("write closed input", errno)
                }
                offset += count
            }
        }
        guard fchmod(writer, 0o400) == 0 else {
            throw SecureStateError.systemCall("seal closed input", errno)
        }
        reader = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var readInfo = stat()
        var named = stat()
        guard reader > STDERR_FILENO, fstat(reader, &readInfo) == 0,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              readInfo.st_dev == original.st_dev, readInfo.st_ino == original.st_ino,
              readInfo.st_dev == named.st_dev, readInfo.st_ino == named.st_ino,
              readInfo.st_uid == owner, readInfo.st_nlink == 1,
              readInfo.st_mode & 0o777 == 0o400, readInfo.st_size == Int64(data.count),
              unlinkat(directory, name, 0) == 0 else {
            throw GitSafetyError.unsafeRepository("closed input changed before sealing")
        }
        unlinked = true
        guard fstat(reader, &readInfo) == 0, readInfo.st_nlink == 0 else {
            throw GitSafetyError.unsafeRepository("closed input still has a pathname")
        }
        descriptor = reader
        accepted = true
    }

    deinit { close(descriptor) }
}
