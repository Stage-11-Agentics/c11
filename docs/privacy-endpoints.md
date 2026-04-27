# Outbound network endpoints

This document tracks every outbound HTTP host c11 can contact, broken
down by feature. Treat this as the single source of truth: if you add
a feature that talks to a new host, add a section here in the same PR.

## AI Usage Monitoring

User-opted. With no accounts configured, none of these calls are made.

| Host | Path | Why | Frequency |
|------|------|-----|-----------|
| `claude.ai` | `/api/organizations/<orgId>/usage` | Claude session/week utilization | per Claude account every 60s while window is visible |
| `chatgpt.com` | `/backend-api/wham/usage` | Codex session/week utilization | per Codex account every 60s while window is visible |
| `status.claude.com` | `/api/v2/incidents.json` | Claude.ai status banner | every 5th tick (~5 min) when any Claude account exists |
| `status.openai.com` | `/api/v2/incidents.json` | Codex status banner | every 5th tick (~5 min) when any Codex account exists |

Hard guarantees:

- Status hosts are enforced via `AIUsageStatusPagePoller.allowedHosts`;
  the poller rejects any host not in that set, plus any host containing
  `/` or `:`. Adding a provider that needs a new statuspage host
  requires updating that allowlist AND this doc.
- Credentials are stored in macOS Keychain only, with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
  `kSecAttrSynchronizable = false`.
- Network requests use an ephemeral `URLSession` with no cookie storage
  and no `URLCache`. The `Cookie`, `Authorization`, and
  `chatgpt-account-id` headers are sanitized via
  `AIUsageHTTP.sanitizeHeaderValue` before being attached.
- Fetchers log only error domain/code; never URL or header values.
- The poller skips ticks while the app window is occluded.
