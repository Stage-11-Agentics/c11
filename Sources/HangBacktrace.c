#include "HangBacktrace.h"

#if defined(__arm64__)

#include <pthread/stack_np.h>

int c11_capture_thread_backtrace(thread_t thread, uintptr_t *out, int max_frames) {
    if (out == NULL || max_frames <= 0) {
        return 0;
    }

    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64,
                         (thread_state_t)&state, &count) != KERN_SUCCESS) {
        return 0;
    }

    int n = 0;
    // Leaf frame: the program counter the thread is currently parked on.
    out[n++] = (uintptr_t)__darwin_arm_thread_state64_get_pc(state);

    // Walk the saved frame-pointer chain. pthread_stack_frame_decode_np reads
    // [fp] (next fp) and [fp+8] (return address) and strips pointer-auth bits
    // from both — the part a pure-Swift walk can't do without ptrauth intrinsics.
    uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(state);
    while (fp != 0 && (fp & 0xF) == 0 && n < max_frames) {
        uintptr_t ret = 0;
        uintptr_t next = pthread_stack_frame_decode_np(fp, &ret);
        if (ret != 0) {
            out[n++] = ret;
        }
        // Frame pointers must climb monotonically; anything else means a corrupt
        // or exhausted chain.
        if (next <= fp) {
            break;
        }
        fp = next;
    }
    return n;
}

#else

int c11_capture_thread_backtrace(thread_t thread, uintptr_t *out, int max_frames) {
    (void)thread;
    (void)out;
    (void)max_frames;
    return 0;
}

#endif /* __arm64__ */
