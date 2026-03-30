import Foundation
import WebKit

protocol WebWorkbenchManaging: AnyObject {
    var webView: WKWebView { get }
    func setAssistantMessageHandler(_ handler: @escaping (String) -> Void)
    func loadConfiguredURL()
    func load(url: URL)
    func reload()
    func fetchLatestAssistantMessage(completion: @escaping (Result<String?, Error>) -> Void)
    func clearSession(completion: ((Result<Void, Error>) -> Void)?)
    func sendPresetCommand(_ preset: CommandPreset, completion: ((Result<Void, Error>) -> Void)?)
    func sendRawCommand(_ command: String, completion: ((Result<Void, Error>) -> Void)?)
}

extension WebWorkbenchManaging {
    func fetchLatestAssistantMessage(completion: @escaping (Result<String?, Error>) -> Void) {
        completion(.success(nil))
    }
}

final class WKWebViewWorkbench: NSObject, WebWorkbenchManaging, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView

    private let config: QuickAppConfig
    private var assistantMessageHandler: ((String) -> Void)?
    private let bridgeHandlerName = "mobilecodexBridge"
    private let jsTimeoutSeconds: TimeInterval = 12

    init(config: QuickAppConfig) {
        self.config = config
        let webConfig = WKWebViewConfiguration()
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfig.userContentController.addUserScript(WKUserScript(
            source: Self.makeObserverBootstrapScript(handlerName: "mobilecodexBridge"),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        self.webView = WKWebView(frame: .zero, configuration: webConfig)
        super.init()
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.navigationDelegate = self
        self.webView.configuration.userContentController.add(self, name: bridgeHandlerName)
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: bridgeHandlerName)
    }

    func setAssistantMessageHandler(_ handler: @escaping (String) -> Void) {
        assistantMessageHandler = handler
    }

    func loadConfiguredURL() {
        let request = URLRequest(url: config.defaultWorkbenchURL)
        webView.load(request)
    }

    func load(url: URL) {
        let request = URLRequest(url: url)
        webView.load(request)
    }

    func reload() {
        webView.reload()
    }

    func clearSession(completion: ((Result<Void, Error>) -> Void)?) {
        let script = """
        (function() {
          try {
            localStorage.clear();
            sessionStorage.clear();
          } catch (_) {}
          return true;
        })();
        """
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                completion?(.failure(error))
                return
            }
            completion?(.success(()))
        }
    }

    func fetchLatestAssistantMessage(completion: @escaping (Result<String?, Error>) -> Void) {
        let script = Self.makeLatestAssistantProbeScript()
        webView.evaluateJavaScript(script) { raw, error in
            if let error {
                completion(.failure(error))
                return
            }
            let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                completion(.success(text))
            } else {
                completion(.success(nil))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.makeObserverInstallScript(handlerName: bridgeHandlerName), completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == bridgeHandlerName else { return }
        if let body = message.body as? [String: Any],
           let type = body["type"] as? String,
           type == "assistant_message",
           let text = body["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            assistantMessageHandler?(trimmed)
        }
    }

    func sendPresetCommand(_ preset: CommandPreset, completion: ((Result<Void, Error>) -> Void)?) {
        sendRawCommand(preset.command, completion: completion)
    }

    func sendRawCommand(_ command: String, completion: ((Result<Void, Error>) -> Void)?) {
        var finished = false
        let lock = NSLock()

        func resolve(_ result: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            completion?(result)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + jsTimeoutSeconds) {
            resolve(.failure(NSError(
                domain: "MobileCodexQuick",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "发送超时：页面未就绪或脚本未响应"]
            )))
        }

        executeDispatch(command: command, recoveredOnce: false, completion: resolve)
    }

    private func executeDispatch(command: String, recoveredOnce: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let script = Self.makeDispatchScript(command: command)
        webView.evaluateJavaScript(script) { [weak self] raw, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let dict = raw as? [String: Any] else {
                completion(.failure(NSError(
                    domain: "MobileCodexQuick",
                    code: 1002,
                    userInfo: [NSLocalizedDescriptionKey: "发送失败：页面脚本返回异常"]
                )))
                return
            }

            let sent = (dict["sent"] as? Bool) ?? false
            if sent {
                completion(.success(()))
                return
            }

            let reason = (dict["reason"] as? String) ?? "未找到可用输入框或发送按钮"
            let debug = (dict["debug"] as? String) ?? ""
            let shouldRecover = !recoveredOnce && (debug.contains("input-not-found") || debug.contains("form-not-found") || debug.contains("btn-count:0") || debug.contains("nav-opened"))
            if shouldRecover {
                let shouldReload = !debug.contains("nav-opened")
                if shouldReload {
                    self.webView.reload()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard let self else { return }
                    self.executeDispatch(command: command, recoveredOnce: true, completion: completion)
                }
                return
            }

            let suffix = debug.isEmpty ? "" : " [debug: \(debug)]"
            completion(.failure(NSError(
                domain: "MobileCodexQuick",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "发送失败：\(reason)\(suffix)"]
            )))
        }
    }

    private static func makeDispatchScript(command: String) -> String {
        let safeCommand = command.jsSingleQuotedEscaped

        return """
        (function() {
            const command = '\(safeCommand)';
            const debug = [];
            try { debug.push('href:' + String(window.location && window.location.href || '')); } catch (_) {}
            try { debug.push('ready:' + String(document.readyState || '')); } catch (_) {}

            function pushDebug(v) {
              try { debug.push(String(v)); } catch (_) {}
            }

            function getReactProps(node) {
              if (!node) return null;
              try {
                const key = Object.keys(node).find((k) => k.indexOf('__reactProps$') === 0);
                if (key && node[key]) return node[key];
              } catch (_) {}
              return null;
            }

            function getReactFiber(node) {
              if (!node) return null;
              try {
                const key = Object.keys(node).find((k) => k.indexOf('__reactFiber$') === 0);
                if (key && node[key]) return node[key];
              } catch (_) {}
              return null;
            }

            function callReactHandler(node, names, eventObj) {
              const seen = new Set();
              let cur = node;
              while (cur && !seen.has(cur)) {
                seen.add(cur);
                const props = getReactProps(cur);
                if (props) {
                  for (const name of names) {
                    if (typeof props[name] === 'function') {
                      try {
                        props[name](eventObj);
                        pushDebug('react-' + name);
                        return true;
                      } catch (_) {
                        pushDebug('react-' + name + '-err');
                      }
                    }
                  }
                }
                const fiber = getReactFiber(cur);
                if (fiber && fiber.return && fiber.return.stateNode && fiber.return.stateNode !== cur) {
                  cur = fiber.return.stateNode;
                } else {
                  cur = cur.parentElement;
                }
              }
              return false;
            }

            function isVisible(el) {
              if (!el) return false;
              const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
              if (style && (style.display === 'none' || style.visibility === 'hidden')) return false;
              const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
              if (rect && rect.width === 0 && rect.height === 0) return false;
              return true;
            }

            function collectRoots() {
              const roots = [];
              const seen = new Set();

              function pushRoot(root) {
                if (!root || seen.has(root)) return;
                seen.add(root);
                roots.push(root);
              }

              function walk(root) {
                pushRoot(root);
                if (!root || !root.querySelectorAll) return;

                const hosts = Array.from(root.querySelectorAll('*'));
                for (const host of hosts) {
                  if (host && host.shadowRoot) {
                    walk(host.shadowRoot);
                  }
                }

                const frames = Array.from(root.querySelectorAll('iframe, frame'));
                for (const frame of frames) {
                  try {
                    if (frame.contentDocument) walk(frame.contentDocument);
                  } catch (_) {}
                }
              }

              walk(document);
              return roots;
            }

            function queryAllDeep(selector, extraRoots) {
              const roots = collectRoots();
              if (Array.isArray(extraRoots)) {
                for (const r of extraRoots) {
                  if (r && !roots.includes(r)) roots.unshift(r);
                }
              }
              const out = [];
              const seen = new Set();
              for (const root of roots) {
                if (!root || !root.querySelectorAll) continue;
                let nodes = [];
                try { nodes = Array.from(root.querySelectorAll(selector)); } catch (_) {}
                for (const node of nodes) {
                  if (!seen.has(node)) {
                    seen.add(node);
                    out.push(node);
                  }
                }
              }
              return out;
            }

            function findInput() {
              const selectors = [
                'textarea.chat-input-placeholder',
                'form textarea.chat-input-placeholder',
                'textarea[data-testid*="chat"]',
                'textarea[placeholder*="Enter"]',
                'textarea[placeholder*="输入"]',
                'textarea[placeholder*="message"]',
                '[data-testid*="composer"] [contenteditable="true"]',
                '[data-testid*="chat"] [contenteditable="true"]',
                '.ProseMirror',
                '[data-lexical-editor="true"]',
                '[data-slate-editor="true"]',
                'textarea',
                'div[role="textbox"]',
                '[contenteditable="true"][role="textbox"]',
                '[role="textbox"][contenteditable="true"]',
                '[contenteditable="true"]'
              ];
              for (const selector of selectors) {
                const nodes = queryAllDeep(selector);
                pushDebug('input-candidates:' + selector + ':' + nodes.length);
                for (const node of nodes) {
                  if (isVisible(node)) {
                    pushDebug('input-selector:' + selector);
                    return node;
                  }
                }
              }
              return null;
            }

            function setInputValue(input, value) {
              if (!input) return false;
              try { if (input.focus) input.focus(); } catch (_) {}

              const isTextInput = input.tagName === 'TEXTAREA' || input.tagName === 'INPUT';
              if (isTextInput) {
                try {
                  const proto = input.tagName === 'TEXTAREA'
                    ? window.HTMLTextAreaElement && window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement && window.HTMLInputElement.prototype;
                  const descriptor = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
                  const setter = descriptor ? descriptor.set : null;
                  if (setter) {
                    setter.call(input, value);
                    pushDebug('value-setter');
                  } else {
                    input.value = value;
                    pushDebug('value-direct');
                  }
                } catch (_) {
                  input.value = value;
                  pushDebug('value-fallback');
                }

                try {
                  if (input._valueTracker && typeof input._valueTracker.setValue === 'function') {
                    input._valueTracker.setValue('');
                    pushDebug('value-tracker');
                  }
                } catch (_) {}
              } else {
                input.textContent = value;
                pushDebug('contenteditable-set');
              }

              try {
                input.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
                pushDebug('input-event');
              } catch (_) {}
              try {
                input.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                pushDebug('change-event');
              } catch (_) {}
              callReactHandler(input, ['onChange', 'onInput'], { target: input, currentTarget: input, type: 'change' });
              return true;
            }

            function findFormForInput(input) {
              if (!input) return null;
              if (input.closest) {
                const form = input.closest('form');
                if (form) return form;
              }
              let cur = input.parentElement;
              while (cur) {
                if (cur.querySelector && cur.querySelector('button[type="submit"],button[aria-label*="Send"],button[aria-label*="发送"]')) {
                  return cur;
                }
                cur = cur.parentElement;
              }
              try {
                const rootNode = input.getRootNode ? input.getRootNode() : null;
                if (rootNode && rootNode.host) {
                  let host = rootNode.host;
                  while (host) {
                    if (host.querySelector && host.querySelector('button[type="submit"],button[aria-label*="Send"],button[aria-label*="发送"],button[data-testid*="send"]')) {
                      return host;
                    }
                    host = host.parentElement;
                  }
                }
              } catch (_) {}
              return null;
            }

            function trySubmitWithForm(form) {
              if (!form) return false;
              let ok = false;
              const submitter = form.querySelector ? form.querySelector('button[type="submit"],button:not([disabled])') : null;
              try {
                const evt = new Event('submit', { bubbles: true, cancelable: true });
                ok = form.dispatchEvent(evt) || ok;
                pushDebug('form-submit-event');
              } catch (_) {}

              if (typeof form.requestSubmit === 'function') {
                try {
                  form.requestSubmit(submitter || undefined);
                  ok = true;
                  pushDebug('form-requestSubmit');
                } catch (_) {}
              }
              if (!ok && typeof form.submit === 'function') {
                try {
                  form.submit();
                  ok = true;
                  pushDebug('form-submit');
                } catch (_) {}
              }
              const reactOk = callReactHandler(
                form,
                ['onSubmit'],
                { target: form, currentTarget: form, type: 'submit', preventDefault: function() {}, stopPropagation: function() {} }
              );
              return ok || reactOk;
            }

            function findSendButtons(form, input) {
              const roots = [];
              if (form) roots.push(form);
              if (input && input.parentElement) roots.push(input.parentElement);
              const selectors = [
                'button[type="submit"]',
                'button[aria-label*="Send"]',
                'button[aria-label*="send"]',
                'button[aria-label*="Reply"]',
                'button[aria-label*="发送"]',
                'button[data-testid*="send"]',
                '[data-testid*="send"] button',
                '[data-testid*="composer"] button',
                '[data-testid*="chat"] button'
              ];
              const out = [];
              const seen = new Set();
              for (const selector of selectors) {
                const nodes = queryAllDeep(selector, roots);
                for (const node of nodes) {
                  if (!seen.has(node) && isVisible(node)) {
                    seen.add(node);
                    out.push(node);
                  }
                }
              }
              return out;
            }

            function tryClickSendButtons(buttons, input) {
              let clicked = false;
              for (const button of buttons) {
                if (button.disabled) {
                  pushDebug('btn-disabled');
                  continue;
                }
                try { button.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); } catch (_) {}
                try { button.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true })); } catch (_) {}
                try { button.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); } catch (_) {}
                try {
                  button.click();
                  clicked = true;
                  pushDebug('btn-click');
                } catch (_) {}
                const reactOk = callReactHandler(
                  button,
                  ['onClick'],
                  { target: button, currentTarget: button, type: 'click', preventDefault: function() {}, stopPropagation: function() {} }
                );
                clicked = clicked || reactOk;
                if (clicked) break;
              }

              if (!clicked && input) {
                try {
                  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
                  input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
                  pushDebug('enter-dispatch');
                } catch (_) {}
                const keyOk = callReactHandler(
                  input,
                  ['onKeyDown', 'onKeyPress'],
                  { key: 'Enter', code: 'Enter', which: 13, keyCode: 13, bubbles: true, cancelable: true, shiftKey: false }
                );
                clicked = clicked || keyOk;
              }
              return clicked;
            }

            function normText(s) {
              return String(s || '').trim().toLowerCase();
            }

            function sampleBodyText() {
              try {
                const t = String((document.body && (document.body.innerText || document.body.textContent)) || '');
                const oneLine = t.replace(/\s+/g, ' ').trim();
                return oneLine.slice(0, 120);
              } catch (_) {
                return '';
              }
            }

            function maybeOpenConversation() {
              const openPhrases = [
                'new chat', 'new session', 'new conversation',
                'continue', 'resume', 'open',
                'chat', 'session',
                'workspace', 'project',
                '新建会话', '新对话', '会话', '聊天', '继续', '打开', '工作区', '项目'
              ];
              const selectors = [
                'a[href*="/session/"]',
                'a[href*="/workspace/"]',
                'a[href*="workspace"]',
                'button[data-testid*="new"]',
                'button[data-testid*="chat"]',
                'button[data-testid*="workspace"]',
                '[data-testid*="workspace"]',
                '[data-testid*="session"]',
                '[data-testid*="conversation"]',
                '[class*="workspace"]',
                '[class*="session"]',
                '[class*="conversation"]',
                '[onclick]',
                '[role="button"]',
                'a',
                'button',
                'li',
                'div'
              ];
              const clicked = new Set();
              let scanned = 0;
              for (const selector of selectors) {
                const nodes = queryAllDeep(selector);
                for (const node of nodes) {
                  scanned += 1;
                  if (!isVisible(node) || clicked.has(node)) continue;
                  const label = normText(node.getAttribute && (node.getAttribute('aria-label') || node.getAttribute('title')) || '');
                  const text = normText(node.innerText || node.textContent || '');
                  const href = normText(node.getAttribute && node.getAttribute('href') || '');
                  const matches = openPhrases.some((p) => label.includes(p) || text.includes(p))
                    || href.includes('/session/')
                    || href.includes('/workspace/')
                    || href.includes('workspace');
                  if (!matches) continue;
                  try {
                    node.click();
                    clicked.add(node);
                    pushDebug('nav-opened:' + selector + ':' + text.slice(0, 48));
                    return true;
                  } catch (_) {}
                }
              }
              pushDebug('nav-scan:' + scanned);
              return false;
            }

            try {
                window.dispatchEvent(new CustomEvent('mobilecodex:command', {
                    detail: { command: command, source: 'ios-quickapp' }
                }));
            } catch (_) {}
            const bodyHead = sampleBodyText();
            if (bodyHead) pushDebug('body-head:' + bodyHead);

            const input = findInput();
            if (!input) pushDebug('input-not-found');
            const valueSet = setInputValue(input, command);
            const form = findFormForInput(input);
            pushDebug(form ? 'form-found' : 'form-not-found');
            const submitted = valueSet ? trySubmitWithForm(form) : false;
            const buttons = findSendButtons(form, input);
            pushDebug('btn-count:' + buttons.length);
            const clicked = valueSet ? tryClickSendButtons(buttons, input) : false;
            const sent = clicked || submitted;
            const openedConversation = (!sent && !input) ? maybeOpenConversation() : false;
            const hasPasswordField = queryAllDeep('input[type="password"]').length > 0;
            const reason = sent
              ? "已触发提交动作"
              : (openedConversation
                  ? "未找到输入框，已尝试自动打开会话"
              : (hasPasswordField
                  ? "未检测到聊天输入框（页面可能在登录态）"
                  : "未触发提交（可能输入未进入React状态或按钮仍禁用）"));

            return {
              sent: sent,
              reason: reason,
              clicked: clicked,
              submitted: submitted,
              debug: debug.join(',')
            };
        })();
        """
    }

    private static func makeObserverBootstrapScript(handlerName: String) -> String {
        """
        (function() {
          if (window.__mobilecodexBootstrapInstalled) return;
          window.__mobilecodexBootstrapInstalled = true;

          window.__mobilecodexPostNative = function(payload) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName)) {
                window.webkit.messageHandlers.\(handlerName).postMessage(payload);
              }
            } catch (_) {}
          };
        })();
        """
    }

    private static func makeObserverInstallScript(handlerName: String) -> String {
        """
        (function() {
          if (window.__mobilecodexObserverInstalled) return true;
          window.__mobilecodexObserverInstalled = true;

          const seen = new Set();
          const bootUntil = Date.now() + 2500;
          let state = { lastText: '', lastCount: 0 };

          function post(text) {
            try {
              if (!text) return;
              const t = String(text).trim();
              if (!t || seen.has(t)) return;
              seen.add(t);
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName)) {
                window.webkit.messageHandlers.\(handlerName).postMessage({ type: 'assistant_message', text: t });
              }
            } catch (_) {}
          }

          function assistantNodes() {
            const selectors = [
              '.chat-message.assistant',
              '.chat-turn.assistant',
              '.message.assistant',
              '.assistant-message',
              '[class*="assistant-message"]',
              '[data-role="assistant"]',
              '[data-author="assistant"]',
              '[data-role="assistant-message"]',
              '[data-message-author-role="assistant"]',
              '[data-testid="assistant-message"]',
              '[data-testid*="assistant-message"]',
              'article[data-testid="assistant"]',
              'article[data-testid*="assistant"]',
              '[aria-label*="assistant"]',
              '.assistant'
            ];
            const out = [];
            const uniq = new Set();
            for (const selector of selectors) {
              const nodes = Array.from(document.querySelectorAll(selector));
              for (const node of nodes) {
                if (!uniq.has(node)) {
                  uniq.add(node);
                  out.push(node);
                }
              }
            }
            return out;
          }

          function extractAssistantTexts() {
            const nodes = assistantNodes();
            return nodes.map((el) => {
              const body = el.querySelector('.prose, .markdown, .message-content, .chat-message-content, [data-testid*="message-content"], .whitespace-pre-wrap, pre, p') || el;
              return body && body.innerText ? body.innerText.trim() : '';
            }).filter(Boolean);
          }

          function scan() {
            const texts = extractAssistantTexts();
            if (texts.length === 0) return;
            const latest = texts[texts.length - 1];
            if (Date.now() < bootUntil) {
              state.lastText = latest;
              state.lastCount = texts.length;
              return;
            }
            if (!state.lastText) {
              state.lastText = latest;
              state.lastCount = texts.length;
              return;
            }
            if (latest !== state.lastText) {
              post(latest);
              state.lastText = latest;
              state.lastCount = texts.length;
              return;
            }
            state.lastCount = texts.length;
          }

          const observer = new MutationObserver(() => scan());
          observer.observe(document.documentElement || document.body, { childList: true, subtree: true, characterData: true });
          setInterval(scan, 1200);
          scan();
          return true;
        })();
        """
    }

    private static func makeLatestAssistantProbeScript() -> String {
        """
        (function() {
          function textOf(el) {
            if (!el) return '';
            const t = (el.innerText || el.textContent || '').trim();
            return t;
          }

          const selectors = [
            '.chat-message.assistant',
            '.chat-turn.assistant',
            '.message.assistant',
            '.assistant-message',
            '[class*="assistant-message"]',
            '[data-role="assistant"]',
            '[data-author="assistant"]',
            '[data-role="assistant-message"]',
            '[data-message-author-role="assistant"]',
            '[data-testid="assistant-message"]',
            '[data-testid*="assistant-message"]',
            'article[data-testid="assistant"]',
            'article[data-testid*="assistant"]',
            '[aria-label*="assistant"]',
            '.assistant'
          ];
          const nodes = [];
          const seen = new Set();
          for (const sel of selectors) {
            document.querySelectorAll(sel).forEach(n => {
              if (!seen.has(n)) {
                seen.add(n);
                nodes.push(n);
              }
            });
          }
          for (let i = nodes.length - 1; i >= 0; i--) {
            const body = nodes[i].querySelector('.prose, .markdown, .message-content, .chat-message-content, [data-testid*="message-content"], .whitespace-pre-wrap, pre, p') || nodes[i];
            const t = textOf(body);
            if (t) return t;
          }

          return '';
        })();
        """
    }
}

private extension String {
    var jsSingleQuotedEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
