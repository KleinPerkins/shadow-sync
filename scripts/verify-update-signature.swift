import CryptoKit
import Foundation

// Public-key-only verifier, deliberately independent of Sparkle's signing tool.
// Status 0 means valid; 1 means invalid input/signature. No input is logged.
@main
struct VerifyUpdateSignature {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4,
                  let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
                  publicKey.count == 32,
                  let signature = Data(base64Encoded: CommandLine.arguments[2]),
                  signature.count == 64 else { exit(1) }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            exit(key.isValidSignature(signature, for: bytes) ? 0 : 1)
        } catch {
            exit(1)
        }
    }
}
