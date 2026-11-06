import Foundation

/// A lexical plan over the three closed configuration sources. It performs no
/// filesystem access and grants no policy, process, or repository authority.
/// Both catalog admission and the custodian use this same ancestor/batch roster.
struct ConfigurationPolicyPlan {
    let batches: [[String]]

    init(preflight: GitConfigurationPreflight, account: EffectiveAccount,
         discovery: DiscoveryCustodyIntent? = nil, requestID: String? = nil) throws {
        var paths = try preflight.admissionPaths(account: account)
        if let discovery {
            guard let requestID else { throw CustodyRecordError.invalidRecord }
            try discovery.validate(account: account)
            paths += discovery.repositoryMetadataPaths + (try DiscoveryResourceReceipt.resourcePaths(requestID: requestID))
        } else if requestID != nil { throw CustodyRecordError.invalidRecord }
        try self.init(paths: paths)
    }
    #if SHADOW_SYNC_TESTING
    init(preflight: GitConfigurationPreflight, account: EffectiveAccount,
         testingDiscovery: DiscoveryCustodyIntent, requestID: String) throws {
        try testingDiscovery.validate(account: account)
        try self.init(paths: preflight.admissionPaths(account: account) + testingDiscovery.repositoryMetadataPaths
            + DiscoveryFixtureResources.resourcePaths(home: account.homeDirectory, requestID: requestID))
    }
    init(preflight: GitConfigurationPreflight, account: EffectiveAccount, discovery: DiscoveryCustodyInput) throws {
        try self.init(paths: preflight.admissionPaths(account: account) + discovery.resourcePaths)
    }
    #endif
    private init(paths: [String]) throws {
        var prefixes: [String] = [], seen = Set<Data>()
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            // The fixed filesystem root is not an AWA candidate. Every other
            // ancestor and the leaf precede any configuration-resource access.
            for length in 2...components.count {
                let prefix = components.prefix(length).joined(separator: "/")
                if seen.insert(Data(prefix.utf8)).inserted { prefixes.append(prefix) }
            }
        }
        guard !prefixes.isEmpty, prefixes.count <= 256 else { throw PolicyHelperError.unavailable }
        batches = stride(from: 0, to: prefixes.count, by: 64).map {
            Array(prefixes[$0..<min($0 + 64, prefixes.count)])
        }
    }

    func bind(index: Int, nonce: String, bindingSHA256: String,
              policySHA256: String, moduleSHA256: String) throws -> ConfigurationPolicyBatch {
        guard batches.indices.contains(index), [policySHA256, moduleSHA256].allSatisfy({
            CustodyWire.hex($0, bytes: 32)
        }) else { throw PolicyProtocolError.invalidRequest }
        let candidates = batches[index]
        let input = try PolicyRequestEncoder.encode(candidates: candidates, nonce: nonce,
                                                    bindingSHA256: bindingSHA256)
        return ConfigurationPolicyBatch(input: input,
            expected: ExpectedPolicyResponse(nonce: nonce, bindingSHA256: bindingSHA256,
                policySHA256: policySHA256, moduleSHA256: moduleSHA256,
                candidateCount: candidates.count))
    }
}

/// These bytes are data, never an execution capability. The caller must first
/// establish actual child retirement, complete streams, and current authority.
struct ConfigurationPolicyBatch {
    let input: Data
    private let expected: ExpectedPolicyResponse
    fileprivate init(input: Data, expected: ExpectedPolicyResponse) {
        self.input = input; self.expected = expected
    }
    func validate(stdout: Data, stderr: Data) throws {
        guard stderr.isEmpty else { throw PolicyHelperError.unavailable }
        let decisions = try PolicyResponseDecoder.decode(stdout, expected: expected)
        guard decisions.count == expected.candidateCount,
              decisions.allSatisfy(\.allowsCandidateAccess) else { throw PolicyHelperError.unavailable }
    }
}
