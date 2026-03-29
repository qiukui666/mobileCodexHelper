import Combine
import Foundation
import WebKit

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class QuickAppViewModel: ObservableObject {
    @Published private(set) var tailscaleStatus: TailscaleStatus = .unavailable
    @Published private(set) var lastActionMessage: String = ""
    @Published var urlText: String
    @Published var inputText: String = ""
    @Published private(set) var messages: [ChatMessage] = [
        ChatMessage(role: .system, text: "已就绪，你可以直接发送指令。")
    ]

    let defaultURLString: String
    let commandPresets: [CommandPreset]

    var webView: WKWebView {
        webWorkbench.webView
    }

    private let webWorkbench: WebWorkbenchManaging
    private let tailscaleLauncher: TailscaleLaunching

    init(
        config: QuickAppConfig,
        webWorkbench: WebWorkbenchManaging,
        tailscaleLauncher: TailscaleLaunching
    ) {
        self.defaultURLString = config.defaultWorkbenchURL.absoluteString
        self.urlText = config.defaultWorkbenchURL.absoluteString
        self.commandPresets = config.commandPresets
        self.webWorkbench = webWorkbench
        self.tailscaleLauncher = tailscaleLauncher
    }

    func start() {
        webWorkbench.loadConfiguredURL()
        refreshTailscaleStatus()
    }

    func refreshTailscaleStatus() {
        tailscaleStatus = tailscaleLauncher.detectStatus()
    }

    func openTailscale() {
        let opened = tailscaleLauncher.launch()
        if opened {
            lastActionMessage = "已尝试拉起 Tailscale；若出现 deeplink 报错，请改为手动打开 Tailscale App。"
        } else {
            lastActionMessage = "无法拉起 Tailscale，请检查是否安装；也可手动打开 Tailscale App。"
        }
        refreshTailscaleStatus()
    }

    func reloadWorkbench() {
        webWorkbench.reload()
    }

    func openWorkbench() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
            lastActionMessage = "地址无效，请检查 URL"
            return
        }
        webWorkbench.load(url: url)
        lastActionMessage = "正在打开工作台"
        messages.append(ChatMessage(role: .system, text: "已加载工作台地址。"))
    }

    func clearSession() {
        webWorkbench.clearSession { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.webWorkbench.reload()
                    self.lastActionMessage = "会话缓存已清理"
                    self.messages.append(ChatMessage(role: .system, text: "会话已清空。"))
                case let .failure(error):
                    self.lastActionMessage = "清理失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func sendPreset(withID id: String) {
        guard let preset = commandPresets.first(where: { $0.id == id }) else {
            lastActionMessage = "未找到预设指令：\(id)"
            return
        }
        sendPreset(preset)
    }

    func sendPreset(_ preset: CommandPreset) {
        webWorkbench.sendPresetCommand(preset) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.lastActionMessage = "已发送预设：\(preset.title)"
                    self.messages.append(ChatMessage(role: .user, text: preset.command))
                    self.messages.append(ChatMessage(role: .assistant, text: "指令已发送到远端工作台。"))
                case let .failure(error):
                    self.lastActionMessage = "发送失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func sendCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastActionMessage = "指令不能为空"
            return
        }
        messages.append(ChatMessage(role: .user, text: trimmed))

        webWorkbench.sendRawCommand(trimmed) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.lastActionMessage = "已发送自定义指令"
                    self.messages.append(ChatMessage(role: .assistant, text: "已发送，等待远端执行结果。"))
                case let .failure(error):
                    self.lastActionMessage = "发送失败：\(error.localizedDescription)"
                    self.messages.append(ChatMessage(role: .system, text: "发送失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    func sendInputMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        sendCommand(text)
    }
}
