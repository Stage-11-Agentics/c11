// Swift ↔ C bridging header. Exposes libghostty's C API to the Swift codebase
// (terminal surfaces, key event plumbing, renderer lifecycle).
#import "ghostty.h"

// Cross-thread main-thread stack capture for MainThreadHangMonitor.
#import "Sources/HangBacktrace.h"
