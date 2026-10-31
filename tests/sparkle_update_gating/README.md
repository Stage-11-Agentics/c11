# Sparkle update gating (C11-541)

Proves that the appcast `scripts/sparkle_generate_appcast.sh` writes for an arm64-only DMG is skipped by Intel Macs and still installs on Apple silicon. Real Sparkle 2.9.3 (c11 1.x) and 2.8.1 (c11 0.x) clients run `-checkForUpdateInformation` against fake hosts at builds 131, 132 and 160, and at the two nightly builds around the Sparkle 2.9 move (3684650524801, the last 2.8.1 nightly; 3711499935701, the first 2.9.3 one, which `nightly.yml` uses as its threshold). The run also checks an unguarded feed and three mutants of the guarded one, so the guards are shown to carry the result.

Run on an Apple-silicon Mac with Xcode, Rosetta and network: `tests/sparkle_update_gating/run.sh [results.json]`. It takes about a minute, builds everything in a temp dir, prints the table to stderr, writes JSON to the given path or to stdout, and exits non-zero on any unexpected verdict.

What it cannot prove: it never runs on Intel hardware. "Native Intel" is simulated in an x86_64 probe under Rosetta: `fake_intel.c` makes `sysctl.proc_translated` fail with ENOENT, the answer a native Intel process gets. It also leaves c11's own update UI out; the verdicts come from Sparkle's driver, not from what c11 0.x shows.
