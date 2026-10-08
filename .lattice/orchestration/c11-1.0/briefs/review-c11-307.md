# Review: C11-307 (bump Sparkle so macOS 26 can install updates), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-307**. PR https://github.com/Stage-11-Agentics/c11/pull/518, head `c89ac3e96b5c4cbb2a8a36724885603f7d6aa443`, base = merge-base with origin/main.
- Title `C11-307 Review Astra`. Actor `agent:astra-review-307`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X6K2V81RAAX9WWJCSVSDJ0.md`; validation `ev_01M3XS6YPG98B9MPCBRB60M1CD` (4 Atlas tests plus a signed macOS 26 update/current/dismissal proof built through C11-312's artifact-only signing). CI pending.
- Release-critical. Blocking if: the Sparkle version/package pin is not exact and reproducible; the feed URL, EdDSA public key, or appcast handling changed in a way that would break updates for already-shipped copies (the feed is `releases/latest/download/appcast.xml`); the signed proof does not show an older signed build updating to the newer one on macOS 26 and relaunching; any publishing path was exercised (no release, tag, appcast or `latest` change); entitlements/hardened-runtime/XPC services for the new Sparkle are wrong for notarization; strings localized; tests behavioral.
- When done, send VERDICT and wait.
