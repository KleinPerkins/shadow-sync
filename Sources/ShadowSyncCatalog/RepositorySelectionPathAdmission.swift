import Foundation

/// A lexical request, not a filesystem handle. Keep exact UTF-8 bytes: policy
/// authority must not be transferred between canonically equivalent spellings.
public struct RepositorySelectionAdmissionPath: Sendable {
    public let root: String
    public let components: [String]

    public init(root: String, components: [String]) throws {
        guard !root.isEmpty, root.utf8.count <= 128,
              !root.hasPrefix("/"), !root.contains("\\"),
              root.rangeOfCharacter(from: .controlCharacters) == nil,
              components.count <= 16,
              components.allSatisfy({ value in
                  !value.isEmpty && value.utf8.count <= 255
                      && value != "." && value != ".."
                      && !value.contains("/") && !value.contains("\\")
                      && value.rangeOfCharacter(from: .controlCharacters) == nil
              }) else { throw RepositorySelectionAdmissionError.unavailable }
        self.root = root
        self.components = components
    }

    func sameBytes(as other: Self) -> Bool {
        root.utf8.elementsEqual(other.root.utf8)
            && components.count == other.components.count
            && zip(components, other.components).allSatisfy {
                $0.utf8.elementsEqual($1.utf8)
            }
    }
}

public enum RepositorySelectionAdmissionError: Error, Sendable {
    case unavailable, cleanupPending
}

public enum RepositorySelectionAdmissionDisposition: Sendable {
    case allowed
    case protected
}

public struct RepositorySelectionAdmissionDecision: Sendable {
    public let path: RepositorySelectionAdmissionPath
    public let disposition: RepositorySelectionAdmissionDisposition

    public init(path: RepositorySelectionAdmissionPath,
                disposition: RepositorySelectionAdmissionDisposition) {
        self.path = path
        self.disposition = disposition
    }
}

/// Catalog owns no process or policy implementation. Core supplies the verified
/// AWA adapter and a current-authority check. Absence always refuses access.
public struct RepositorySelectionPathAdmission: Sendable {
    private let evaluate: @Sendable ([RepositorySelectionAdmissionPath], UInt64) throws
        -> [RepositorySelectionAdmissionDecision]
    private let revalidate: @Sendable () throws -> Void

    #if SHADOW_SYNC_TESTING
    public enum TestingFailureStage: String, Sendable { case deadlineBefore, revalidation, deadlineAfter }
    public enum TestingPosition: String, Sendable { case direct, classifyBefore, classifyAfter }
    public typealias TestingValidationCompletion = @Sendable (TestingFailureStage?) -> Void
    private var testingPosition = TestingPosition.direct
    private var testingValidation: (@Sendable (TestingPosition, UInt64, UInt64) -> TestingValidationCompletion?)?

    /// The returned completion is called synchronously on this same thread,
    /// exactly once, before validate returns or throws.
    public func testingObservingValidation(
        _ observer: @escaping @Sendable (TestingPosition, UInt64, UInt64) -> TestingValidationCompletion?
    ) -> Self {
        var copy = self; copy.testingValidation = observer; return copy
    }
    private func testingAt(_ position: TestingPosition) -> Self {
        var copy = self; copy.testingPosition = position; return copy
    }
    private var testingFailure: (@Sendable (TestingFailureStage, UInt64, UInt64) -> Void)?

    public func testingObservingFailures(
        _ observer: @escaping @Sendable (TestingFailureStage, UInt64, UInt64) -> Void
    ) -> Self {
        var copy = self
        copy.testingFailure = observer
        return copy
    }
    #endif

    public init(
        evaluate: @escaping @Sendable ([RepositorySelectionAdmissionPath], UInt64) throws
            -> [RepositorySelectionAdmissionDecision],
        revalidate: @escaping @Sendable () throws -> Void
    ) {
        self.evaluate = evaluate
        self.revalidate = revalidate
    }

    public static var unavailable: Self {
        Self(evaluate: { _, _ in throw RepositorySelectionAdmissionError.unavailable },
             revalidate: { throw RepositorySelectionAdmissionError.unavailable })
    }

    public func validate(deadline: UInt64) throws {
        #if SHADOW_SYNC_TESTING
        let started = DispatchTime.now().uptimeNanoseconds
        var stage = TestingFailureStage.deadlineBefore
        var passed = false
        let completed = testingValidation?(testingPosition, started, deadline)
        defer {
            completed?(passed ? nil : stage)
            if !passed { testingFailure?(stage, started, deadline) }
        }
        #endif
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw RepositorySelectionAdmissionError.unavailable
        }
        #if SHADOW_SYNC_TESTING
        stage = .revalidation
        #endif
        try revalidate()
        #if SHADOW_SYNC_TESTING
        stage = .deadlineAfter
        #endif
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw RepositorySelectionAdmissionError.unavailable
        }
        #if SHADOW_SYNC_TESTING
        passed = true
        #endif
    }

    public func classify(_ paths: [RepositorySelectionAdmissionPath], deadline: UInt64)
        throws -> [RepositorySelectionAdmissionDisposition] {
        guard !paths.isEmpty, paths.count <= 64 else {
            throw RepositorySelectionAdmissionError.unavailable
        }
        #if SHADOW_SYNC_TESTING
        try testingAt(.classifyBefore).validate(deadline: deadline)
        #else
        try validate(deadline: deadline)
        #endif
        let decisions = try evaluate(paths, deadline)
        #if SHADOW_SYNC_TESTING
        try testingAt(.classifyAfter).validate(deadline: deadline)
        #else
        try validate(deadline: deadline)
        #endif
        guard decisions.count == paths.count,
              zip(paths, decisions).allSatisfy({ $0.sameBytes(as: $1.path) }) else {
            throw RepositorySelectionAdmissionError.unavailable
        }
        return decisions.map(\.disposition)
    }

    public func requireAllowed(_ path: RepositorySelectionAdmissionPath, deadline: UInt64) throws {
        guard case .allowed = try classify([path], deadline: deadline)[0] else {
            throw RepositorySelectionAdmissionError.unavailable
        }
    }

    #if SHADOW_SYNC_TESTING
    /// Explicit isolated-fixture dependency. Never compiled into the product.
    public static var testingAllowAll: Self {
        Self(evaluate: { paths, _ in paths.map {
            RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed)
        } }, revalidate: {})
    }
    #endif
}
