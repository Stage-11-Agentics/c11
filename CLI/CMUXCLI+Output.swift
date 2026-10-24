// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension CMUXCLI {

    func printBrandHuman(_ response: Any) {
        guard let dict = response as? [String: Any] else {
            print(jsonString(response))
            return
        }
        let channel = dict["channel"] as? String ?? "unknown"
        let bundle = dict["bundle"] as? [String: Any] ?? [:]
        let palette = dict["palette"] as? [String: String] ?? [:]
        let accent = dict["accent_hex"] as? String ?? ""
        let font = dict["font_family"] as? String ?? ""
        let displayName = bundle["display_name"] as? String ?? ""
        let identifier = bundle["identifier"] as? String ?? ""
        let iconName = bundle["icon_name"] as? String ?? ""
        let shortVersion = bundle["short_version"] as? String ?? ""
        let build = bundle["build"] as? String ?? ""
        print("\(displayName) \(shortVersion) (build \(build))")
        print("channel:    \(channel)")
        print("identifier: \(identifier)")
        print("icon:       \(iconName)")
        print("accent:     \(accent)")
        print("font:       \(font)")
        print("palette:")
        let order = ["black", "surface", "rule", "dim", "white", "gold", "gold_faint"]
        for key in order {
            if let hex = palette[key] {
                print("  \(key.padding(toLength: 11, withPad: " ", startingAt: 0)) \(hex)")
            }
        }
    }

    func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }
}
