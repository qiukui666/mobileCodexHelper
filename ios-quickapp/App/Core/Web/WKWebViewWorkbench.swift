import Foundation
import WebKit

protocol WebWorkbenchManaging: AnyObject {
    var webView: WKWebView { get }
    func loadConfiguredURL()
    func load(url: URL)
    func reload()
    func clearSession(completion: ((Result<Void, Error>) -> Void)?)
    func sendPresetCommand(_ preset: CommandPreset, completion: ((Result<Void, Error>) -> Void)?)
    func sendRawCommand(_ command: String, completion: ((Result<Void, Error>) -> Void)?)
}

final class WKWebViewWorkbench: NSObject, WebWorkbenchManaging {
    let webView: WKWebView

    private let config: QuickAppConfig

    init(config: QuickAppConfig) {
        self.config = config
        let webConfig = WKWebViewConfiguration()
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: webConfig)
        super.init()
        self.webView.allowsBackForwardNavigationGestures = true
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

    func sendPresetCommand(_ preset: CommandPreset, completion: ((Result<Void, Error>) -> Void)?) {
        sendRawCommand(preset.command, completion: completion)
    }

    func sendRawCommand(_ command: String, completion: ((Result<Void, Error>) -> Void)?) {
        let script = Self.makeDispatchScript(command: command)
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                completion?(.failure(error))
                return
            }
            completion?(.success(()))
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

            const inputSelectors = [
                'textarea[data-role="prompt"]',
                'textarea',
                'input[type="text"]',
                '[contenteditable="true"]'
            ];
            var input = null;
            for (const selector of inputSelectors) {
                const target = document.querySelector(selector);
                if (target) {
                    input = target;
                    break;
                }
            }

            if (input) {
                if ('value' in input) {
                    input.value = command;
                } else {
                    input.textContent = command;
                }
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
            }

            const sendSelectors = [
                'button[type="submit"]',
                'button[data-role="send"]',
                '[aria-label="Send"]',
                '[data-testid="send-button"]'
            ];
            for (const selector of sendSelectors) {
                const button = document.querySelector(selector);
                if (button) {
                    button.click();
                    break;
                }
            }

            return true;
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
