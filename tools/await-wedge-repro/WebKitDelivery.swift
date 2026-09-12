import AppKit
import WebKit

// Does a REAL WKWebView.evaluateJavaScript completion handler arrive while
// v2AwaitCallback's nested CFRunLoopRunInMode pump runs inside an in-progress
// main-queue drain?
//
// The sibling harness (AwaitDeadlock.swift) proved that a DispatchQueue.main.async
// delivery cannot land there. That is only decisive for c11 if WebKit actually
// delivers that way. WebKit may instead hop IPC replies onto the main RUNLOOP
// (CFRunLoopPerformBlock), which the nested pump *would* service. This harness
// settles which it is, against the real framework.
//
//   loaded   — page committed, then eval inside the nested pump
//   uncommitted — nothing ever loaded (the production scenario: 127.0.0.1 that
//                 never commits a document), then eval inside the nested pump

let CASE = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "loaded"
let TIMEOUT: TimeInterval = 3.0

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

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
    while !resolved && ProcessInfo.processInfo.systemUptime < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }
    return resolved ? result : nil
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

final class Nav: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
}
let nav = Nav()
webView.navigationDelegate = nav

let watchdog = Thread {
    Thread.sleep(forTimeInterval: TIMEOUT + 12.0)
    log("\nWEDGED: never unwound — reproduced")
    exit(3)
}
watchdog.start()

func runProbe() {
    let socketThread = DispatchQueue(label: "socket-cmd")
    socketThread.async {
        log("[socket] dispatching to main via asyncAndWait (matches prod stack)")

        // The frame that makes the nested pump reentrant on an in-progress drain.
        DispatchQueue.main.asyncAndWait {
            precondition(Thread.isMainThread)
            let t0 = ProcessInfo.processInfo.systemUptime

            let value: String? = awaitCallback(timeout: TIMEOUT) { finish in
                webView.evaluateJavaScript("1+1") { result, error in
                    log("  [delivery] evaluateJavaScript completion RAN "
                        + "(result=\(String(describing: result)) error=\(error.map { "\($0)" } ?? "nil"))")
                    finish(error == nil ? "\(result ?? "nil")" : "error")
                }
            }

            let dt = ProcessInfo.processInfo.systemUptime - t0
            log(String(format: "\nRESULT case=%@ value=%@ elapsed=%.2fs (timeout=%.1fs)",
                       CASE, value ?? "nil", dt, TIMEOUT))

            if value != nil {
                log("VERDICT: WebKit delivery LANDS inside the nested pump — this path works.")
                exit(0)
            } else {
                log("VERDICT: WebKit delivery does NOT land inside the nested pump — "
                    + "burned the full timeout holding main.")
                exit(4)
            }
        }
    }
}

switch CASE {
case "loaded":
    webView.loadHTMLString("<html><body>hi</body></html>", baseURL: nil)
    // Let the page commit on a free main thread before probing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        log("[setup] page committed=\(nav.done); probing")
        runProbe()
    }
case "uncommitted":
    // A WKWebView that was never asked to load anything.
    log("[setup] no load issued — document never commits; probing")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { runProbe() }
case "deadport":
    // The actual production scenario: a load is issued to a local dev server
    // that isn't up, so the navigation fails and no document ever commits —
    // but webView.url is non-nil, so a `url == nil` guard would NOT catch it.
    let dead = URL(string: "http://127.0.0.1:59999/never")!
    webView.load(URLRequest(url: dead))
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        log("[setup] url=\(webView.url?.absoluteString ?? "nil") "
            + "isLoading=\(webView.isLoading) committed=\(nav.done) "
            + "title=\(webView.title.map { "'\($0)'" } ?? "nil")")
        runProbe()
    }
case "hanging":
    // The real production trigger: a local dev server that ACCEPTS the TCP
    // connection but never sends a response (a wrangler/vite server still
    // starting). The provisional navigation stays in flight forever, so no
    // document ever commits — while webView.url is non-nil and isLoading true.
    let port = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "59998"
    let url = URL(string: "http://127.0.0.1:\(port)/")!
    webView.load(URLRequest(url: url))
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        log("[setup] url=\(webView.url?.absoluteString ?? "nil") "
            + "isLoading=\(webView.isLoading) committed=\(nav.done)")
        runProbe()
    }
default:
    log("unknown case"); exit(64)
}

app.run()
