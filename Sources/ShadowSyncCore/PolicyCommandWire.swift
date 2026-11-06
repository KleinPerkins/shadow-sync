import Foundation

/// Closed policy wire shared by caller and actual custodian. Its validation
/// performs no candidate filesystem access and grants no publisher authority.
enum PolicyCommandWire {
    static let logicalArguments = ["isolated-policy-classification"]
    static var interpreterArguments: [String] { ["-I", "-S", "-B", "-c", bootstrap] }

    static func budget(timeout: TimeInterval, absoluteDeadline: UInt64?,
                       now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> CustodyBudget {
        let original = try CustodyBudget.make(kind: .policyClassify, workSeconds: timeout, now: now)
        guard let deadline = absoluteDeadline else { return original }
        guard deadline > now else { throw CustodyProtocolError.invalidBudget }
        return try original.draining(at: deadline)
    }

    static func resources(adapter: Data, contract: Data) throws -> Data {
        guard (1...65_536).contains(adapter.count), (1...16_384).contains(contract.count) else {
            throw PolicyProtocolError.invalidRequest
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "shadow-sync-policy-resources/v1", "adapter": adapter.base64EncodedString(),
            "contract": contract.base64EncodedString(),
        ], options: [.sortedKeys])
        guard data.count <= 131_072 else { throw PolicyProtocolError.invalidRequest }
        return data
    }

    static func validateRequest(_ data: Data, bindingSHA256: String) throws {
        guard !data.isEmpty, data.count <= 262_144 else { throw PolicyProtocolError.invalidRequest }
        var parser = try PolicyWireParser(data, profile: .configuration)
        let object = try parser.parse().object(keys: ["schema", "nonce", "binding_sha256", "candidates"])
        guard object["schema"] == .string("shadow-sync-policy-batch-request/v1"),
              object["binding_sha256"] == .string(bindingSHA256),
              case .string(let nonce) = object["nonce"], case .array(let values) = object["candidates"] else {
            throw PolicyProtocolError.invalidRequest
        }
        let candidates = try values.map { value -> String in
            guard case .string(let candidate) = value else { throw PolicyProtocolError.invalidRequest }
            return candidate
        }
        // The established encoder applies every lexical/count/duplicate bound.
        // Require its canonical bytes as well; no second permissive grammar.
        guard try PolicyRequestEncoder.encode(candidates: candidates, nonce: nonce,
            bindingSHA256: bindingSHA256) == data else { throw PolicyProtocolError.invalidRequest }
    }

    static let bootstrap = #"""
    import base64,json,os,sys
    try:
        if not sys.flags.isolated or not sys.flags.no_site or not sys.flags.dont_write_bytecode: raise ValueError()
        with os.fdopen(9,'rb') as f: raw=f.read(131073)
        if not 0<len(raw)<=131072: raise ValueError()
        def pairs(items):
            out={}
            for key,value in items:
                if key in out: raise ValueError()
                out[key]=value
            return out
        value=json.loads(raw,object_pairs_hook=pairs)
        if type(value) is not dict or set(value)!={'schema','adapter','contract'}: raise ValueError()
        if value['schema']!='shadow-sync-policy-resources/v1': raise ValueError()
        if type(value['adapter']) is not str or type(value['contract']) is not str: raise ValueError()
        adapter=base64.b64decode(value['adapter'],validate=True)
        contract=base64.b64decode(value['contract'],validate=True)
        if not 0<len(adapter)<=65536 or not 0<len(contract)<=16384: raise ValueError()
        scope={'__name__':'shadow_sync_policy_adapter'}
        exec(compile(adapter,'<shadow-sync-policy-adapter>','exec'),scope)
        result=scope['run_sealed'](contract)
        if type(result) is not int or result not in (0,2): raise ValueError()
    except BaseException:
        sys.stderr.write('Policy classification unavailable.\n')
        sys.exit(2)
    sys.exit(result)
    """#
}
