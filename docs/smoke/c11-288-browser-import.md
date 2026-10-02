# C11-288 browser import smoke (parked WIP)

The packaged Release wizard exercised normal discovery and import in disposable macOS guests. No import fixture loader, destination override, capture-only mode, or HOME override was used. All profile data was synthetic loopback data. This smoke is incomplete and is not a handoff or release verdict.

## Completed observations

1. Historical source `837f9f79925a7d5e7b18854ee3577bc2fec2a3cc`: normal discovery found generated Chrome, Arc and Safari profiles in the guest's actual home. Roots were `$HOME/Library/Application Support/Google/Chrome/Default`, `$HOME/Library/Application Support/Arc/Default` and `$HOME/Library/Safari`.
2. Created fresh destination `c11-288-chrome-denied` through the UI. An encrypted-only synthetic Chrome source triggered the actual Keychain password request. Cancel imported zero cookies and one history entry, with an explicit Safe Storage warning. Source bytes remained unchanged. This does not prove successful decryption of modern encrypted cookies.
3. Imported the mixed Chrome fixture into `c11-288-chrome`: one plaintext cookie, one skipped encrypted row, one history entry, and the Keychain warning. Imported Arc history into `c11-288-arc`: zero cookies, one history entry, no warning. Imported generated Safari history into `c11-288-safari`: zero cookies, one history entry, and the documented unsupported `Cookies.binarycookies` warning. Four destination histories held the exact synthetic loopback URL; seven original fixture hashes matched before and after import.
4. Canonical tag `c11-288`, clean source `a70bcae30878b6e8dfc24d31e98bc258a41b4fe5`, compiled Release successfully. Executable SHA256: `31b1856e6c11673639defadcf8f58caf8083e2db4dd8bac1e1c7cbfa6c766425`. The source includes C11-314. Compilation did not execute native unit assertions.
5. On that canonical build, imported a declared plaintext-only Chrome subset into fresh `c11-288-chrome` (one cookie, one history entry, no warning), and Arc history into fresh `c11-288-arc` (zero cookies, one history entry, no warning). Actual profile-picker screenshots show SIGNED IN under Chrome and SIGNED OUT under Arc for the same loopback URL. The server independently recorded true then false. Source hashes after this second pass were not captured; do not claim its source immutability.
6. Installed Chrome 154.0.8037.98 only inside the disposable guest, visited the loopback page in a fresh native Chrome profile, quit Chrome through its UI, and confirmed the persisted source history entry. Import of that browser-produced database into c11 was not completed. The guest ran macOS 26.6.2 (25G83); Safari 26.6.2 was installed. Arc was absent, so native Arc compatibility remains unverified; its detector root is `$HOME/Library/Application Support/Arc`.
7. Both completed guest leases were deleted. The second guest was automatically deleted at its 20-minute deadline. That cleanup does not prove successful c11 UI Quit. Completed build logs and a runtime app copy were retained; the canonical build cache was deleted.

## Remaining work

1. Obtain a normal-serial guest lease with no other guests running and no UI reservation or Validator VM priority marker. Do not start while `/tmp/c11-validator-vm-wanted` exists on the remote host. Use a 20-minute automatic deletion timer and actively drive the lease.
2. In a fresh guest, produce loopback visits in native Chrome and Safari, quit each through its UI, and record their actual persisted history schemas and hashes. Keep the c11 browser blank before creating destinations, so profile switching cannot pre-populate the imported URL.
3. Create fresh `c11-288-chrome-live` and `c11-288-safari-live` through the actual profile UI. Import native history through the packaged wizard. Verify destination entries and unchanged source hashes. Record counts and specific warnings. Fix and behaviorally test any actual importer regression; the generated Safari schema above does not prove compatibility with Safari's real schema.
4. Quit c11 through its actual menu and confirmation. Verify no matching application and no original application process remain. Delete the guest immediately afterward, even on failure.
5. Replace this WIP with the final numbered smoke note and evidence. If code changes, rebuild and test using only tag `c11-288`; C11-314 removes the WorkspaceRemoteConnectionTests skip, while Keychain tests still need their SSH limitation recorded.
6. Push the final branch, create the draft PR only at handoff, post a validation comment with a numbered Validator scenario, and send HANDOFF REVIEW. No PR is currently open for this ticket.

## Evidence already attached to C11-288

| Observation | Artifact |
|---|---|
| Normal packaged discovery | `art_01M3YKDZRC5Z4G9RJ9J5AQYDGK` |
| Actual synthetic Keychain request | `art_01M3YKDZTW8BEG59RPRK57J6YH` |
| Chrome encrypted-only denial | `art_01M3YKB72VDW19XYFVF78FSQJA` |
| Chrome mixed-fixture result | `art_01M3YKB75EKY9R7KNWJETAVCYH` |
| Arc generated-history result | `art_01M3YKB77YGBR8W9A5FHP59N1R` |
| Safari generated-history result and cookie warning | `art_01M3YKB7ACD89KTH6WVBRKG8G5` |
| Four persisted destination histories | `art_01M3YKDZXBN3E7J5ENDE680MK3` |
| Seven original source hashes unchanged | `art_01M3YM74EBBWJMFQYYX8F98D6T` |
| Canonical Release identity | `art_01M3YW66RCQ0NNDQRVHJA71V3S` |
| Chrome selected profile, SIGNED IN | `art_01M3Z2P8WK7AD2A6DN5561BVN5` |
| Arc selected profile, SIGNED OUT | `art_01M3Z2P90BECYKR979F54BPJJ3` |
| Boolean-only loopback server log | `art_01M3Z2TFDF6NEEPJJE2H1CYYDK` |

Safari cookies remain unsupported. Successful modern Chromium encrypted-cookie import is unverified. Native Arc coverage is unavailable. No importer code has changed; no real account, password, bookmark, extension, or passkey was imported.
