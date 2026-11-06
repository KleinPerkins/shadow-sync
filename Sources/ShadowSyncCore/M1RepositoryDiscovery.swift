import Darwin
import Foundation

public enum M1RepositoryDiscoveryError: Error, Equatable, Sendable {
    case accountUnavailable
    case requiredRootUnavailable
    case locationUnavailable
    case unsupportedLayout
    case invalidRepositoryMetadata
    case policyUnavailable
    case scanBudgetExceeded
}

public struct RepositoryDiscoveryFailurePresentation: Equatable, Sendable {
    public let messageText: String
    public let informativeText: String

    public static func forError(_ error: any Error) -> Self {
        switch error as? M1RepositoryDiscoveryError {
        case .accountUnavailable:
            return Self(
                messageText: "Account Information Unavailable",
                informativeText:
                    "ShadowSync could not locate the current account's home folder. Check the account configuration, then try again."
            )
        case .requiredRootUnavailable, .locationUnavailable, .unsupportedLayout:
            return Self(
                messageText: "Required ~/dev Folder Unavailable",
                informativeText:
                    "ShadowSync could not find or safely open the required ~/dev folder. Restore or check out ~/dev in your home folder, make sure you can open it, then try again."
            )
        case .invalidRepositoryMetadata:
            return Self(
                messageText: "Repository Could Not Be Verified",
                informativeText:
                    "ShadowSync found ~/dev but could not verify its supported M1 Git metadata and origin. Check the repository, then try again."
            )
        case .policyUnavailable:
            return Self(
                messageText: "Repository Safety Policy Unavailable",
                informativeText:
                    "ShadowSync could not verify which repositories are safe to inspect. No repositories were checked."
            )
        case .scanBudgetExceeded:
            return Self(
                messageText: "Repository Search Limit Reached",
                informativeText:
                    "ShadowSync stopped before offering repositories because ~/dev contains more folders than can be safely inspected in one run. Move unnecessary folders outside ~/dev, then try again. No update was started."
            )
        case nil:
            return Self(
                messageText: "Repository Check Failed",
                informativeText:
                    "ShadowSync could not inspect the M1 ~/dev repository. Review its local layout and Git metadata, then try again."
            )
        }
    }
}

public struct RepositoryDiscoveryEmptyPresentation: Equatable, Sendable {
    public let messageText: String
    public let informativeText: String

    public static let noEligibleCandidate = Self(
        messageText: "No Eligible Repository Found",
        informativeText:
            "ShadowSync found ~/dev, but no repository could be safely offered for selection. No update was started."
    )

    public static let m1NoCandidate = noEligibleCandidate
}

#if SHADOW_SYNC_TESTING
public struct M1RepositoryDiscovery: RepositoryDiscovering {
    #if SHADOW_SYNC_TESTING
    private let testingAccount: EffectiveAccount?
    #endif

    public init() {
        #if SHADOW_SYNC_TESTING
        testingAccount = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(testingHomeDirectory: String) throws {
        testingAccount = try EffectiveAccount.isolated(homeDirectory: testingHomeDirectory)
    }
    #endif

    public func discover() throws -> [RepositoryCandidate] {
        let account: EffectiveAccount
        #if SHADOW_SYNC_TESTING
        if let testingAccount {
            account = testingAccount
        } else {
            account = try currentAccount()
        }
        #else
        account = try currentAccount()
        #endif
        let path = URL(fileURLWithPath: account.homeDirectory)
            .appendingPathComponent("dev", isDirectory: true).path
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT {
                throw M1RepositoryDiscoveryError.requiredRootUnavailable
            }
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw M1RepositoryDiscoveryError.requiredRootUnavailable
        }
        let rootDescriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        defer { close(rootDescriptor) }
        let gitPath = URL(fileURLWithPath: path)
            .appendingPathComponent(".git", isDirectory: true).path
        var gitInfo = stat()
        if lstat(gitPath, &gitInfo) != 0 {
            if errno == ENOENT {
                return []
            }
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        guard (gitInfo.st_mode & S_IFMT) == S_IFDIR else {
            return []
        }
        do {
            let candidate = try RepositoryHandle.fixedCandidate(path: path)
            return [RepositoryCandidate(
                id: candidate.id,
                displayName: candidate.originIdentity?.canonicalName
                    ?? candidate.displayName,
                path: candidate.path,
                rawOrigin: candidate.rawOrigin,
                presentationLocation: "~/dev",
                rootIdentity: candidate.rootIdentity,
                gitDirectoryIdentity: candidate.gitDirectoryIdentity,
                commonDirectoryIdentity: candidate.commonDirectoryIdentity,
                configIdentity: candidate.configIdentity,
                policyAdmissionSHA256: candidate.policyAdmissionSHA256,
                hookAdmissionSHA256: candidate.hookAdmissionSHA256,
                linkedWorktreePaths: candidate.linkedWorktreePaths
            )]
        } catch {
            throw M1RepositoryDiscoveryError.invalidRepositoryMetadata
        }
    }

    private func currentAccount() throws -> EffectiveAccount {
        do {
            return try EffectiveAccount.current()
        } catch {
            throw M1RepositoryDiscoveryError.accountUnavailable
        }
    }
}
#endif
