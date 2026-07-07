import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
// Browser is split across two files to stay under the per-file size ceiling;
// its handler methods are internal (not private) because the v2DispatchBrowser
// slice and the methods now span both files.
extension TerminalController {

    func v2DispatchBrowser(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        case "browser.navigate":
            return v2Result(id: id, self.v2BrowserNavigate(params: params))
        case "browser.back":
            return v2Result(id: id, self.v2BrowserBack(params: params))
        case "browser.forward":
            return v2Result(id: id, self.v2BrowserForward(params: params))
        case "browser.reload":
            return v2Result(id: id, self.v2BrowserReload(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.snapshot":
            return v2Result(id: id, self.v2BrowserSnapshot(params: params))
        case "browser.eval":
            return v2Result(id: id, self.v2BrowserEval(params: params))
        case "browser.wait":
            return v2Result(id: id, self.v2BrowserWait(params: params))
        case "browser.click":
            return v2Result(id: id, self.v2BrowserClick(params: params))
        case "browser.dblclick":
            return v2Result(id: id, self.v2BrowserDblClick(params: params))
        case "browser.hover":
            return v2Result(id: id, self.v2BrowserHover(params: params))
        case "browser.focus":
            return v2Result(id: id, self.v2BrowserFocusElement(params: params))
        case "browser.type":
            return v2Result(id: id, self.v2BrowserType(params: params))
        case "browser.fill":
            return v2Result(id: id, self.v2BrowserFill(params: params))
        case "browser.press":
            return v2Result(id: id, self.v2BrowserPress(params: params))
        case "browser.keydown":
            return v2Result(id: id, self.v2BrowserKeyDown(params: params))
        case "browser.keyup":
            return v2Result(id: id, self.v2BrowserKeyUp(params: params))
        case "browser.check":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: true))
        case "browser.uncheck":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: false))
        case "browser.select":
            return v2Result(id: id, self.v2BrowserSelect(params: params))
        case "browser.scroll":
            return v2Result(id: id, self.v2BrowserScroll(params: params))
        case "browser.scroll_into_view":
            return v2Result(id: id, self.v2BrowserScrollIntoView(params: params))
        case "browser.screenshot":
            return v2Result(id: id, self.v2BrowserScreenshot(params: params))
        case "browser.get.text":
            return v2Result(id: id, self.v2BrowserGetText(params: params))
        case "browser.get.html":
            return v2Result(id: id, self.v2BrowserGetHTML(params: params))
        case "browser.get.value":
            return v2Result(id: id, self.v2BrowserGetValue(params: params))
        case "browser.get.attr":
            return v2Result(id: id, self.v2BrowserGetAttr(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.get.count":
            return v2Result(id: id, self.v2BrowserGetCount(params: params))
        case "browser.get.box":
            return v2Result(id: id, self.v2BrowserGetBox(params: params))
        case "browser.get.styles":
            return v2Result(id: id, self.v2BrowserGetStyles(params: params))
        case "browser.is.visible":
            return v2Result(id: id, self.v2BrowserIsVisible(params: params))
        case "browser.is.enabled":
            return v2Result(id: id, self.v2BrowserIsEnabled(params: params))
        case "browser.is.checked":
            return v2Result(id: id, self.v2BrowserIsChecked(params: params))
        case "browser.find.role":
            return v2Result(id: id, self.v2BrowserFindRole(params: params))
        case "browser.find.text":
            return v2Result(id: id, self.v2BrowserFindText(params: params))
        case "browser.find.label":
            return v2Result(id: id, self.v2BrowserFindLabel(params: params))
        case "browser.find.placeholder":
            return v2Result(id: id, self.v2BrowserFindPlaceholder(params: params))
        case "browser.find.alt":
            return v2Result(id: id, self.v2BrowserFindAlt(params: params))
        case "browser.find.title":
            return v2Result(id: id, self.v2BrowserFindTitle(params: params))
        case "browser.find.testid":
            return v2Result(id: id, self.v2BrowserFindTestId(params: params))
        case "browser.find.first":
            return v2Result(id: id, self.v2BrowserFindFirst(params: params))
        case "browser.find.last":
            return v2Result(id: id, self.v2BrowserFindLast(params: params))
        case "browser.find.nth":
            return v2Result(id: id, self.v2BrowserFindNth(params: params))
        case "browser.frame.select":
            return v2Result(id: id, self.v2BrowserFrameSelect(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.dialog.accept":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: true))
        case "browser.dialog.dismiss":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: false))
        case "browser.download.wait":
            return v2Result(id: id, self.v2BrowserDownloadWait(params: params))
        case "browser.cookies.get":
            return v2Result(id: id, self.v2BrowserCookiesGet(params: params))
        case "browser.cookies.set":
            return v2Result(id: id, self.v2BrowserCookiesSet(params: params))
        case "browser.cookies.clear":
            return v2Result(id: id, self.v2BrowserCookiesClear(params: params))
        case "browser.storage.get":
            return v2Result(id: id, self.v2BrowserStorageGet(params: params))
        case "browser.storage.set":
            return v2Result(id: id, self.v2BrowserStorageSet(params: params))
        case "browser.storage.clear":
            return v2Result(id: id, self.v2BrowserStorageClear(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.console.list":
            return v2Result(id: id, self.v2BrowserConsoleList(params: params))
        case "browser.console.clear":
            return v2Result(id: id, self.v2BrowserConsoleClear(params: params))
        case "browser.errors.list":
            return v2Result(id: id, self.v2BrowserErrorsList(params: params))
        case "browser.highlight":
            return v2Result(id: id, self.v2BrowserHighlight(params: params))
        case "browser.state.save":
            return v2Result(id: id, self.v2BrowserStateSave(params: params))
        case "browser.state.load":
            return v2Result(id: id, self.v2BrowserStateLoad(params: params))
        case "browser.addinitscript":
            return v2Result(id: id, self.v2BrowserAddInitScript(params: params))
        case "browser.addscript":
            return v2Result(id: id, self.v2BrowserAddScript(params: params))
        case "browser.addstyle":
            return v2Result(id: id, self.v2BrowserAddStyle(params: params))
        case "browser.viewport.set":
            return v2Result(id: id, self.v2BrowserViewportSet(params: params))
        case "browser.geolocation.set":
            return v2Result(id: id, self.v2BrowserGeolocationSet(params: params))
        case "browser.offline.set":
            return v2Result(id: id, self.v2BrowserOfflineSet(params: params))
        case "browser.trace.start":
            return v2Result(id: id, self.v2BrowserTraceStart(params: params))
        case "browser.trace.stop":
            return v2Result(id: id, self.v2BrowserTraceStop(params: params))
        case "browser.network.route":
            return v2Result(id: id, self.v2BrowserNetworkRoute(params: params))
        case "browser.network.unroute":
            return v2Result(id: id, self.v2BrowserNetworkUnroute(params: params))
        case "browser.network.requests":
            return v2Result(id: id, self.v2BrowserNetworkRequests(params: params))
        case "browser.screencast.start":
            return v2Result(id: id, self.v2BrowserScreencastStart(params: params))
        case "browser.screencast.stop":
            return v2Result(id: id, self.v2BrowserScreencastStop(params: params))
        case "browser.input_mouse":
            return v2Result(id: id, self.v2BrowserInputMouse(params: params))
        case "browser.input_keyboard":
            return v2Result(id: id, self.v2BrowserInputKeyboard(params: params))
        case "browser.input_touch":
            return v2Result(id: id, self.v2BrowserInputTouch(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    func v2JSONLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    func v2NormalizeJSValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is V2BrowserUndefinedSentinel {
            return [
                Self.v2BrowserEvalEnvelopeTypeKey: Self.v2BrowserEvalEnvelopeTypeUndefined,
                Self.v2BrowserEvalEnvelopeValueKey: NSNull()
            ]
        }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = v2NormalizeJSValue(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { v2NormalizeJSValue($0) }
        }
        return String(describing: value)
    }

    func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        contentWorld: WKContentWorld
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            if preferAsync, #available(macOS 11.0, *) {
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                    switch result {
                    case .success(let value):
                        finish(value, nil)
                    case .failure(let error):
                        finish(nil, error.localizedDescription)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        finish(nil, error.localizedDescription)
                    } else {
                        finish(value, nil)
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        if Thread.isMainThread {
            // C11-165 COR-3: pump the main run loop in short slices instead of
            // one CFRunLoopRun stopped via CFRunLoopStop. Concurrent browser
            // commands nest this call, and CFRunLoopStop only stops the
            // *innermost* run loop — so an outer invocation's stop was swallowed
            // and its socket thread wedged permanently (audit P0.4). Slicing
            // lets each nested invocation observe its OWN `resolved` flag and
            // deadline and unwind independently. The loop still pumps events
            // (WebKit completion callbacks, rendering, main-queue blocks), so
            // main is not frozen and WebKit calls stay on their required main
            // thread — the reason this path runs on main at all.
            var resolved = false
            var result: T?

            let finish: (T) -> Void = { value in
                guard !resolved else { return }
                resolved = true
                result = value
            }

            start(finish)
            guard !resolved else { return result }

            // Monotonic deadline (systemUptime, mach-based) so an NTP/clock
            // change during the await can't distort the timeout. Each slice
            // blocks the full 50ms draining sources (returnAfterSourceHandled:
            // false) rather than returning after one source — otherwise steady
            // main-thread source traffic (WebKit render callbacks, timers) would
            // busy-spin the loop for the whole timeout window.
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !resolved && ProcessInfo.processInfo.systemUptime < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.05, false)
            }
            return resolved ? result : nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T?
        start { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> Bool {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true
        case .failure:
            return false
        }
    }

    func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(v2BrowserNextElementOrdinal)"
        v2BrowserNextElementOrdinal += 1
        v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(surfaceId: surfaceId, selector: selector)
        return ref
    }

    func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = v2BrowserElementRefs[refKey], entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }

    func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2BrowserFrameSelectorBySurface[surfaceId]
    }

    func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> V2JavaScriptResult {
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """

        var rawResult: V2JavaScriptResult
        if #available(macOS 11.0, *) {
            rawResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .page
            )
        } else {
            let evaluateFallback = """
            (async () => {
              \(asyncFunctionBody)
            })()
            """
            rawResult = v2RunJavaScript(webView, script: evaluateFallback, timeout: timeout, contentWorld: .page)
        }

        if !useEval, case .failure(let pageMessage) = rawResult, #available(macOS 11.0, *) {
            let isolatedResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .defaultClient
            )
            switch isolatedResult {
            case .success:
                rawResult = isolatedResult
            case .failure(let isolatedMessage):
                if isolatedMessage != pageMessage {
                    rawResult = .failure("\(pageMessage) (isolated-world retry: \(isolatedMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .success(value)
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .success(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .success(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .success(value)
            }
        }
    }

    func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    func v2BrowserPendingDialogs(surfaceId: UUID) -> [[String: Any]] {
        let queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        return queue.enumerated().map { index, d in
            [
                "index": index,
                "type": d.type,
                "message": d.message,
                "default_text": v2OrNull(d.defaultText)
            ]
        }
    }

    func v2BrowserPopDialog(surfaceId: UUID) -> V2BrowserPendingDialog? {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        guard !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        v2BrowserDialogQueueBySurface[surfaceId] = queue
        return first
    }

    func v2BrowserEnsureInitScriptsApplied(surfaceId: UUID, browserPanel: BrowserPanel) {
        let scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
        let styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
        guard !scripts.isEmpty || !styles.isEmpty else { return }

        let injector = """
        (() => {
          window.__cmuxInitScriptsApplied = window.__cmuxInitScriptsApplied || { scripts: [], styles: [] };
          return true;
        })()
        """
        _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: injector)

        for script in scripts {
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script)
        }
        for css in styles {
            let cssLiteral = v2JSONLiteral(css)
            let styleScript = """
            (() => {
              const id = 'cmux-init-style-' + btoa(unescape(encodeURIComponent(\(cssLiteral)))).replace(/=+$/g, '');
              if (document.getElementById(id)) return true;
              const el = document.createElement('style');
              el.id = id;
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: styleScript)
        }
    }

    func v2BrowserOpenSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let respectExternalOpenRules = v2Bool(params, "respect_external_open_rules") ?? false

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let url,
               respectExternalOpenRules,
               BrowserLinkOpenSettings.shouldOpenExternally(url) {
                guard NSWorkspace.shared.open(url) else {
                    result = .err(
                        code: "external_open_failed",
                        message: "Failed to open URL externally",
                        data: ["url": url.absoluteString]
                    )
                    return
                }
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(nil),
                    "pane_ref": v2Ref(kind: .pane, uuid: nil),
                    "surface_id": v2OrNull(nil),
                    "surface_ref": v2Ref(kind: .surface, uuid: nil),
                    "created_split": false,
                    "placement_strategy": "external",
                    "opened_externally": true,
                    "url": url.absoluteString
                ])
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            var createdSplit = true
            var placementStrategy = "split_right"
            let createdPanel: BrowserPanel?
            if let targetPane = ws.preferredBrowserTargetPane(fromPanelId: sourceSurfaceId) {
                createdPanel = ws.newBrowserSurface(inPane: targetPane, url: url, focus: true)
                createdSplit = false
                placementStrategy = "reuse_right_sibling"
            } else {
                createdPanel = ws.newBrowserSplit(from: sourceSurfaceId, orientation: .horizontal, url: url)
            }

            guard let browserPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create browser", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": browserPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: browserPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "created_split": createdSplit,
                "placement_strategy": placementStrategy
            ])
        }
        return result
    }

    func v2BrowserNavigate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let url = v2String(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            browserPanel.navigateSmart(url)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    func v2BrowserBack(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "back")
    }

    func v2BrowserForward(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "forward")
    }

    func v2BrowserReload(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "reload")
    }

    func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let selectorLiteral = v2JSONLiteral(selector)
        let script = """
        (() => {
          const __selector = \(selectorLiteral);
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = v2NormalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    func v2BrowserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        browserPanel: BrowserPanel
    ) -> V2CallResult {
        var data = v2BrowserNotFoundDiagnostics(surfaceId: surfaceId, browserPanel: browserPanel, selector: selector)
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message: String
        if count > 0 && visibleCount == 0 {
            message = "Element \"\(selector)\" is present but not visible."
        } else if count > 1 {
            message = "Selector \"\(selector)\" matched multiple elements."
        } else {
            message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }

        return .err(code: "not_found", message: message, data: data)
    }

    func v2BrowserAppendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any]
    ) {
        guard v2Bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": v2Bool(params, "snapshot_interactive") ?? true,
            "cursor": v2Bool(params, "snapshot_cursor") ?? false,
            "compact": v2Bool(params, "snapshot_compact") ?? true,
            "max_depth": max(0, v2Int(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = v2String(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = v2OrNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(v2JSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, useEval: false) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ws.id.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard v2WaitForBrowserCondition(
                            browserPanel.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return v2BrowserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                browserPanel: browserPanel
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return v2BrowserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return v2BrowserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                browserPanel: browserPanel
            )
        }
    }

    func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12)
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let interactiveLiteral = interactiveOnly ? "true" : "false"
            let cursorLiteral = includeCursor ? "true" : "false"
            let compactLiteral = compact ? "true" : "false"
            let scopeLiteral = scopeSelector.map(v2JSONLiteral) ?? "null"

            let script = """
            (() => {
              const __interactiveOnly = \(interactiveLiteral);
              const __includeCursor = \(cursorLiteral);
              const __compact = \(compactLiteral);
              const __maxDepth = \(maxDepth);
              const __scopeSelector = \(scopeLiteral);

              const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
              const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
              const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
              const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

              const __isVisible = (el) => {
                try {
                  if (!el) return false;
                  const style = getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  if (!style || !rect) return false;
                  if (rect.width <= 0 || rect.height <= 0) return false;
                  if (style.display === 'none' || style.visibility === 'hidden') return false;
                  if (parseFloat(style.opacity || '1') <= 0.01) return false;
                  return true;
                } catch (_) {
                  return false;
                }
              };

              const __implicitRole = (el) => {
                const tag = String(el.tagName || '').toLowerCase();
                if (tag === 'button') return 'button';
                if (tag === 'a' && el.hasAttribute('href')) return 'link';
                if (tag === 'input') {
                  const type = String(el.getAttribute('type') || 'text').toLowerCase();
                  if (type === 'checkbox') return 'checkbox';
                  if (type === 'radio') return 'radio';
                  if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
                  return 'textbox';
                }
                if (tag === 'textarea') return 'textbox';
                if (tag === 'select') return 'combobox';
                if (tag === 'summary') return 'button';
                if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
                if (tag === 'li') return 'listitem';
                return null;
              };

              const __nameFor = (el) => {
                const aria = __normalize(el.getAttribute('aria-label') || '');
                if (aria) return aria;
                const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
                if (labelledBy) {
                  const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
                  if (text) return text;
                }
                if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
                  const placeholder = __normalize(el.getAttribute('placeholder') || '');
                  if (placeholder) return placeholder;
                  const value = __normalize(el.value || '');
                  if (value) return value;
                }
                const title = __normalize(el.getAttribute('title') || '');
                if (title) return title;
                const text = __normalize(el.innerText || el.textContent || '');
                if (text) return text.slice(0, 120);
                return '';
              };

              const __cssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  const parent = cur.parentElement;
                  if (parent) {
                    const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                    if (siblings.length > 1) {
                      const index = siblings.indexOf(cur) + 1;
                      part += `:nth-of-type(${index})`;
                    }
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                  if (parts.length >= 6) break;
                }
                return parts.join(' > ');
              };

              const __root = (() => {
                if (__scopeSelector) {
                  return document.querySelector(__scopeSelector) || document.body || document.documentElement;
                }
                return document.body || document.documentElement;
              })();

              const __entries = [];
              const __seen = new Set();
              const __appendEntry = (el, depth, forcedRole) => {
                if (!__isVisible(el)) return;
                const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
                const role = forcedRole || explicitRole || __implicitRole(el) || '';
                if (!role) return;

                if (__interactiveOnly && !__interactiveRoles.has(role)) return;
                if (!__interactiveOnly) {
                  const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
                  if (!includeRole) return;
                  if (__compact && __structuralRoles.has(role)) {
                    const name = __nameFor(el);
                    if (!name) return;
                  }
                }

                const selector = __cssPath(el);
                if (!selector || __seen.has(selector)) return;
                __seen.add(selector);
                __entries.push({
                  selector,
                  role,
                  name: __nameFor(el),
                  depth
                });
              };

              const __walk = (node, depth) => {
                if (!node || depth > __maxDepth || node.nodeType !== 1) return;
                const el = node;
                __appendEntry(el, depth, null);
                for (const child of Array.from(el.children || [])) {
                  __walk(child, depth + 1);
                }
              };

              if (__root) {
                __walk(__root, 0);
              }

              if (__includeCursor && __root) {
                const all = Array.from(__root.querySelectorAll('*'));
                for (const el of all) {
                  if (!__isVisible(el)) continue;
                  const style = getComputedStyle(el);
                  const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
                  const hasCursorPointer = style.cursor === 'pointer';
                  const tabIndex = el.getAttribute('tabindex');
                  const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
                  if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
                  __appendEntry(el, 0, 'generic');
                  if (__entries.length >= 256) break;
                }
              }

              const body = document.body;
              const root = document.documentElement;
              return {
                title: __normalize(document.title || ''),
                url: String(location.href || ''),
                ready_state: String(document.readyState || ''),
                text: body ? String(body.innerText || '') : '',
                html: root ? String(root.outerHTML || '') : '',
                entries: __entries
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0, useEval: false) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let refToken = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                return .ok(payload)
            }
        }
    }

    func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = v2BrowserSelector(params)

        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                let literal = v2JSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = v2String(params, "text_contains") {
                let literal = v2JSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = v2JSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = v2String(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        var setupResult: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var webView: WKWebView?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupResult = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupResult = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                setupResult = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                setupResult = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            workspaceId = ws.id
            surfaceIdOut = surfaceId
            webView = browserPanel.webView
        }

        if let setupResult {
            return setupResult
        }
        guard let workspaceId, let surfaceIdOut, let webView else {
            return .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let literal = v2JSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        if v2WaitForBrowserCondition(
            webView,
            surfaceId: surfaceIdOut,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "waited": true
            ])
        }
        return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
    }

    func v2BrowserClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "click") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof el.click === 'function') {
                el.click();
              } else {
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
              }
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserDblClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window, detail: 2 }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserHover(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
              el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserFocusElement(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "focus") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserType(params: [String: Any]) -> V2CallResult {
        guard let text = v2String(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "type") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const chunk = String(\(textLiteral));
              if ('value' in el) {
                el.value = (el.value || '') + chunk;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = (el.textContent || '') + chunk;
              }
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserFill(params: [String: Any]) -> V2CallResult {
        // `fill` must allow empty strings so callers can clear existing input values.
        guard let text = v2RawString(params, "text") ?? v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing text/value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "fill") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const value = String(\(textLiteral));
              if ('value' in el) {
                el.value = value;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = value;
              }
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserPress(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keypress', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserKeyDown(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserKeyUp(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserCheck(params: [String: Any], checked: Bool) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
              el.checked = \(checked ? "true" : "false");
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserSelect(params: [String: Any]) -> V2CallResult {
        let selectedValue = v2String(params, "value") ?? v2String(params, "text")
        guard let selectedValue else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "select") { selectorLiteral in
            let valueLiteral = v2JSONLiteral(selectedValue)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('value' in el)) return { ok: false, error: 'not_select' };
              el.value = String(\(valueLiteral));
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserScroll(params: [String: Any]) -> V2CallResult {
        let dx = v2Int(params, "dx") ?? 0
        let dy = v2Int(params, "dy") ?? 0
        let selectorRaw = v2BrowserSelector(params)

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let selector = selectorRaw.flatMap { v2BrowserResolveSelector($0, surfaceId: surfaceId) }
            if selectorRaw != nil && selector == nil {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw ?? ""])
            }

            let script: String
            if let selector {
                let selectorLiteral = v2JSONLiteral(selector)
                script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.scrollBy === 'function') {
                    el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
                  } else {
                    el.scrollLeft += \(dx);
                    el.scrollTop += \(dy);
                  }
                  return { ok: true };
                })()
                """
            } else {
                script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
            }

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return v2BrowserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    func v2BrowserScrollIntoView(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "scroll_into_view") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let snapshotResult: Data?? = v2AwaitCallback(timeout: 5.0) { finish in
                browserPanel.takeSnapshot { image in
                    finish(image.flatMap { self.v2PNGData(from: $0) })
                }
            }

            guard let snapshotResult else {
                return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
            }
            guard let imageData = snapshotResult else {
                return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
            }

            var result: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "png_base64": imageData.base64EncodedString()
            ]

            // Best effort: keep screenshot data available even when temp-file writes fail.
            let screenshotsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
                bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
                let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
                let shortRandomId = String(UUID().uuidString.prefix(8))
                let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
                let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
                if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                    result["path"] = imageURL.path
                    result["url"] = imageURL.absoluteString
                }
            }

            return .ok(result)
        }
    }

    func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = v2JSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    func v2BrowserGetTitle(params: [String: Any]) -> V2CallResult {
        v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "title": browserPanel.pageTitle
            ])
        }
    }

    func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = v2JSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

}
