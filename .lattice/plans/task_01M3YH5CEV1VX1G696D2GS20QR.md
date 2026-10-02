# C11-317: Split CLI/c11.swift and make the capability registry and socket dispatch per-feature

Atin (2026-10-02): the c11 1.0 run spent most rebase churn on CLI/c11.swift (~19k lines), TerminalController.swift, SocketHandlers/SocketDispatch.swift, Sources/CapabilityFeatures.swift and Localizable.xcstrings. Split the CLI into one file per command family and make registry entries and dispatch cases additive per-feature files so parallel tickets stop conflicting. Behavior-preserving refactor; land between releases.
