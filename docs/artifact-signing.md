# Unpublished signed artifacts

`sign-artifact.yml` builds, signs, notarizes and staples test bytes on an ephemeral
GitHub runner. It uploads **only an Actions artifact**. It has read-only repository
permission and creates no release, tag, production appcast, Homebrew update or
latest slot. Signing credentials stay in the existing GitHub repository-secret
context. Atlas receives artifacts, never certificates or Apple/Sparkle private keys.
The production `release.yml` is independent and unchanged by this producer.

## Dispatch

The workflow must have landed on the default branch before `workflow_dispatch`
is available. Select the reviewed producer ref separately from the reviewed source
ref. A mismatching full source SHA stops before build/signing. The producer is
checked out at `github.workflow_sha`; the source is checked out recursively at
`source_ref`. Only dispatch source admitted by the release Orchestrator.

For C11-307/C11-298, create two proof builds with increasing `proof_build` values.
Use an isolated Atlas HTTP directory reachable by the running proof app, for
example `http://127.0.0.1:18731/proof` when the server and app both run on Atlas.
The proof app is signed with bundle id `com.stage11.c11.sparkle307` and its feed,
appcast and daemon URLs point to that directory. The proof-only built plist allows
HTTP updater traffic through ATS; candidate ATS settings stay as built from source.
Do not modify a signed plist.
No production GitHub feed or authenticated Actions archive URL is a proof feed.

```sh
gh workflow run sign-artifact.yml --repo Stage-11-Agentics/c11 --ref main \
  -f source_ref='<reviewed-branch>' -f expected_sha='<40-character-source-sha>' \
  -f purpose=proof -f proof_build=10001 \
  -f proof_feed_base=http://127.0.0.1:18731/proof
```

For C11-292/C11-293, use `purpose=candidate` and an explicit target tag matching
the version in the built source. For 1.0 these must be `1.0.0` and `v1.0.0`.
Leave all proof inputs empty. The app retains production bundle, build and feed;
the staged appcast uses the future versioned release URL without publishing it.

```sh
gh workflow run sign-artifact.yml --repo Stage-11-Agentics/c11 --ref main \
  -f source_ref='<reviewed-versioned-ref>' -f expected_sha='<40-character-source-sha>' \
  -f purpose=candidate -f target_tag=v1.0.0
```

The standard `macos-15` runner uses process-local Xcode 26.3, Zig 0.15.2 and
create-dmg 8.0.0.
Unavailable Xcode or missing signing inputs fail explicitly. The run summary
records individual asset SHA-256 values and the uploaded archive identity/digest.
Artifact names include purpose, 12-character source SHA, run id and attempt:
`c11-signed-proof-0123456789ab-123456-1`. Retention is 30 days; download and preserve
the exact candidate before expiration. An Actions artifact is not permanent release
storage. Reruns produce new bytes and require new approval.

## Retrieve and verify on Atlas

Use an existing authorized `gh` session to download the **named artifact from the
exact run**, not the most recent run. If Atlas has no existing GitHub login,
download on an authorized client and copy the files to Atlas. Do not provision
signing credentials or a new GitHub credential on Atlas for this path.

```sh
gh run download <run-id> --repo Stage-11-Agentics/c11 \
  --name '<artifact-name>' --dir '<fresh-artifact-directory>'
cd '<fresh-artifact-directory>'
shasum -a 256 -c SHA256SUMS
python3 '<reviewed-producer-checkout>/scripts/sign_artifact.py' verify .
xcrun stapler validate c11-macos.dmg
hdiutil attach -readonly -nobrowse -mountpoint '<fixture-mount-directory>' c11-macos.dmg
xcrun stapler validate '<fixture-mount-directory>/c11.app'
codesign --verify --deep --strict '<fixture-mount-directory>/c11.app'
spctl -a -vv --type execute '<fixture-mount-directory>/c11.app'
hdiutil detach '<fixture-mount-directory>'
```

Record real Atlas command results on the consuming ticket; producer mocks and
Actions acceptance are not Atlas Gatekeeper proof. Do not launch a proof app on
Hyperion. C11-307/C11-298 own their update/relaunch runtime evidence. For computer
use, enumerate Atlas displays, set a hard termination timer and prove dismissal
with synthesized input; do not close unrelated fleet windows.

Serve the verified proof files in a fixture-owned directory matching the signed
feed URL. Copy all eight assets, create a small synthetic `notes.html`, and start
a bounded fixture server, for example a Python `http.server` bound to `127.0.0.1`
on Atlas. Preserve build 1's installed app, replace the feed directory with build
2's verified files, then let Sparkle fetch build 2. Teardown the server by its
recorded PID. The download directory is never the production feed.

## Exact-byte contract

Each artifact contains these eight immutable assets:

- `c11-macos.dmg` (signed, notarized and stapled)
- `appcast.xml` (Sparkle signature of that exact DMG)
- `c11d-remote-{darwin,linux}-{arm64,amd64}` (four binaries)
- `c11d-remote-checksums.txt`
- `c11d-remote-manifest.json`

`signing-manifest.json` records source ref/SHA, recursive submodule pins, producer
workflow SHA, run/attempt, purpose, bundle/feed/version/build/target tag,
toolchain, validation results and hashes of all eight assets. `SHA256SUMS` hashes
those assets plus the signing manifest. The manifest does not hash itself;
the run summary anchors that hash. Verify the downloaded hashes against the
recorded run summary as well as against the downloaded manifest.

C11-293 must publish the preserved candidate assets verbatim after Atin names the
candidate run and hashes. No rebuild, re-sign, re-staple or appcast regeneration
after approval. Any changed bytes require new hashes and approval. This ticket
does not implement promotion or dispatch the production release workflow.

## Lightweight producer checks

`python3 tests/test_sign_artifact.py` executes the shell producer with synthetic
platform tools, source fixtures and secret canaries. It exercises proof/candidate
identity, expected-SHA mismatch, production-feed rejection, candidate version
mismatch, missing secrets, signer failure, notarization rejection, cleanup,
the upload file set and tamper detection. It does not run Xcode or Apple tooling.
CI runs this in `workflow-guard-tests`; actual signed proof comes from the Actions
run and Atlas consumer checks.
