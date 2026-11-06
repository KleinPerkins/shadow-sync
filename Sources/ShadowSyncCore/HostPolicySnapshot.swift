import CryptoKit
import Darwin
import Foundation

/// A coherent, byte-bound configuration snapshot. This grants no repository
/// access: every candidate still requires AWA classification before any I/O.
/// The caller obtains the account from the account database and the qualified
/// contract from publisher-verified application resources. Neither is inferred
/// from environment variables or a source checkout here.
struct HostPolicySnapshot: Sendable {
    private static let bindingLocator = "Library/Application Support/ShadowSync/host-policy-binding.json"

    let account: EffectiveAccount
    let binding: HostPolicyBinding
    let projection: HostPolicyProjection
    let bindingSHA256: String
    let admissionSHA256: String
    private let files: [PolicyAuthorityFile]

    private init(account: EffectiveAccount, binding: HostPolicyBinding,
                 projection: HostPolicyProjection, bindingSHA256: String,
                 admissionSHA256: String, files: [PolicyAuthorityFile]) {
        self.account = account; self.binding = binding; self.projection = projection
        self.bindingSHA256 = bindingSHA256; self.admissionSHA256 = admissionSHA256
        self.files = files
    }

    static func load(account: EffectiveAccount, contract: QualifiedAWAContract) throws -> Self {
        do {
            guard account.uid == geteuid() else { throw HostPolicyBindingError.unavailable }
            // Concatenation preserves exact lexical bytes. The no-follow reader
            // rejects invalid absolute paths and every unsafe ancestor.
            func read(_ relative: String, maximum: Int) throws -> PolicyAuthorityFile {
                try PolicyAuthorityFile.read(path: account.homeDirectory + "/" + relative,
                                             owner: account.uid, maximumBytes: maximum)
            }
            let bindingFile = try read(bindingLocator, maximum: 65_536)
            let binding = try HostPolicyBinding.decode(bindingFile.bytes, contract: contract)
            var files = [bindingFile]
            func bound(_ path: String, _ digest: String) throws -> PolicyAuthorityFile {
                let result = try read(path, maximum: 1_048_576)
                guard result.sha256 == digest else { throw HostPolicyBindingError.unavailable }
                files.append(result); return result
            }
            _ = try bound(binding.policy.relativePath, binding.policy.sha256)
            let projectionFile = try bound(binding.projection.relativePath, binding.projection.sha256)
            let projection = try HostPolicyProjection.decode(projectionFile.bytes, policy: binding.policy)
            _ = try bound(binding.module.relativePath, binding.module.sha256)
            // Bind the projection to the current dev-owned source inputs, not
            // merely to a stale generated file whose own hash still matches.
            for key in ["host_overlay", "hook_dispatcher"] {
                guard let source = projection.sourceInputs[key] else { throw HostPolicyBindingError.unavailable }
                let file = try bound(source.relativePath, source.sha256)
                if key == "hook_dispatcher", file.bytes != projection.hookDispatcher {
                    throw HostPolicyBindingError.unavailable
                }
            }
            try PolicyAuthorityFile.revalidate(files)
            let admission = try JSONSerialization.data(withJSONObject: [
                "schema": "shadow-sync-policy-admission/v1",
                "binding_sha256": bindingFile.sha256,
                "policy_sha256": binding.policy.sha256,
                "projection_sha256": binding.projection.sha256,
                "module_sha256": contract.moduleSHA256,
                "release_revision": contract.releaseRevision,
                "account_uid": account.uid,
                "account_home": account.homeDirectory,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            return Self(account: account, binding: binding, projection: projection,
                bindingSHA256: bindingFile.sha256,
                admissionSHA256: SHA256.hash(data: admission).map { String(format: "%02x", $0) }.joined(),
                files: files)
        } catch { throw HostPolicyBindingError.unavailable }
    }

    /// Reconstruct this from currently verified publisher/host configuration
    /// on each side of a handoff. admissionSHA256 alone binds content, but a
    /// byte-identical replacement or moved ancestor must also revoke a request.
    /// This digest grants no path classification or command admission.
    func identityCommitment() throws -> String {
        try revalidate()
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "shadow-sync-policy-identity/v1",
            "admission_sha256": admissionSHA256,
            "account_username_utf8": Data(account.username.utf8).base64EncodedString(),
            "files": try files.map { try $0.identityCommitment() },
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        try revalidate()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func revalidate() throws {
        do {
            guard account.uid == geteuid() else { throw HostPolicyBindingError.unavailable }
            try PolicyAuthorityFile.revalidate(files)
        } catch { throw HostPolicyBindingError.unavailable }
    }
}
