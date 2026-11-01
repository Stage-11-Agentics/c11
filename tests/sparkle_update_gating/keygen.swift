// Prints a throwaway Sparkle EdDSA key pair, base64, one per line: the 32-byte
// private seed (the format sign_update and generate_appcast read from a key
// file) and the public key (the SUPublicEDKey value).
import CryptoKit

let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
