# AI Usage Monitoring

c11 can show your remaining Claude.ai and Codex (ChatGPT) subscription
quota in the sidebar footer. The panel is opt-in: with no accounts
configured, nothing renders.

## Where it appears

When you add at least one account, a per-provider section is added to
the sidebar footer (above the dev panel in DEBUG builds and above the
help menu / update pill in release builds). Each section can be
collapsed independently, and the collapsed state is remembered in
`UserDefaults` under `c11.aiusage.collapsed.<providerId>`.

Each account row shows:
- a 5-hour Session bar
- a 7-day Week bar
- the next reset window when known

Click the section's ellipsis menu to add another account, edit an
existing one, refresh now, or open the upstream status page.

## Privacy

- Credentials live in macOS Keychain only, with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
  `kSecAttrSynchronizable = false` (no iCloud).
- Network requests use an ephemeral `URLSession` (no on-disk cookies,
  no `URLCache`, `reloadIgnoringLocalCacheData`).
- The status page poller hard-codes an allowlist of two hosts:
  `status.claude.com` and `status.openai.com`. No other status host
  can be contacted without a code change.
- The fetchers log only error domain/code, never URL or header values.
- See `docs/privacy-endpoints.md` for the full list of outbound hosts.

## Claude

Claude usage is read automatically from Claude Code's local activity
log (`~/.claude/projects/`). No credentials are required and no
network call is made to fetch usage data.

c11 registers a Claude account automatically on first launch if the
local log directory exists.

### Add a Claude account

1. In c11, open Settings → Agents & Automation → AI Usage Monitoring.
2. Click "Add account" and pick **Claude**.
3. Give the account a name ("Personal", "Work") and optionally set a
   session token limit (e.g. `140000`).
4. Save.

When a session token limit is set, the sidebar shows a utilization
bar. Without a limit, c11 displays session and week costs in dollars
instead.

### Session token limit

If you know your Claude plan's 5-hour session cap (visible in your
subscription settings), enter it here to see a utilization bar instead
of the cost-only view. Leave blank to always show cost.

## Codex

Codex usage is read automatically from the Codex CLI's local database
(`~/.codex/state_5.sqlite`). No setup required — add a Codex account
in Settings → AI Usage Monitoring → Add Codex Account if the sidebar
entry doesn't appear automatically.

When a session token limit is set, the sidebar shows a utilization bar.
Without a limit, c11 displays session and week costs in dollars instead.

## Multiple accounts per provider

You can add as many accounts as you like. A common pattern is one
"Personal" and one "Work" entry per provider. Each row is independent;
removing one only deletes that one Keychain item.

## Bar colors and thresholds

The Settings → Agents & Automation page also exposes a colors card.
You can customize the low / mid / high colors, the percentages where
each color takes over, and toggle smooth interpolation between the
stops. Defaults: 85% / 95%, smooth interpolation on, palette
`#46B46E / #D2AA3C / #DC5050`. The global "Reset Settings" button
restores the palette but does not delete account credentials, since
that is a separate "Remove" action per account.

## Troubleshooting

- **401 / 403:** the sign-in expired. Open the editor and paste a
  fresh credential.
- **Codex returns 404:** the token does not have access to the WHAM
  endpoint (no Codex subscription).
- **Status loading forever:** the upstream status page returned a
  network error. The poller retries every five minutes and surfaces
  the last successful fetch in the meantime.
- **Polling pauses when the window is hidden:** intentional. The
  occlusion observer skips ticks while the window is not visible to
  avoid burning quota when nothing is reading the panel.
