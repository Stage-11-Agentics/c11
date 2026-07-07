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

    func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }

    func v2BrowserNavSimple(params: [String: Any], action: String) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            switch action {
            case "back":
                browserPanel.goBack()
            case "forward":
                browserPanel.goForward()
            case "reload":
                browserPanel.reload()
            default:
                break
            }
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

    func v2BrowserGetURL(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "url": browserPanel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    func v2BrowserFocusWebView(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.0)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = .err(code: "invalid_state", message: "WebView is not in a window", data: nil)
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = .err(code: "invalid_state", message: "WebView is hidden", data: nil)
                return
            }

            window.makeFirstResponder(webView)
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                result = .ok(["focused": true])
            } else {
                result = .err(code: "internal_error", message: "Focus did not move into web view", data: nil)
            }
        }
        return result
    }

    func v2BrowserIsWebViewFocused(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var focused = false
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            let webView = browserPanel.webView
            guard let window = webView.window,
                  let fr = window.firstResponder as? NSView else {
                focused = false
                return
            }
            focused = fr.isDescendant(of: webView)
        }
        return .ok(["focused": focused])
    }

    func v2BrowserFindWithScript(
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadata: [String: Any] = [:]
    ) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let script = """
            (() => {
              const __cmuxCssPath = (el) => {
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
                  let siblings = cur.parentElement ? Array.from(cur.parentElement.children).filter((n) => String(n.tagName || '').toLowerCase() === tag) : [];
                  if (siblings.length > 1) {
                    const pos = siblings.indexOf(cur) + 1;
                    part += `:nth-of-type(${pos})`;
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                }
                return parts.join(' > ');
              };

              const __cmuxFound = (() => {
            \(finderBody)
              })();
              if (!__cmuxFound) return { ok: false, error: 'not_found' };
              const selector = __cmuxCssPath(__cmuxFound);
              if (!selector) return { ok: false, error: 'not_found' };
              return {
                ok: true,
                selector,
                tag: String(__cmuxFound.tagName || '').toLowerCase(),
                text: String(__cmuxFound.textContent || '').trim()
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: ["action": actionName])
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: metadata)
                }

                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "action": actionName,
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref
                ]
                for (k, v) in metadata {
                    payload[k] = v
                }
                if let tag = dict["tag"] as? String {
                    payload["tag"] = tag
                }
                if let text = dict["text"] as? String {
                    payload["text"] = text
                }
                return .ok(payload)
            }
        }
    }

    func v2BrowserFindRole(params: [String: Any]) -> V2CallResult {
        guard let role = (v2String(params, "role") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = v2String(params, "name")?.lowercased()
        let exact = v2Bool(params, "exact") ?? false
        let roleLiteral = v2JSONLiteral(role)
        let nameLiteral = name.map(v2JSONLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __targetRole = String(\(roleLiteral)).toLowerCase();
                const __targetName = \(nameLiteral);
                const __exact = \(exactLiteral);
                const __implicitRole = (el) => {
                  const tag = String(el.tagName || '').toLowerCase();
                  if (tag === 'button') return 'button';
                  if (tag === 'a' && el.hasAttribute('href')) return 'link';
                  if (tag === 'input') {
                    const type = String(el.getAttribute('type') || 'text').toLowerCase();
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit' || type === 'button') return 'button';
                    return 'textbox';
                  }
                  if (tag === 'textarea') return 'textbox';
                  if (tag === 'select') return 'combobox';
                  return null;
                };
                const __nameFor = (el) => {
                  const aria = String(el.getAttribute('aria-label') || '').trim();
                  if (aria) return aria.toLowerCase();
                  const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                  if (labelledBy) {
                    const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                    if (text) return text.toLowerCase();
                  }
                  const txt = String(el.innerText || el.textContent || '').trim();
                  if (txt) return txt.toLowerCase();
                  if ('value' in el) {
                    const v = String(el.value || '').trim();
                    if (v) return v.toLowerCase();
                  }
                  return '';
                };
                const __nodes = Array.from(document.querySelectorAll('*'));
                return __nodes.find((el) => {
                  const explicit = String(el.getAttribute('role') || '').toLowerCase();
                  const resolved = explicit || __implicitRole(el) || '';
                  if (resolved !== __targetRole) return false;
                  if (__targetName == null) return true;
                  const currentName = __nameFor(el);
                  return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.role",
            finderBody: finder,
            metadata: [
                "role": role,
                "name": v2OrNull(name),
                "exact": exact
            ]
        )
    }

    func v2BrowserFindText(params: [String: Any]) -> V2CallResult {
        guard let text = (v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let textLiteral = v2JSONLiteral(text)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(textLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __nodes = Array.from(document.querySelectorAll('body *'));
                return __nodes.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  if (!v) return false;
                  return __exact ? (v === __target) : v.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.text",
            finderBody: finder,
            metadata: ["text": text, "exact": exact]
        )
    }

    func v2BrowserFindLabel(params: [String: Any]) -> V2CallResult {
        guard let label = (v2String(params, "label") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let labelLiteral = v2JSONLiteral(label)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(labelLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __labels = Array.from(document.querySelectorAll('label'));
                const __label = __labels.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  return __exact ? (v === __target) : v.includes(__target);
                });
                if (!__label) return null;
                const htmlFor = String(__label.getAttribute('for') || '').trim();
                if (htmlFor) {
                  return document.getElementById(htmlFor);
                }
                return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.label",
            finderBody: finder,
            metadata: ["label": label, "exact": exact]
        )
    }

    func v2BrowserFindPlaceholder(params: [String: Any]) -> V2CallResult {
        guard let placeholder = (v2String(params, "placeholder") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let placeholderLiteral = v2JSONLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadata: ["placeholder": placeholder, "exact": exact]
        )
    }

    func v2BrowserFindAlt(params: [String: Any]) -> V2CallResult {
        guard let alt = (v2String(params, "alt") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let altLiteral = v2JSONLiteral(alt)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.alt",
            finderBody: finder,
            metadata: ["alt": alt, "exact": exact]
        )
    }

    func v2BrowserFindTitle(params: [String: Any]) -> V2CallResult {
        guard let title = (v2String(params, "title") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let titleLiteral = v2JSONLiteral(title)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.title",
            finderBody: finder,
            metadata: ["title": title, "exact": exact]
        )
    }

    func v2BrowserFindTestId(params: [String: Any]) -> V2CallResult {
        guard let testId = v2String(params, "testid") ?? v2String(params, "test_id") ?? v2String(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let testIdLiteral = v2JSONLiteral(testId)

        let finder = """
                const __target = String(\(testIdLiteral));
                const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                for (const sel of __selectors) {
                  const nodes = Array.from(document.querySelectorAll(sel));
                  const found = nodes.find((el) => {
                    return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                  });
                  if (found) return found;
                }
                return null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.testid",
            finderBody: finder,
            metadata: ["testid": testId]
        )
    }

    func v2BrowserFindFirst(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    func v2BrowserFindLast(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = document.querySelectorAll(\(selectorLiteral));
              if (!list || list.length === 0) return { ok: false, error: 'not_found' };
              const idx = list.length - 1;
              const el = list[idx];
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
              return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    func v2BrowserFindNth(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = v2Int(params, "index") ?? v2Int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              const nth = idx + 1;
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${nth})`;
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector, "index": index])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "index": v2OrNull(dict["index"]),
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2BrowserFrameSelectorBySurface[surfaceId] = selector
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "frame_selector": selector
                    ])
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .err(code: "not_supported", message: "Cross-origin iframe control is not supported", data: ["selector": selector])
                }
                return .err(code: "not_found", message: "Frame not found", data: ["selector": selector])
            }
        }
    }

    func v2BrowserFrameMain(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func v2BrowserEnsureDialogHooks(browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.dialogTelemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            v2BrowserEnsureDialogHooks(browserPanel: browserPanel)
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__cmuxDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__cmuxDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__cmuxDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: surfaceId)
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": pending])
                }

                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ])
            }
        }
    }

    func v2BrowserDownloadWait(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 10_000)
            let timeout = Double(timeoutMs) / 1000.0
            let path = v2String(params, "path")

            if let path {
                let fm = FileManager.default
                let pathIsReady = {
                    guard fm.fileExists(atPath: path),
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let size = attrs[.size] as? NSNumber else {
                        return false
                    }
                    return size.intValue > 0
                }
                if pathIsReady() {
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "path": path,
                        "downloaded": true
                    ])
                }

                let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
                let fd = open(watchedPath, O_EVTONLY)
                guard fd >= 0 else {
                    return .err(code: "internal_error", message: "Failed to watch download path", data: ["path": path])
                }
                defer { close(fd) }

                let ready = v2AwaitCallback(timeout: timeout) { finish in
                    var source: DispatchSourceFileSystemObject?
                    var timeoutWorkItem: DispatchWorkItem?
                    var finished = false
                    let finishOnce: (Bool) -> Void = { value in
                        guard !finished else { return }
                        finished = true
                        timeoutWorkItem?.cancel()
                        source?.cancel()
                        finish(value)
                    }
                    source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: [.write, .extend, .attrib, .link, .rename],
                        queue: .main
                    )
                    source?.setEventHandler {
                        if pathIsReady() {
                            finishOnce(true)
                        }
                    }
                    source?.setCancelHandler {
                        source = nil
                    }
                    source?.resume()
                    timeoutWorkItem = DispatchWorkItem {
                        finishOnce(pathIsReady())
                    }
                    if let timeoutWorkItem {
                        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
                    }
                    if pathIsReady() {
                        finishOnce(true)
                    }
                } ?? false
                guard ready else {
                    return .err(code: "timeout", message: "Timed out waiting for download file", data: ["path": path, "timeout_ms": timeoutMs])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "path": path,
                    "downloaded": true
                ])
            }

            if let first = v2BrowserDownloadEventsBySurface[surfaceId]?.first {
                var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                remaining.removeFirst()
                v2BrowserDownloadEventsBySurface[surfaceId] = remaining
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "download": first
                ])
            }

            let downloadEvent = v2AwaitCallback(timeout: timeout) { finish in
                var observer: NSObjectProtocol?
                observer = NotificationCenter.default.addObserver(
                    forName: .browserDownloadEventDidArrive,
                    object: nil,
                    queue: .main
                ) { note in
                    guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                          candidateSurfaceId == surfaceId,
                          let event = note.userInfo?["event"] as? [String: Any] else {
                        return
                    }
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    finish(event)
                }
            }
            guard let downloadEvent else {
                return .err(code: "timeout", message: "No download event observed", data: ["timeout_ms": timeoutMs])
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "download": downloadEvent
            ])
        }
    }

    func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            store.getAllCookies { items in
                finish(items)
            }
        }
    }

    func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.setCookie(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.delete(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cookies": cookies.map(v2BrowserCookieDict)
            ])
        }
    }

    func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = browserPanel.currentURL

            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty {
                    cookieObjects = [single]
                }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "set": setCount
            ])
        }
    }

    func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let clearAll = params["all"] == nil && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cleared": removed
            ])
        }
    }

    func v2BrowserStorageType(_ params: [String: Any]) -> String {
        let type = (v2String(params, "storage") ?? v2String(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = key.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ])
            }
        }
    }

    func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = v2JSONLiteral(key)
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value))
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": key
                ])
            }
        }
    }

    func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "cleared": true
                ])
            }
        }
    }

    func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
                [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "title": panel.displayTitle,
                    "url": panel.currentURL?.absoluteString ?? "",
                    "focused": panel.id == ws.focusedPanelId,
                    "pane_id": v2OrNull(ws.paneId(forPanelId: panel.id)?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: ws.paneId(forPanelId: panel.id)?.id)
                ]
            }
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": v2OrNull(ws.focusedPanelId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "tabs": tabs
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let url = v2String(params, "url").flatMap(URL.init(string:))
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let paneUUID = v2UUID(params, "pane_id")
                ?? v2UUID(params, "target_pane_id")
                ?? (v2UUID(params, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found", data: nil)
                return
            }

            guard let panel = ws.newBrowserSurface(inPane: pane, url: url, focus: true) else {
                result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                return
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": pane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: pane.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "url": panel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    func v2BrowserTabSwitch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return v2UUID(params, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            ws.focusPanel(targetId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": targetId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: targetId)
            ])
        }
        return result
    }

    func v2BrowserTabClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                result = .err(code: "not_found", message: "No browser tabs", data: nil)
                return
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = v2UUID(params, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            let ok = ws.closePanel(targetId, force: true)
            result = ok
                ? .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": targetId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                ])
                : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
        }
        return result
    }

    func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : [];
              if (\(clearLiteral)) {
                window.__cmuxConsoleLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [];
              if (\(clearLiteral)) {
                window.__cmuxErrorLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    func v2BrowserHighlight(params: [String: Any]) -> V2CallResult {
        return v2BrowserSelectorAction(params: params, actionName: "highlight") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const prev = el.style.outline;
              const prevOffset = el.style.outlineOffset;
              el.style.outline = '3px solid #ff9f0a';
              el.style.outlineOffset = '2px';
              setTimeout(() => {
                el.style.outline = prev;
                el.style.outlineOffset = prevOffset;
              }, 1200);
              return { ok: true };
            })()
            """
        }
    }

    func v2BrowserStateSave(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let storageScript = """
            (() => {
              const readStorage = (st) => {
                const out = {};
                if (!st) return out;
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return out;
              };
              return {
                local: readStorage(window.localStorage),
                session: readStorage(window.sessionStorage)
              };
            })()
            """

            let storageValue: Any
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (v2BrowserCookieStoreAll(store) ?? []).map(v2BrowserCookieDict)

            let state: [String: Any] = [
                "url": browserPanel.currentURL?.absoluteString ?? "",
                "cookies": cookies,
                "storage": storageValue,
                "frame_selector": v2OrNull(v2BrowserFrameSelectorBySurface[surfaceId])
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(code: "internal_error", message: "Failed to write state file", data: ["path": path, "error": error.localizedDescription])
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "cookies": cookies.count
            ])
        }
    }

    func v2BrowserStateLoad(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        let url = URL(fileURLWithPath: path)
        let raw: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .err(code: "invalid_params", message: "State file must contain a JSON object", data: ["path": path])
            }
            raw = obj
        } catch {
            return .err(code: "not_found", message: "Failed to read state file", data: ["path": path, "error": error.localizedDescription])
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            if let frameSelector = raw["frame_selector"] as? String, !frameSelector.isEmpty {
                v2BrowserFrameSelectorBySurface[surfaceId] = frameSelector
            } else {
                v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            }

            if let urlStr = raw["url"] as? String,
               !urlStr.isEmpty,
               let parsed = URL(string: urlStr) {
                browserPanel.navigate(to: parsed)
            }

            if let cookieRows = raw["cookies"] as? [[String: Any]] {
                let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
                for row in cookieRows {
                    if let cookie = v2BrowserCookieFromObject(row, fallbackURL: browserPanel.currentURL) {
                        _ = v2BrowserCookieStoreSet(store, cookie: cookie)
                    }
                }
            }

            if let storage = raw["storage"] as? [String: Any] {
                let storageLiteral = v2JSONLiteral(storage)
                let script = """
                (() => {
                  const payload = \(storageLiteral);
                  const apply = (st, data) => {
                    if (!st || !data || typeof data !== 'object') return;
                    st.clear();
                    for (const [k, v] of Object.entries(data)) {
                      st.setItem(String(k), v == null ? '' : String(v));
                    }
                  };
                  apply(window.localStorage, payload.local);
                  apply(window.sessionStorage, payload.session);
                  return true;
                })()
                """
                _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "loaded": true
            ])
        }
    }

    func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
            scripts.append(script)
            v2BrowserInitScriptsBySurface[surfaceId] = scripts

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "scripts": scripts.count
            ])
        }
    }

    func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
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

    func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
            styles.append(css)
            v2BrowserInitStylesBySurface[surfaceId] = styles

            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: source, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "styles": styles.count
            ])
        }
    }

    func v2BrowserViewportSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.viewport.set", details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP")
    }

    func v2BrowserGeolocationSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.geolocation.set", details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP")
    }

    func v2BrowserOfflineSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.offline.set", details: "WKWebView does not expose reliable per-tab offline emulation")
    }

    func v2BrowserTraceStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.start", details: "Playwright trace artifacts are not available on WKWebView")
    }

    func v2BrowserTraceStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.stop", details: "Playwright trace artifacts are not available on WKWebView")
    }

    func v2BrowserNetworkRoute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "route", "params": params])
        }
        return v2BrowserNotSupported("browser.network.route", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    func v2BrowserNetworkUnroute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "unroute", "params": params])
        }
        return v2BrowserNotSupported("browser.network.unroute", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    func v2BrowserNetworkRequests(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            let items = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            return .err(code: "not_supported", message: "browser.network.requests is not supported on WKWebView", data: [
                "details": "Request interception logs are unavailable without CDP network hooks",
                "recorded_requests": items
            ])
        }
        return v2BrowserNotSupported("browser.network.requests", details: "Request interception logs are unavailable without CDP network hooks")
    }

    func v2BrowserScreencastStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.start", details: "WKWebView does not expose CDP screencast streaming")
    }

    func v2BrowserScreencastStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.stop", details: "WKWebView does not expose CDP screencast streaming")
    }

    func v2BrowserInputMouse(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_mouse", details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll")
    }

    func v2BrowserInputKeyboard(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_keyboard", details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup")
    }

    func v2BrowserInputTouch(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_touch", details: "Raw CDP touch injection is unavailable on WKWebView")
    }

}
