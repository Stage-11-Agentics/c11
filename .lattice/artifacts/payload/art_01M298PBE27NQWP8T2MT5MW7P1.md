Verdict PASS

Findings: none.

Evidence:
- ghostty/include/ghostty.h:1136 declares two parameters and ghostty/src/apprt/embedded.zig:1725 now exports the exact upstream two-parameter form; ptr.deinit() still targets the real Text buffer.
- docs/ghostty-fork.md:127 records fork SHA d4431f804 and the clean-drop upstream rebase note.
- scripts/ghosttykit-checksums.txt:14 is the workflow-generated checksum for the exact fork SHA.
- The PR diff is limited to the submodule pointer, fork documentation, and generated checksum; no Swift call site changed.
- diff --check passed for the parent and submodule commit. The bounded ABI audit compared 70 matching C-header/Zig-export functions and found zero parameter-count mismatches.