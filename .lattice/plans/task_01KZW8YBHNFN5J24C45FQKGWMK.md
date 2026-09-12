# C11-210: c11 CLI aborts with SIGABRT when its stdout/stderr pipe closes

The c11 CLI raised NSFileHandleOperationException from FileHandle.write(_:) when the far end of its stderr/stdout pipe was gone, and aborted.

An ObjC exception cannot unwind through Swift frames — there is no landing pad — so the throw goes __cxa_throw -> failed_throw -> std::terminate -> abort. The existing NSSetUncaughtExceptionHandler guard in CMUXTermMain.main() (which checks for .fileHandleOperationException and exits 0) never gets the chance to run. SIGPIPE was already SIG_IGN, which is why the failure surfaced as a raised exception rather than a signal.

Observed in production 2026-08-12: crash report c11-2026-08-12-185921.ips, PID 79541, procPath /Applications/c11.app/Contents/Resources/bin/c11, EXC_CRASH/SIGABRT, abort() called, frames -[NSConcreteFileHandle writeData:] <- CMUXTermMain.main(). The CLI hit a socket error while the app was shutting down, tried to print it to a stderr pipe whose reader had already gone, and aborted.

FIX: added FileHandle.c11SafeWrite(_:) — a write(2) loop that handles EINTR and drops EPIPE/EBADF silently — and routed all 10 CLI stderr/stdout write sites through it. Failure is now a return value, never a raise.

PROOF (scratchpad epipe_test.py: spawn the CLI with a forced socket error and stderr as a pipe whose read end is closed):
  OLD binary (v0.61.0 build 123): exit=-6 SIGABRT, 3/3
  NEW binary:                     exit=1  clean,   3/3
Normal behavior verified unaffected: stderr messages still reach a live reader, stdout help and version unchanged.

Ships in v0.64.0.
