# C11-288 browser import smoke

The packaged Release wizard exercised normal discovery and import in disposable macOS guests (macOS 26.6.2, Safari 26.6.2, Chrome 154.0.8037.98 installed in the guest). No import fixture loader, destination override, capture-only mode, or HOME override was used. All profile data was synthetic loopback data (`127.0.0.1`). No real account, password, bookmark, extension, or passkey was imported, and no real browser profile was read.

## Result

| Browser | Scope | Outcome |
|---|---|---|
| Chrome 154 (native visit) | history | Imported 1 entry with title and visit count into a fresh profile. Source database hash unchanged. |
| Chrome (synthetic, encrypted cookies only) | cookies and history | Real Keychain request appeared first. Cancel imported 0 cookies, imported history, and reported a Safe Storage warning. |
| Chrome (synthetic, plaintext cookie) | cookies and history | Imported 1 cookie and 1 history entry. The destination profile shows the loopback page signed in; a separate profile shows it signed out. |
| Arc | history | Application absent from the guest. Generated Arc schema imported 1 history entry, 0 cookies, no warning. Native Arc compatibility is unverified. |
| Safari 26.6.2 (native visit) | history | **Failed**: 0 entries and the warning `no such column: history_items.title`. Fixed in this PR. |
| Safari | cookies | Existing `Cookies.binarycookies` warning, no crash. Documented limit. |

## Fix

`BrowserDataImporter.importWebKitHistory` selected `history_items.title`. Real Safari stores `title` on `history_visits`; `history_items` has no such column. The wizard warned (not silent) but imported nothing from any real Safari history. The query now lives in `readWebKitHistoryRows` and takes `history_visits.title` from the most recent visit of each URL (SQLite returns bare columns from the `MAX(visit_time)` row). Counts, last-visit time, domain filter and the 5000-row cap are unchanged.

Test: `BrowserImportMappingTests.testSafariHistoryReadsLatestVisitTitleFromRealSchemaAndLeavesSourceUntouched` builds a database with Safari 26.6.2's observed `history_items` and `history_visits` columns, two visits to one URL plus one filtered-out host, and asserts the latest visit's title, the visit count, the last-visit date, the domain filter, and unchanged source bytes. On Atlas (tag `c11-288`, `c11LogicTests/BrowserImportMappingTests`) it fails with the old query (`no such column: history_items.title`, 1 failure in 17) and passes with the fix (17 tests, 0 failures). The fixture seeder's Safari schema was corrected to match.

## Numbered smoke steps (Validator scenario)

1. Start a disposable guest with Safari and, separately, Chrome installed. Never use a real user's profiles.
2. In the guest, visit `http://127.0.0.1:<port>/c11-288` in Chrome and in Safari, then quit each through its UI.
3. Launch the packaged build normally. Create fresh profiles `chrome-live` and `safari-live` through the profile menu. Keep the c11 browser on a blank page while doing so.
4. Browser menu, Import Browser Data. Pick Google Chrome, destination `chrome-live`, History only, domain filter `127.0.0.1`. Expect: imported history entries 1, cookies 0, no warning.
5. Repeat for Safari into `safari-live`. Expect: imported history entries 1, cookies 0, no warning. (Before the fix: 0 entries and `no such column: history_items.title`.)
6. Switch to each destination profile and open History. Expect the loopback URL with its page title.
7. Import Safari with cookies selected. Expect the `Cookies.binarycookies` warning and no crash.
8. Quit c11 through its menu and confirmation. Expect no remaining c11 process. Delete the guest.

## Limits (labeled)

- The Safari fix is proven by the behavioral test against the schema observed natively. The packaged wizard was not re-run on a fixed build; scenario steps 5 and 6 are the Validator's check.
- Successful decryption of a modern encrypted Chromium cookie was not demonstrated; the Keychain prompt and Cancel path were.
- Native Arc was not installed in the guest; Arc coverage is generated-schema only (detector root `$HOME/Library/Application Support/Arc`).
- The loopback page body is not readable through `c11 browser wait/get-text` (an H-E automation issue, out of scope); sign-in state was proven from the profile-picker screenshots and the loopback server's boolean log.
- `WorkspaceRemoteConnectionTests` is not skipped (C11-314); Keychain tests retain their SSH limitation.

## Evidence attached to C11-288

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
| Native Chrome 154 history import result, Safari schema and failing pre-fix result, red and green test excerpts | attached to C11-288 by the final owner (titles begin Native Chrome, Native Safari, Chrome destination, Red run, Green run) |
