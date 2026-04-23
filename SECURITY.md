# Security

Found something that looks like a security issue in c11? Report it privately. Public issues turn bad news into worse news.

## How to report

- **Preferred — GitHub Security Advisories:** <https://github.com/Stage-11-Agentics/c11/security/advisories/new>
- **Fallback — email:** `benevolent.futures@gmail.com`, subject line `c11 security`.

Include what you found, how to trigger it, and anything you've already established about impact. We'll acknowledge within three business days, work with you on reproduction and a fix, and coordinate public disclosure after the patch ships. Credit however you want it — your name, a handle, or not at all.

## What counts

c11 is a macOS app with a local Unix socket, an embedded terminal (Ghostty), an embedded browser (WKWebView), and an agent-facing metadata layer. In scope:

- Arbitrary code execution via crafted socket commands, malformed metadata, or malicious terminal output.
- Privilege escalation, sandbox escape, or TCC / entitlement abuse specific to c11.
- Credential or secret leakage in logs, crash reports, or persisted workspace state.
- Auto-update / Sparkle signing or delivery issues on c11's release pipeline.

Out of scope:

- Social engineering of operators.
- Bugs in upstream dependencies (Ghostty, Sparkle, Bonsplit, etc.) that aren't reachable through c11's configuration. Report those upstream; we'll help route if you're not sure where.
- Anything that requires physical access to an already-compromised machine.

## Supported versions

c11 is pre-1.0 and ships as a rolling release through the `stage-11-agentics/c11` Homebrew tap and DMGs on the [Releases](https://github.com/Stage-11-Agentics/c11/releases) page. Security fixes land on the latest build; older versions aren't maintained. Keep current.

## Safe harbor

We won't pursue legal action against researchers who:

- Act in good faith and reach out before public disclosure.
- Avoid privacy violations, data destruction, and service disruption.
- Stay inside the minimum needed to demonstrate the issue.

Report the thing, we'll fix the thing.
