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

## Add a Claude account

1. Open `https://claude.ai` in a browser and sign in.
2. Open DevTools, go to the **Application** panel, and grab the
   `sessionKey` cookie value (it starts with `sk-ant-sid01-`). You can
   paste the full `sessionKey=...` segment, c11 will strip the prefix.
3. Make any request on `claude.ai` and find the organization id in
   the request URL: `claude.ai/api/organizations/<orgId>/...`. The id
   is a UUID.
4. In c11, open Settings → Agents & Automation → AI Usage Monitoring.
5. Click "Add account", pick **Claude**, give the account a name
   ("Personal", "Work"), paste the session key, paste the org id, and
   save.

If you see "Sign-in expired (status 401)", repeat step 2 to get a
fresh session key.

## Add a Codex account

1. Run `codex login` once so `~/.codex/auth.json` exists.
2. Get the access token:
   ```
   jq -r .tokens.access_token < ~/.codex/auth.json
   ```
   It is a 3-segment JWT starting with `eyJ`.
3. Get the optional account id:
   ```
   jq -r .tokens.account_id < ~/.codex/auth.json
   ```
   If the value is `null` or empty, leave the field blank.
4. In c11, Settings → Agents & Automation → AI Usage Monitoring → Add
   → Codex. Paste the values and save.

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
