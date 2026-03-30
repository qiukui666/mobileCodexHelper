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
    private let jsTimeoutSeconds: TimeInterval = 8

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
        let script = Self.makeDispatchScript(command: command)
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

        webView.evaluateJavaScript(script) { raw, error in
            if let error {
                resolve(.failure(error))
                return
            }
            if let dict = raw as? [String: Any] {
                let sent = (dict["sent"] as? Bool) ?? false
                if !sent {
                    let reason = (dict["reason"] as? String) ?? "未找到可用输入框或发送按钮"
                    let debug = (dict["debug"] as? String) ?? ""
                    let suffix = debug.isEmpty ? "" : " [debug: \(debug)]"
                    resolve(.failure(NSError(
                        domain: "MobileCodexQuick",
                        code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "发送失败：\(reason)\(suffix)"]
                    )))
                    return
                }
            } else {
                let reason = "页面脚本返回异常"
                resolve(.failure(NSError(
                    domain: "MobileCodexQuick",
                    code: 1002,
                    userInfo: [NSLocalizedDescriptionKey: "发送失败：\(reason)"]
                )))
                return
            }
            resolve(.success(()))
        }
    }

    private static func makeDispatchScript(command: String) -> String {
        let safeCommand = command.jsSingleQuotedEscaped

        return """
        (function() {
            const command = '\(safeCommand)';
            try {
                window.dispatchEvent(new CustomEvent('mobilecodex:command', {
                    detail: { command: command, source: 'ios-quickapp' }
                }));
            } catch (_) {}

            // Target claudecodeui composer specifically to avoid hitting unrelated inputs.
            const inputSelectors = [
                'textarea.chat-input-placeholder',
                'form textarea.chat-input-placeholder',
                'textarea[placeholder*="Enter"]',
                'textarea[placeholder*="输入"]'
            ];
            var input = null;
            for (const selector of inputSelectors) {
                const target = document.querySelector(selector);
                if (target) {
                    input = target;
                    break;
                }
            }

            var sent = false;
            var clicked = false;
            var submitted = false;
            var debug = [];

            if (input) {
                debug.push('input-found');
                if ('value' in input) {
                    try {
                        const setter =
                          Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement && window.HTMLTextAreaElement.prototype, 'value')?.set
                          || Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), 'value')?.set;
                        if (setter) {
                            setter.call(input, command);
                            debug.push('value-setter');
                        } else {
                            input.value = command;
                            debug.push('value-direct');
                        }
                    } catch (_) {
                        input.value = command;
                        debug.push('value-fallback');
                    }
                } else {
                    input.textContent = command;
                    debug.push('contenteditable-set');
                }
                if (input.focus) { input.focus(); }
                try {
                  if (input._valueTracker && typeof input._valueTracker.setValue === 'function') {
                    input._valueTracker.setValue('');
                    debug.push('react-value-tracker');
                  }
                } catch (_) {}
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));

                // Try invoking React handlers directly when available.
                try {
                  const reactPropsKey = Object.keys(input).find((k) => k.startsWith('__reactProps$'));
                  if (reactPropsKey && input[reactPropsKey]?.onChange) {
                    input[reactPropsKey].onChange({ target: input, currentTarget: input, type: 'change' });
                    debug.push('react-onchange-called');
                  }
                } catch (_) {}

                input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
                const form = input.closest ? input.closest('form') : null;
                if (form && typeof form.requestSubmit === 'function') {
                    form.requestSubmit();
                    submitted = true;
                    debug.push('form-requestSubmit');
                } else if (form && typeof form.submit === 'function') {
                    form.submit();
                    submitted = true;
                    debug.push('form-submit');
                }
            }

            const targetForm = input && input.closest ? input.closest('form') : null;
            const sendSelectors = ['button[type="submit"]'];
            for (const selector of sendSelectors) {
                const button = targetForm ? targetForm.querySelector(selector) : document.querySelector(selector);
                if (button) {
                    if (button.disabled) {
                        debug.push('button-disabled');
                        continue;
                    }
                    try { button.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); } catch (_) {}
                    try { button.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true })); } catch (_) {}
                    try { button.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true })); } catch (_) {}
                    button.click();
                    clicked = true;
                    debug.push('button-clicked');
                    break;
                }
            }

            sent = clicked || submitted;

            return {
              sent: sent,
              reason: sent ? "已触发提交动作" : "未触发提交（可能输入未进入React状态或按钮仍禁用）",
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

          function extractAssistantTexts() {
            const nodes = Array.from(document.querySelectorAll('.chat-message.assistant'));
            return nodes.map((el) => {
              const body = el.querySelector('.prose, .markdown, .whitespace-pre-wrap') || el;
              return body && body.innerText ? body.innerText.trim() : '';
            }).filter(Boolean);
          }

          function scan() {
            const texts = extractAssistantTexts();
            if (texts.length > 0) {
              post(texts[texts.length - 1]);
            }
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

          const strictSelectors = ['.chat-message.assistant'];
          const strictNodes = [];
          for (const sel of strictSelectors) {
            document.querySelectorAll(sel).forEach(n => strictNodes.push(n));
          }
          for (let i = strictNodes.length - 1; i >= 0; i--) {
            const body = strictNodes[i].querySelector('.prose, .markdown, .whitespace-pre-wrap') || strictNodes[i];
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
