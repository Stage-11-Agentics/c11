import Foundation

enum AIUsageRegistry {
    /// All registered providers. Concrete provider files extend the
    /// `Providers` namespace and are appended to this list as they land
    /// (`Providers.claude`, `Providers.codex`, future stubs).
    static var all: [AIUsageProvider] { [Providers.claude, Providers.codex] }

    /// All providers usable in the UI (including credential-free local providers).
    static var ui: [AIUsageProvider] { all }

    static func provider(id: String) -> AIUsageProvider? {
        all.first { $0.id == id }
    }
}

enum Providers {}
