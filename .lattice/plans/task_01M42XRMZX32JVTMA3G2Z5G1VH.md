# C11-331: Remote builds upload only what Atlas lacks, not a full-history bundle per head

## Why
In the c11 1.0 run, staging to Atlas was slow all day and caused real stalls. `scripts/remote_build.py` caches bundles by SHA, but every new head creates `parent-<head>.bundle` from `git bundle create ... HEAD`, which carries the full history (about 170 MB). The Hyperion to Atlas link measured about 160 KB/s (2026-10-02 15:51). With ten seats staging at once, seats hit their 900 s command cap (15:00), Atlas load reached 54, and a captain gate waited behind uploads (12:20). The workaround was to build and run guests on Atlas and never ship built apps across the link.

## Done when
- A remote build for a new head uploads only the objects Atlas does not have: an incremental bundle against a base the host already holds, or a `git fetch` on Atlas from the forge.
- Staging a head whose parent Atlas already has takes seconds, not minutes, measured over the Hyperion link.
- `tests/test_remote_build_routing.py` (or a sibling test) covers the incremental path and the fallback to a full bundle when no shared base exists.

Source: c11 1.0 run retro, `.lattice/orchestration/c11-1.0/run-state.md` entries 12:20, 15:00 and 15:51 on 2026-10-02.
