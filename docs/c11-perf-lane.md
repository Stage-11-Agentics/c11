# Atlas c11 performance lane

The lane measures two command-search tests from `c11LogicTests` and one Markdown corpus bridge test from `c11Tests` on the current `main` tip once an hour. It runs on Atlas under the existing user, uses the shared fleet build slot, writes one JSONL record per benchmark, and posts no GitHub status. A failed or unavailable measurement never blocks `main`.

The script owns a separate checkout at `~/c11-perf-lane/worktree` and a separate DerivedData directory. It fetches the requested ref, refuses a dirty checkout, updates the pinned submodules, and invokes `xcodebuild` only through `~/c11-poller/bin/atlas_build_slots.py`. It sets `C11_PERF_LANE=1` and runs these selectors serially:

- `CommandPaletteSearchEngineTests/testCommandSearchBenchmarkBeatsLegacyPipeline`
- `CommandPaletteSearchEngineTests/testSwitcherSearchBenchmarkBeatsLegacyPipeline`
- `MarkdownWebRendererTests/testCorpusBridgeSubmissionCostOnC11Checkout`

## Install after merge

Run these commands on Atlas as `atinwoodard` after this lane is merged:

```sh
mkdir -p "$HOME/c11-perf-lane/logs" "$HOME/c11-perf-lane/records" "$HOME/Library/LaunchAgents"
git clone --no-tags https://github.com/Stage-11-Agentics/c11.git "$HOME/c11-perf-lane/worktree"
git -C "$HOME/c11-perf-lane/worktree" submodule update --init --recursive ghostty vendor/bonsplit
GHOSTTY_SHA="$(git -C "$HOME/c11-perf-lane/worktree" rev-parse HEAD:ghostty)"
if [ ! -d "$HOME/.cache/cmux/ghosttykit/$GHOSTTY_SHA/GhosttyKit.xcframework" ]; then
  mkdir -p "$HOME/.cache/cmux/ghosttykit/$GHOSTTY_SHA"
  (
    cd "$HOME/.cache/cmux/ghosttykit/$GHOSTTY_SHA"
    GHOSTTY_SHA="$GHOSTTY_SHA" \
      GHOSTTYKIT_OUTPUT_DIR="$HOME/.cache/cmux/ghosttykit/$GHOSTTY_SHA/GhosttyKit.xcframework" \
      "$HOME/c11-perf-lane/worktree/scripts/download-prebuilt-ghosttykit.sh"
  )
fi
sed "s|@HOME@|$HOME|g" \
  "$HOME/c11-perf-lane/worktree/scripts/launchd/com.stage11.c11-perf-lane.plist.in" \
  > "$HOME/Library/LaunchAgents/com.stage11.c11-perf-lane.plist"
plutil -lint "$HOME/Library/LaunchAgents/com.stage11.c11-perf-lane.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.stage11.c11-perf-lane.plist"
launchctl kickstart -k "gui/$(id -u)/com.stage11.c11-perf-lane"
```

The `StartInterval` is one hour; the kickstart runs the first sample immediately. Runs serialize with a lock under `state/`. A run that overlaps another exits successfully without starting a second build.

## Check and run

```sh
launchctl print "gui/$(id -u)/com.stage11.c11-perf-lane"
tail -n 3 "$HOME/c11-perf-lane/records/perf.jsonl"
tail -n 40 "$HOME/c11-perf-lane/logs/launchd.err"
```

To run a sample immediately:

```sh
/usr/bin/python3 "$HOME/c11-perf-lane/worktree/scripts/c11-perf-lane.py" \
  run --root "$HOME/c11-perf-lane" --ref main
```

Each JSONL row includes the full tested SHA, the benchmark name, measured milliseconds, overall test state, run id, log path and elapsed build/test seconds. The two search rows include reference and optimized timings; the corpus row includes payload bytes, median main-thread submission time and all samples. Passing result bundles are removed after their summary is read. Failed result bundles and logs are kept for 30 days; old logs and bundles are pruned on the next run. The append-only timing record is retained.

## Stop and remove

```sh
launchctl bootout "gui/$(id -u)/com.stage11.c11-perf-lane"
/bin/rm -f "$HOME/Library/LaunchAgents/com.stage11.c11-perf-lane.plist"
/bin/rm -rf "$HOME/c11-perf-lane"
```
