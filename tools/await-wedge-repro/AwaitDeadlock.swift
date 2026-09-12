import Foundation

// Repro for the c11 v2AwaitCallback main-thread wedge (observed on v0.61.0 build 123,
// code byte-identical at release/v0.64.0).
//
// Reproduces the exact frame shape captured from the wedged prod process:
//   __CFRunLoopRun
//     -> _dispatch_main_queue_drain
//       -> _dispatch_async_and_wait_invoke      (socket cmd hops to main via asyncAndWait)
//         -> v2AwaitCallback
//           -> CFRunLoopRunInMode               (the C11-165 sliced pump)
//
// Question under test, in two parts:
//   Q1. Does a main-queue-delivered callback (how WKWebView delivers
//       evaluateJavaScript completion handlers) arrive while the nested pump runs?
//   Q2. Does the monotonic deadline loop unwind on time when it does NOT arrive?
//
// Q2 is the one that matters. The shipped comment asserts the loop "still pumps
// main-queue blocks, so main is not frozen." Prod contradicts that: 23+ min of
// continuous stall with a 61s worst-case timeout.

let CASE = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mainqueue"
let TIMEOUT: TimeInterval = 3.0

// Verbatim port of v2AwaitCallback's main-thread branch (BrowserHandlers.swift:314-347).
func awaitCallback<T>(timeout: TimeInterval, start: (@escaping (T) -> Void) -> Void) -> T? {
    var resolved = false
    var result: T?

    let finish: (T) -> Void = { value in
        guard !resolved else { return }
        resolved = true
        result = value
    }

    start(finish)
    guard !resolved else { return result }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var slices = 0
    while !resolved && ProcessInfo.processInfo.systemUptime < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
        slices += 1
    }
    FileHandle.standardError.write("  [pump] slices=\(slices) resolved=\(resolved)\n".data(using: .utf8)!)
    return resolved ? result : nil
}

// Watchdog on a detached thread: if the deadline loop fails to unwind, say so out loud
// rather than hanging the harness the way prod hung.
let watchdog = Thread {
    Thread.sleep(forTimeInterval: TIMEOUT + 7.0)
    FileHandle.standardError.write(
        "\nWEDGED: deadline loop did NOT unwind \(Int(TIMEOUT + 7))s after a \(TIMEOUT)s timeout — reproduced\n"
            .data(using: .utf8)!)
    exit(3)
}
watchdog.start()

let socketThread = DispatchQueue(label: "socket-cmd")

socketThread.async {
    print("[socket] dispatching to main via asyncAndWait (matches prod stack)")

    // This is the frame that makes the nested pump reentrant on an in-progress drain.
    DispatchQueue.main.asyncAndWait {
        precondition(Thread.isMainThread)
        let t0 = ProcessInfo.processInfo.systemUptime

        let value: String? = awaitCallback(timeout: TIMEOUT) { finish in
            switch CASE {
            case "mainqueue":
                // How WebKit actually delivers evaluateJavaScript completion handlers.
                DispatchQueue.main.async {
                    print("  [delivery] main-queue block RAN")
                    finish("delivered")
                }
            case "never":
                // Page never commits a document: the handler is simply never invoked.
                // Isolates Q2 (does the deadline unwind?) from Q1 (does delivery work?).
                print("  [delivery] callback intentionally never fired")
            case "timer":
                // Control: a CFRunLoop timer source, NOT routed through the main queue.
                let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                    print("  [delivery] runloop TIMER fired")
                    finish("delivered")
                }
                RunLoop.main.add(timer, forMode: .default)
            default:
                fatalError("unknown case")
            }
        }

        let dt = ProcessInfo.processInfo.systemUptime - t0
        print(String(format: "\nRESULT case=%@ value=%@ elapsed=%.2fs (timeout=%.1fs)",
                     CASE, value ?? "nil", dt, TIMEOUT))

        let unwound = dt < TIMEOUT + 1.5
        print(unwound
              ? "VERDICT: deadline loop unwound on time."
              : "VERDICT: deadline loop OVERRAN its deadline.")
        exit(unwound ? 0 : 4)
    }
}

CFRunLoopRun()
