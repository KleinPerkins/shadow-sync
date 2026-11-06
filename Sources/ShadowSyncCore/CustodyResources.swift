import Darwin
import Foundation

enum CustodyResourceError: Error { case invalidResource, closed, limit, systemCall(Int32) }

#if SHADOW_SYNC_TESTING
enum CustodyResourceTesting {
    enum Point: String, CaseIterable { case named, unlinked, written, pipeRead, pipeWrite }
    private static let key = "shadow-sync-custody-resource-fault"
    static func withFault(_ point: Point, _ body: () throws -> Void) throws {
        let prior = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = point.rawValue
        defer {
            if let prior { Thread.current.threadDictionary[key] = prior }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        try body()
    }
    static func hit(_ point: Point) throws {
        if Thread.current.threadDictionary[key] as? String == point.rawValue { throw CustodyResourceError.systemCall(EIO) }
    }
}
#endif

/// A value observation never confers ownership of the observed descriptor.
private struct CustodyResourceIdentity: Equatable {
    let node: FileIdentity
    let access: Int32
    let size: Int64
    let modifiedSeconds: Int, modifiedNanoseconds: Int
    let changedSeconds: Int, changedNanoseconds: Int
    let acl: String?

    static func capture(_ fd: Int32, kind: mode_t, access: Int32, uid: uid_t) throws -> Self {
        var info = stat()
        let flags = fcntl(fd, F_GETFL), descriptorFlags = fcntl(fd, F_GETFD)
        guard fd > 200, fstat(fd, &info) == 0, info.st_dev >= 0,
              info.st_mode & S_IFMT == kind,
              (info.st_uid == uid || (kind == S_IFDIR && isSystemRoot(info))),
              flags >= 0, flags & O_ACCMODE == access,
              descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0 else {
            throw CustodyResourceError.invalidResource
        }
        if kind == S_IFREG {
            guard info.st_mode == S_IFREG | 0o400, info.st_nlink == 0,
                  info.st_size >= 0, info.st_size <= 1_048_576 else { throw CustodyResourceError.invalidResource }
        } else if kind == S_IFDIR {
            guard info.st_mode & 0o7022 == 0 else { throw CustodyResourceError.invalidResource }
        } else if kind == S_IFIFO {
            // Darwin pipe ends have distinct kernel inode observations, device
            // zero, no links and kernel-chosen mode bits. They have no pathname.
            guard info.st_nlink == 0, flags & O_NONBLOCK != 0 else { throw CustodyResourceError.invalidResource }
        } else { throw CustodyResourceError.invalidResource }
        return Self(node: FileIdentity(info), access: access, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec,
            acl: kind == S_IFIFO ? nil : try PolicyAuthorityFile.safeACL(fd))
    }

    private static func isSystemRoot(_ info: stat) -> Bool {
        var root = stat()
        return info.st_uid == 0 && lstat("/", &root) == 0 && root.st_mode & S_IFMT == S_IFDIR
            && root.st_dev == info.st_dev && root.st_ino == info.st_ino
    }

    func claim(_ role: CustodyDescriptorClaim.Role) -> CustodyDescriptorClaim {
        CustodyDescriptorClaim(role: role, device: node.device, inode: node.inode, uid: node.owner,
            mode: UInt32(node.mode), links: UInt64(node.linkCount), access: access == O_RDONLY ? .read : .write)
    }
    func sameStableResource(as other: Self) -> Bool {
        node.matchesStableNode(other.node) && (node.isDirectory || node.linkCount == other.node.linkCount)
            && access == other.access && acl == other.acl
    }
}

/// Created only from an actual retained state capability. The temporary name is
/// removed before private bytes are written; no writable handle escapes creation.
final class CustodySealedResource: @unchecked Sendable {
    let role: CustodyDescriptorClaim.Role
    let sha256: String
    fileprivate let descriptor: OwnedFileDescriptor
    private let identity: CustodyResourceIdentity

    private init(role: CustodyDescriptorClaim.Role, descriptor: OwnedFileDescriptor,
                 identity: CustodyResourceIdentity, bytes: Data) {
        self.role = role; self.descriptor = descriptor; self.identity = identity
        sha256 = CustodyRecordBinding.digest(bytes)
    }
    static func bytes(_ bytes: Data, role: CustodyDescriptorClaim.Role,
                      leases: CustodyAuthorityLeaseSet) throws -> CustodySealedResource {
        guard role == .input || role == .code, !bytes.isEmpty, bytes.count <= 262_144 else {
            throw CustodyResourceError.limit
        }
        return try create(role: role, leases: leases) { _ in bytes }
    }
    /// The request includes its own real inode/descriptor claim. This builder
    /// runs before publication, without a metadata guard or child process.
    fileprivate static func create(role: CustodyDescriptorClaim.Role, leases: CustodyAuthorityLeaseSet,
                                   content: (CustodyDescriptorClaim) throws -> Data) throws -> CustodySealedResource {
        let state = try leases.duplicateStateDirectory(), root = state.0.value
        let name = ".shadow-sync-custody-input-" + UUID().uuidString.lowercased()
        let rawWriter = openat(root, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard rawWriter >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let writer = OwnedFileDescriptor(rawWriter)
        var original = stat(), named = stat(), unlinked = false
        defer {
            writer.closeNow()
            if !unlinked, fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
               named.st_dev == original.st_dev, named.st_ino == original.st_ino,
               named.st_uid == state.1, named.st_mode & S_IFMT == S_IFREG { _ = unlinkat(root, name, 0) }
        }
        guard fstat(rawWriter, &original) == 0, original.st_uid == state.1,
              original.st_nlink == 1, original.st_mode & S_IFMT == S_IFREG,
              fchmod(rawWriter, 0o400) == 0 else { throw CustodyResourceError.invalidResource }
        #if SHADOW_SYNC_TESTING
        try CustodyResourceTesting.hit(.named)
        #endif
        let rawReader = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard rawReader >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let initialReader = OwnedFileDescriptor(rawReader)
        let reader = OwnedFileDescriptor(try initialReader.duplicate(minimum: 201)); initialReader.closeNow()
        var observed = stat()
        guard fstat(reader.value, &observed) == 0, observed.st_dev == original.st_dev,
              observed.st_ino == original.st_ino, observed.st_nlink == 1,
              fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == original.st_dev, named.st_ino == original.st_ino,
              unlinkat(root, name, 0) == 0 else { throw CustodyResourceError.invalidResource }
        unlinked = true
        #if SHADOW_SYNC_TESTING
        try CustodyResourceTesting.hit(.unlinked)
        #endif
        guard fsync(root) == 0 else { throw CustodyResourceError.systemCall(errno) }
        let before = try CustodyResourceIdentity.capture(reader.value, kind: S_IFREG, access: O_RDONLY, uid: state.1)
        let bytes = try content(before.claim(role))
        guard !bytes.isEmpty, bytes.count <= (role == .request ? 1_048_576 : 262_144) else { throw CustodyResourceError.limit }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(rawWriter, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CustodyResourceError.systemCall(errno) }; offset += n
            }
        }
        #if SHADOW_SYNC_TESTING
        try CustodyResourceTesting.hit(.written)
        #endif
        guard fsync(rawWriter) == 0 else { throw CustodyResourceError.systemCall(errno) }
        writer.closeNow()
        let after = try CustodyResourceIdentity.capture(reader.value, kind: S_IFREG, access: O_RDONLY, uid: state.1)
        guard before.sameStableResource(as: after), after.size == bytes.count else { throw CustodyResourceError.invalidResource }
        let result = Self(role: role, descriptor: reader, identity: after, bytes: bytes)
        try result.validate(); return result
    }
    /// A retained read-only view for a serial child. It is never a new lock or
    /// writable capability; the original sealed resource remains held by its owner.
    func duplicateReadOnly() throws -> OwnedFileDescriptor {
        try validate()
        let copy = OwnedFileDescriptor(try descriptor.duplicate(minimum: 201))
        try validate()
        return copy
    }
    func claim() throws -> CustodyDescriptorClaim { try validate(); return identity.claim(role) }
    func validate() throws {
        let current = try CustodyResourceIdentity.capture(descriptor.value, kind: S_IFREG, access: O_RDONLY, uid: identity.node.owner)
        guard current == identity, try digest() == sha256 else { throw CustodyResourceError.invalidResource }
    }
    private func digest() throws -> String {
        var data = Data(), block = [UInt8](repeating: 0, count: 4096)
        while data.count < identity.size {
            let n = pread(descriptor.value, &block, min(block.count, Int(identity.size) - data.count), off_t(data.count))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CustodyResourceError.invalidResource }; data.append(contentsOf: block.prefix(n))
        }
        guard try CustodyResourceIdentity.capture(descriptor.value, kind: S_IFREG, access: O_RDONLY, uid: identity.node.owner) == identity else {
            throw CustodyResourceError.invalidResource
        }
        return CustodyRecordBinding.digest(data)
    }
}

enum CustodyPipeRead: Equatable { case bytes(Data), wouldBlock, end }

/// Every endpoint is private, nonblocking, CLOEXEC and normalized above all
/// inherited destinations. No method duplicates the caller's liveness writer.
private final class CustodyPipe {
    private let mutex = NSLock()
    private var reader: OwnedFileDescriptor?
    private var writer: OwnedFileDescriptor?
    private let readIdentity: CustodyResourceIdentity, writeIdentity: CustodyResourceIdentity
    private let uid: uid_t

    init() throws {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw CustodyResourceError.systemCall(errno) }
        let originals = pair.map(OwnedFileDescriptor.init)
        defer { originals.forEach { $0.closeNow() } }
        var copies: [OwnedFileDescriptor] = []
        for original in originals {
            // All production spawns must use CLOEXEC_DEFAULT; that also closes
            // the initial pipe descriptors during the short normalization step.
            let copy = OwnedFileDescriptor(try original.duplicate(minimum: 201))
            let flags = fcntl(copy.value, F_GETFL)
            guard flags >= 0, fcntl(copy.value, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CustodyResourceError.systemCall(errno) }
            copies.append(copy)
            #if SHADOW_SYNC_TESTING
            try CustodyResourceTesting.hit(copies.count == 1 ? .pipeRead : .pipeWrite)
            #endif
        }
        guard fcntl(copies[1].value, F_SETNOSIGPIPE, 1) == 0 else { throw CustodyResourceError.systemCall(errno) }
        uid = geteuid(); reader = copies[0]; writer = copies[1]
        readIdentity = try CustodyResourceIdentity.capture(copies[0].value, kind: S_IFIFO, access: O_RDONLY, uid: uid)
        writeIdentity = try CustodyResourceIdentity.capture(copies[1].value, kind: S_IFIFO, access: O_WRONLY, uid: uid)
    }
    func claim(_ role: CustodyDescriptorClaim.Role, writing: Bool) throws -> CustodyDescriptorClaim {
        mutex.lock(); defer { mutex.unlock() }
        let expected = writing ? writeIdentity : readIdentity
        guard let fd = writing ? writer : reader,
              try CustodyResourceIdentity.capture(fd.value, kind: S_IFIFO, access: writing ? O_WRONLY : O_RDONLY, uid: uid)
                .sameStableResource(as: expected) else { throw CustodyResourceError.closed }
        return expected.claim(role)
    }
    func take(writing: Bool) throws -> OwnedFileDescriptor {
        mutex.lock(); defer { mutex.unlock() }
        guard let result = writing ? writer : reader else { throw CustodyResourceError.closed }
        guard try CustodyResourceIdentity.capture(result.value, kind: S_IFIFO, access: writing ? O_WRONLY : O_RDONLY, uid: uid)
            .sameStableResource(as: writing ? writeIdentity : readIdentity) else { throw CustodyResourceError.invalidResource }
        if writing { writer = nil } else { reader = nil }
        return result
    }
    #if SHADOW_SYNC_TESTING
    var testingWriter: Int32 { mutex.lock(); defer { mutex.unlock() }; return writer?.value ?? -1 }
    #endif
    func closeWriter() { mutex.lock(); writer?.closeNow(); writer = nil; mutex.unlock() }
    func read(maximum: Int) throws -> CustodyPipeRead {
        guard (1...16_388).contains(maximum) else { throw CustodyResourceError.limit }
        mutex.lock(); defer { mutex.unlock() }
        guard let reader else { throw CustodyResourceError.closed }
        var bytes = [UInt8](repeating: 0, count: maximum)
        let n = Darwin.read(reader.value, &bytes, bytes.count)
        if n < 0 && [EINTR, EAGAIN].contains(errno) { return .wouldBlock }
        guard n >= 0 else { throw CustodyResourceError.systemCall(errno) }
        return n == 0 ? .end : .bytes(Data(bytes.prefix(n)))
    }
    func write(_ bytes: Data, offset: Int) throws -> Int {
        guard !bytes.isEmpty, bytes.count <= 16_388, (0..<bytes.count).contains(offset) else { throw CustodyResourceError.limit }
        mutex.lock(); defer { mutex.unlock() }
        guard let writer else { throw CustodyResourceError.closed }
        let n = bytes.withUnsafeBytes { Darwin.write(writer.value, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if n < 0 && [EINTR, EAGAIN].contains(errno) { return 0 }
        guard n >= 0 else { throw CustodyResourceError.systemCall(errno) }; return n
    }
}

/// The original cleanup owner and its exact open-file descriptions survive the
/// caller's local references. Registry retirement controls this object's lifetime;
/// no helper duplicate is wrapped in another cleanup-owning configuration object.
final class CustodyFrozenGitResources: @unchecked Sendable {
    private let owner: FrozenGitConfiguration
    let directory: OwnedFileDescriptor, file: OwnedFileDescriptor
    private let claims: [CustodyDescriptorClaim]
    private let acls: [String]

    init(_ owner: FrozenGitConfiguration, uid: uid_t) throws {
        self.owner = owner
        let directoryCopy = fcntl(owner.directoryDescriptor, F_DUPFD_CLOEXEC, 201)
        guard directoryCopy >= 0 else { throw CustodyResourceError.systemCall(errno) }
        directory = OwnedFileDescriptor(directoryCopy)
        let fileCopy = fcntl(owner.descriptor, F_DUPFD_CLOEXEC, 201)
        guard fileCopy >= 0 else { throw CustodyResourceError.systemCall(errno) }
        file = OwnedFileDescriptor(fileCopy)
        let pairs: [(CustodyDescriptorClaim.Role, Int32)] = [(.gitDirectory, directory.value), (.gitFile, file.value)]
        claims = try pairs.map { try Self.claim($0.1, role: $0.0, uid: uid) }
        acls = try pairs.map { try PolicyAuthorityFile.safeACL($0.1) }
        try validate()
    }
    static func claim(_ descriptor: Int32, role: CustodyDescriptorClaim.Role, uid: uid_t) throws -> CustodyDescriptorClaim {
        guard role == .gitDirectory || role == .gitFile else { throw CustodyResourceError.invalidResource }
        var info = stat()
        let access = role == .gitFile ? O_RDWR : O_RDONLY
        let flags = fcntl(descriptor, F_GETFL), fdFlags = fcntl(descriptor, F_GETFD)
        guard descriptor > 200, fstat(descriptor, &info) == 0, info.st_dev >= 0,
              info.st_uid == uid, info.st_mode == (role == .gitFile ? S_IFREG | 0o600 : S_IFDIR | 0o700),
              role != .gitFile || info.st_nlink == 1,
              info.st_flags & UInt32(UF_IMMUTABLE) != 0,
              flags >= 0, flags & O_ACCMODE == access, fdFlags >= 0, fdFlags & FD_CLOEXEC != 0 else {
            throw CustodyResourceError.invalidResource
        }
        return CustodyDescriptorClaim(role: role, device: UInt64(info.st_dev), inode: info.st_ino,
            uid: info.st_uid, mode: UInt32(info.st_mode), links: UInt64(info.st_nlink),
            access: role == .gitFile ? .readWrite : .read)
    }
    func descriptorClaims() throws -> [CustodyDescriptorClaim] { try validate(); return claims }
    func validate() throws {
        let pairs: [(CustodyDescriptorClaim.Role, Int32)] = [(.gitDirectory, directory.value), (.gitFile, file.value)]
        guard try pairs.map({ try Self.claim($0.1, role: $0.0, uid: geteuid()) }) == claims,
              try pairs.map({ try PolicyAuthorityFile.safeACL($0.1) }) == acls else {
            throw CustodyResourceError.invalidResource
        }
        try RepositoryHandle.validateFrozenConfiguration(descriptor: file.value,
            directoryDescriptor: directory.value, snapshot: owner.snapshot)
    }
    var snapshot: GitConfigurationSnapshot { owner.snapshot }
}

/// A helper retains the actual inherited lock descriptions; its target receives
/// only a separately opened, identity-checked read-only view. That view never
/// reacquires or substitutes for the lock. This object owns no pathname cleanup.
final class CustodyInheritedFrozenConfiguration {
    let snapshot: GitConfigurationSnapshot
    let targetReadOnly: OwnedFileDescriptor
    private let file: OwnedFileDescriptor, directory: OwnedFileDescriptor
    private let claims: [CustodyDescriptorClaim], acls: [String]

    init(snapshot: GitConfigurationSnapshot, directory: OwnedFileDescriptor, file: OwnedFileDescriptor) throws {
        self.snapshot = snapshot; self.directory = directory; self.file = file
        claims = try [CustodyFrozenGitResources.claim(directory.value, role: .gitDirectory, uid: geteuid()),
                      CustodyFrozenGitResources.claim(file.value, role: .gitFile, uid: geteuid())]
        acls = try [PolicyAuthorityFile.safeACL(directory.value), PolicyAuthorityFile.safeACL(file.value)]
        try RepositoryHandle.validateFrozenConfiguration(descriptor: file.value,
            directoryDescriptor: directory.value, snapshot: snapshot)
        let raw = openat(directory.value, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let view = OwnedFileDescriptor(raw)
        targetReadOnly = OwnedFileDescriptor(try view.duplicate(minimum: 201))
        try revalidate()
    }
    func revalidate() throws {
        guard try [CustodyFrozenGitResources.claim(directory.value, role: .gitDirectory, uid: geteuid()),
                   CustodyFrozenGitResources.claim(file.value, role: .gitFile, uid: geteuid())] == claims,
              try [PolicyAuthorityFile.safeACL(directory.value), PolicyAuthorityFile.safeACL(file.value)] == acls else {
            throw CustodyResourceError.invalidResource
        }
        try RepositoryHandle.validateFrozenConfiguration(descriptor: file.value,
            directoryDescriptor: directory.value, snapshot: snapshot)
        var info = stat()
        guard fstat(targetReadOnly.value, &info) == 0, FileIdentity(info) == snapshot.frozenIdentity,
              info.st_size == Int64(snapshot.frozenSize), info.st_flags & UInt32(UF_IMMUTABLE) != 0,
              fcntl(targetReadOnly.value, F_GETFL) & O_ACCMODE == O_RDONLY,
              fcntl(targetReadOnly.value, F_GETFD) & FD_CLOEXEC != 0,
              try PolicyAuthorityFile.safeACL(targetReadOnly.value) == acls[1] else {
            throw CustodyResourceError.invalidResource
        }
    }
    #if SHADOW_SYNC_TESTING
    static func fixtureBytes(_ snapshot: GitConfigurationSnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }
    static func fixtureSnapshot(_ bytes: Data, parent: pid_t) throws -> GitConfigurationSnapshot {
        // Strict parsing rejects duplicate keys before Codable; canonical replay
        // rejects unknown fields and ambiguous/coerced values. This fixture is
        // not a production policy admission or a general decoded path reader.
        _ = try CustodyWire.decode(bytes, maximum: 262_144)
        let value = try JSONDecoder().decode(GitConfigurationSnapshot.self, from: bytes)
        let prefix = "/private/tmp/shadow-sync-fixture-config."
        guard try fixtureBytes(value) == bytes, value.frozenOwnerPID == parent,
              value.frozenDirectoryPath.hasPrefix(prefix),
              !value.frozenDirectoryPath.dropFirst(prefix.count).isEmpty,
              value.frozenDirectoryPath.dropFirst(prefix.count).utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45
              }), value.frozenPath == value.frozenDirectoryPath + "/config" else {
            throw CustodyResourceError.invalidResource
        }
        return value
    }
    #endif
}

/// Actual held resources, not an executable permit or proof that a repository
/// candidate passed policy. The future command context must supply that authority.
final class CustodyRequestResources: @unchecked Sendable {
    let scope: CustodyMetadataScope
    let request: UnvalidatedCustodyRequest
    let sealedRequest: CustodySealedResource
    private let input: CustodySealedResource?, code: CustodySealedResource?
    private let workingDirectory: OwnedFileDescriptor
    private let workingIdentity: CustodyResourceIdentity
    private let control: CustodyPipe, status: CustodyPipe, output: CustodyPipe, error: CustodyPipe
    private let trace: CustodyPipe?
    private let frozenConfiguration: CustodyFrozenGitResources?
    private let mutex = NSLock()
    private var transferred = false

    init(scope: CustodyMetadataScope, kind: CustodyCommandKind, arguments: [String], environment: [String: String],
         budget: CustodyBudget, stdoutLimit: UInt64, stderrLimit: UInt64,
         workingDirectory source: OwnedFileDescriptor, input: Data? = nil, code: Data? = nil,
         captureDiscoveryTrace: Bool = false, frozenConfiguration: FrozenGitConfiguration? = nil) throws {
        guard scope.observation == .open else { throw CustodyRecordError.fenced }
        guard !captureDiscoveryTrace || kind == .discoveryGit else { throw CustodyResourceError.invalidResource }
        if kind == .policyClassify {
            guard input != nil, code != nil, stdoutLimit <= 65_536, stderrLimit <= 65_536 else {
                throw CustodyResourceError.invalidResource
            }
        }
        try budget.validate(kind: kind, permittedWorkSeconds: kind.maximumWorkSeconds, now: DispatchTime.now().uptimeNanoseconds)
        guard frozenConfiguration == nil || (kind == .discoveryGit && input != nil && code == nil
            && (scope.leases.mode == .read || scope.leases.mode == .mutation)) else {
            throw CustodyResourceError.invalidResource
        }
        self.frozenConfiguration = try frozenConfiguration.map { try CustodyFrozenGitResources($0, uid: scope.uid) }
        self.scope = scope
        workingDirectory = OwnedFileDescriptor(try source.duplicate(minimum: 201))
        workingIdentity = try CustodyResourceIdentity.capture(workingDirectory.value, kind: S_IFDIR, access: O_RDONLY, uid: scope.uid)
        self.input = try input.map { try CustodySealedResource.bytes($0, role: .input, leases: scope.leases) }
        self.code = try code.map { try CustodySealedResource.bytes($0, role: .code, leases: scope.leases) }
        control = try CustodyPipe(); status = try CustodyPipe(); output = try CustodyPipe(); error = try CustodyPipe()
        trace = captureDiscoveryTrace ? try CustodyPipe() : nil
        let binding = try scope.binding(nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        var claims = try scope.leases.descriptorClaims() + [control.claim(.control, writing: false), status.claim(.status, writing: true), workingIdentity.claim(.workingDirectory)]
        if let frozenConfiguration = self.frozenConfiguration { claims += try frozenConfiguration.descriptorClaims() }
        if let input = self.input { claims.append(try input.claim()) }
        if let code = self.code { claims.append(try code.claim()) }
        if let trace { claims.append(try trace.claim(.traceOutput, writing: true)) }
        var prepared: UnvalidatedCustodyRequest?
        let inputSHA256 = self.input?.sha256, codeSHA256 = self.code?.sha256
        sealedRequest = try CustodySealedResource.create(role: .request, leases: scope.leases) { requestClaim in
            let descriptors = (claims + [requestClaim]).sorted { $0.role.number < $1.role.number }
            let digest = try Self.resourceDigest(descriptors, input: inputSHA256, code: codeSHA256)
            let r = UnvalidatedCustodyRequest(binding: binding, kind: kind, authority: scope.leases.mode,
                arguments: arguments, environment: environment, budget: budget, stdoutLimit: stdoutLimit, stderrLimit: stderrLimit,
                inputSHA256: inputSHA256, resourcesSHA256: digest, descriptors: descriptors)
            let data = try r.encode(); prepared = r; return data
        }
        guard let prepared else { throw CustodyResourceError.invalidResource }; request = prepared
        try validate()
    }
    static func resourceDigest(_ claims: [CustodyDescriptorClaim], input: String?, code: String?) throws -> String {
        let bytes = try CustodyWire.encode(.object(["schema": .string("shadow-sync-custody-resources/v1"),
            "descriptors": .array(claims.map(\.wire)), "input": input.map(PolicyWireValue.string) ?? .null,
            "code": code.map(PolicyWireValue.string) ?? .null]), maximum: 16_384)
        return CustodyRecordBinding.digest(bytes)
    }
    func validate() throws {
        try scope.leases.validate(); try sealedRequest.validate(); try input?.validate(); try code?.validate()
        try frozenConfiguration?.validate()
        let current = try CustodyResourceIdentity.capture(workingDirectory.value, kind: S_IFDIR, access: O_RDONLY, uid: scope.uid)
        guard current.sameStableResource(as: workingIdentity),
              try sealedRequest.claim() == request.descriptors.first(where: { $0.role == .request }),
              try Self.resourceDigest(request.descriptors, input: input?.sha256, code: code?.sha256) == request.resourcesSHA256 else {
            throw CustodyResourceError.invalidResource
        }
    }
    /// One ownership transfer of helper pipe ends. The caller's control writer
    /// is deliberately absent. A registry must retain this value before spawn.
    func takeSpawnResources() throws -> CustodySpawnResources {
        mutex.lock(); defer { mutex.unlock() }
        guard !transferred else { throw CustodyResourceError.closed }; try validate()
        transferred = true
        var sources: [(Int32, OwnedFileDescriptor)] = []
        sources.append((191, try control.take(writing: false)))
        sources.append((192, try status.take(writing: true)))
        sources.append((1, try output.take(writing: true)))
        sources.append((2, try error.take(writing: true)))
        if let trace { sources.append((7, try trace.take(writing: true))) }
        var files: [(Int32, OwnedFileDescriptor)] = [(190, sealedRequest.descriptor), (200, workingDirectory)]
        if let frozenConfiguration { files += [(195, frozenConfiguration.directory), (196, frozenConfiguration.file)] }
        if let input { files.append((8, input.descriptor)) }
        if let code { files.append((9, code.descriptor)) }
        return try CustodySpawnResources(resources: self, pipeSources: sources, fileSources: files)
    }
    func closeControl() { control.closeWriter() }
    func writeControl(_ data: Data, offset: Int = 0) throws -> Int { try control.write(data, offset: offset) }
    func readStatus() throws -> CustodyPipeRead { try status.read(maximum: 16_388) }
    func readOutput(error isError: Bool = false) throws -> CustodyPipeRead { try (isError ? error : output).read(maximum: 16_388) }
    func readTrace() throws -> CustodyPipeRead {
        guard let trace else { return .end }
        return try trace.read(maximum: 16_388)
    }

    #if SHADOW_SYNC_TESTING
    var testingControlWriterDescriptor: Int32 { control.testingWriter }
    var testingRequestDescriptor: Int32 { sealedRequest.descriptor.value }
    var testingWorkingDescriptor: Int32 { workingDirectory.value }
    #endif
}

/// Closed inherited mapping only. It never selects an executable, spawns,
/// resumes a process, accepts a journal result or grants candidate access.
final class CustodySpawnResources: @unchecked Sendable {
    let resources: CustodyRequestResources
    private let pipeSources: [(Int32, OwnedFileDescriptor)]
    private let fileSources: [(Int32, OwnedFileDescriptor)]
    private let pipeIdentities: [CustodyResourceIdentity]
    private let mutex = NSLock()
    private var mapped = false, released = false
    fileprivate init(resources: CustodyRequestResources, pipeSources: [(Int32, OwnedFileDescriptor)], fileSources: [(Int32, OwnedFileDescriptor)]) throws {
        self.resources = resources; self.pipeSources = pipeSources; self.fileSources = fileSources
        pipeIdentities = try pipeSources.map { target, fd in
            let identity = try CustodyResourceIdentity.capture(fd.value, kind: S_IFIFO, access: target == 191 ? O_RDONLY : O_WRONLY, uid: resources.scope.uid)
            if target == 191 || target == 192 || target == 7 {
                let role: CustodyDescriptorClaim.Role = target == 191 ? .control : (target == 192 ? .status : .traceOutput)
                guard identity.claim(role) == resources.request.descriptors.first(where: { $0.role == role }) else { throw CustodyResourceError.invalidResource }
            }
            return identity
        }
    }
    func appendActions(to actions: inout posix_spawn_file_actions_t?) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !mapped, !released, actions != nil else { throw CustodyResourceError.closed }
        try resources.validate(); try resources.scope.leases.appendSpawnActions(to: &actions)
        for (i, source) in pipeSources.enumerated() {
            guard try CustodyResourceIdentity.capture(source.1.value, kind: S_IFIFO, access: source.0 == 191 ? O_RDONLY : O_WRONLY, uid: resources.scope.uid)
                .sameStableResource(as: pipeIdentities[i]) else { throw CustodyResourceError.invalidResource }
        }
        for (target, source) in pipeSources + fileSources {
            guard source.value > 200 else { throw CustodyResourceError.invalidResource }
            let rc = posix_spawn_file_actions_adddup2(&actions, source.value, target)
            guard rc == 0 else { throw CustodyResourceError.systemCall(rc) }
        }
        let null = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        guard null == 0 else { throw CustodyResourceError.systemCall(null) }
        guard let directory = fileSources.first(where: { $0.0 == 200 }) else { throw CustodyResourceError.invalidResource }
        // Darwin resolves this action against the retained parent descriptor.
        // Using a destination created by another spawn action fails EBADF.
        let cwd = posix_spawn_file_actions_addfchdir(&actions, directory.1.value)
        guard cwd == 0 else { throw CustodyResourceError.systemCall(cwd) }
        for (_, source) in pipeSources + fileSources {
            let rc = posix_spawn_file_actions_addclose(&actions, source.value)
            guard rc == 0 else { throw CustodyResourceError.systemCall(rc) }
        }
        mapped = true
    }
    /// Call after the actual spawn attempt, including failure. Until then the
    /// registry retains these copies; after release EOF depends only on the child.
    func releaseChildCopies() {
        mutex.lock(); defer { mutex.unlock() }
        guard !released else { return }; released = true
        for (_, source) in pipeSources { source.closeNow() }
    }
    #if SHADOW_SYNC_TESTING
    func testingDescriptor(_ target: Int32) -> Int32? { (pipeSources + fileSources).first { $0.0 == target }?.1.value }
    var testingSourceDescriptors: [Int32] { (pipeSources + fileSources).map { $0.1.value } }
    #endif
}
