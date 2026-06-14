#ifndef C11_HANG_BACKTRACE_H
#define C11_HANG_BACKTRACE_H

#include <mach/mach.h>
#include <stdint.h>

/// Capture a thread's call stack by reading its register state and walking the
/// frame-pointer chain. `out[0]` is the leaf PC; subsequent entries are
/// PAC-stripped return addresses (via `pthread_stack_frame_decode_np`).
///
/// The caller MUST `thread_suspend(thread)` before calling and `thread_resume`
/// after — this function only reads. Cross-thread safe (no calling-thread stack
/// bounds check, unlike `backtrace_from_fp`). Returns the number of addresses
/// written, 0 on failure or on non-arm64 architectures.
int c11_capture_thread_backtrace(thread_t thread, uintptr_t *out, int max_frames);

#endif /* C11_HANG_BACKTRACE_H */
