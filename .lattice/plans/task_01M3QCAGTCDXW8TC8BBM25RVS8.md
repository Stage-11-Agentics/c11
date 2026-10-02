# C11-242: c11: path mode in the New Workspace search (type ~ or / to complete a path and create there)

Follow-up to C11-240; start after it merges (same file).

When the search query starts with ~ or /, the search switches from filtering recents to a path: the first row is 'Create in <path>' for the typed path, followed by directories under it (real filesystem children, listed off the main thread, plus known recents). Tab completes the highlighted child; ⏎ creates in the typed or highlighted path even if it is not a recent; a nonexistent path shows the missing state and does not create. The row design follows the C11-240 prototype (path mode is mocked there: type ~/Projects/). Once this lands, consider with Atin whether the separate path field can shrink to a secondary control.
