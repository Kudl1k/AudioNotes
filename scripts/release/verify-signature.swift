import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else { exit(2) }
do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: data) else { exit(1) }
} catch { exit(1) }
