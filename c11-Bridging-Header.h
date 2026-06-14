// Swift ↔ C bridging header. Exposes libghostty's C API to the Swift codebase
// (terminal surfaces, key event plumbing, renderer lifecycle).
#import "ghostty.h"

// Cross-thread main-thread stack capture for MainThreadHangMonitor.
// Path-qualified deliberately: a quote-include resolves relative to this header's
// own directory (the repo root), so it does not depend on HEADER_SEARCH_PATHS.
#import "Sources/HangBacktrace.h"
