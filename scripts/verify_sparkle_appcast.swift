#!/usr/bin/env swift
// Verifies a generated Sparkle appcast against the archive it describes, with
// no keychain access: the enclosure's sparkle:edSignature must be a valid
// Ed25519 signature of the archive under the given public key, the enclosure
// length must equal the archive size, and the URL must be the expected one.
// Prints the item's version fields as JSON so the caller can compare them
// with the app's Info.plist.
//
// Usage: verify_sparkle_appcast.swift <appcast.xml> <archive> <base64-public-key> <expected-url>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("verify_sparkle_appcast: \(message)\n", stderr)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 5 else {
    fail("usage: verify_sparkle_appcast.swift <appcast.xml> <archive> <base64-public-key> <expected-url>")
}
let (appcastPath, archivePath, publicKeyB64, expectedURL) = (args[1], args[2], args[3], args[4])

guard let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: appcastPath), options: []) else {
    fail("cannot parse \(appcastPath)")
}
guard let items = try? document.nodes(forXPath: "//channel/item"), items.count == 1,
      let item = items.first as? XMLElement else {
    fail("appcast must contain exactly one item")
}
guard let enclosure = item.elements(forName: "enclosure").first else { fail("item has no enclosure") }

func attribute(_ element: XMLElement, _ name: String) -> String? {
    element.attributes?.first(where: { $0.name == name })?.stringValue
}
func child(_ name: String) -> String? {
    item.elements(forName: name).first?.stringValue
}

guard let signatureB64 = attribute(enclosure, "sparkle:edSignature"),
      let signature = Data(base64Encoded: signatureB64) else { fail("enclosure has no sparkle:edSignature") }
guard let url = attribute(enclosure, "url") else { fail("enclosure has no url") }
guard let lengthText = attribute(enclosure, "length"), let length = Int(lengthText) else { fail("enclosure has no length") }

guard let archive = FileManager.default.contents(atPath: archivePath) else { fail("cannot read \(archivePath)") }
var keyText = publicKeyB64
while keyText.count % 4 != 0 { keyText += "=" }
guard let keyData = Data(base64Encoded: keyText),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("invalid Ed25519 public key")
}

guard publicKey.isValidSignature(signature, for: archive) else {
    fail("edSignature does NOT verify against the given public key")
}
guard length == archive.count else { fail("enclosure length \(length) != archive size \(archive.count)") }
guard url == expectedURL else { fail("enclosure url \(url) != expected \(expectedURL)") }

let version = attribute(enclosure, "sparkle:version") ?? child("sparkle:version") ?? ""
let shortVersion = attribute(enclosure, "sparkle:shortVersionString") ?? child("sparkle:shortVersionString") ?? ""
let result: [String: Any] = [
    "signature": "valid",
    "url": url,
    "length": length,
    "version": version,
    "shortVersionString": shortVersion,
]
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)
