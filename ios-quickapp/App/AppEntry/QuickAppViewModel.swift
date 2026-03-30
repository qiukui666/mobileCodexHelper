import Combine
import Foundation
import WebKit

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
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
    private var pendingSendMessageID: UUID?
    private var pendingTimeoutWorkItem: DispatchWorkItem?
    private var replyPollWorkItem: DispatchWorkItem?

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
        self.webWorkbench.setAssistantMessageHandler { [weak self] text in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.shouldAppendAssistant(text) else { return }
                self.finishPendingSend(with: "已收到远端回复")
                self.messages.append(ChatMessage(role: .assistant, text: text))
            }
        }
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
        let pendingID = UUID()
        pendingSendMessageID = pendingID
        messages.append(ChatMessage(id: pendingID, role: .system, text: "正在发送..."))
        pendingTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingSendMessageID == pendingID else { return }
            self.finishPendingSend(with: "已发送，但暂未抓到远端回复（可能是页面回包结构未命中）。")
        }
        pendingTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)

        webWorkbench.sendRawCommand(trimmed) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.lastActionMessage = "已发送自定义指令"
                    self.updatePendingSend(with: "已发送，等待远端回复...")
                    self.startReplyPolling()
                case let .failure(error):
                    self.lastActionMessage = "发送失败：\(error.localizedDescription)"
                    self.finishPendingSend(with: "发送失败：\(error.localizedDescription)")
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

    private func finishPendingSend(with text: String) {
        pendingTimeoutWorkItem?.cancel()
        pendingTimeoutWorkItem = nil
        replyPollWorkItem?.cancel()
        replyPollWorkItem = nil
        guard let id = pendingSendMessageID,
              let idx = messages.firstIndex(where: { $0.id == id }) else {
            messages.append(ChatMessage(role: .system, text: text))
            pendingSendMessageID = nil
            return
        }
        messages[idx] = ChatMessage(id: id, role: .system, text: text)
        pendingSendMessageID = nil
    }

    private func updatePendingSend(with text: String) {
        guard let id = pendingSendMessageID,
              let idx = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[idx] = ChatMessage(id: id, role: .system, text: text)
    }

    private func startReplyPolling() {
        replyPollWorkItem?.cancel()
        let start = Date()
        let timeout: TimeInterval = 35

        func scheduleNext() {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingSendMessageID != nil else { return }

                self.pollLatestAssistantMessage { result in
                    guard self.pendingSendMessageID != nil else { return }
                    switch result {
                    case let .success(text):
                        if let text, self.shouldAppendAssistant(text) {
                            self.finishPendingSend(with: "已收到远端回复")
                            self.messages.append(ChatMessage(role: .assistant, text: text))
                            return
                        }
                    case .failure:
                        break
                    }

                    if Date().timeIntervalSince(start) >= timeout {
                        self.finishPendingSend(with: "已发送，但仍未抓到回复。请点“网页登录”确认远端页面是否真的有回包。")
                        return
                    }

                    scheduleNext()
                }
            }

            self.replyPollWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }

        scheduleNext()
    }

    private func shouldAppendAssistant(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if normalized == "已发送，等待远端回复..." || normalized == "正在发送..." {
            return false
        }
        if normalized.contains("Enter to send") || normalized.contains("Shift+Enter") || normalized.contains("slash commands") {
            return false
        }
        if normalized.contains("sessions") && normalized.contains("workspace") {
            return false
        }
        if messages.contains(where: { $0.role == .user && $0.text == normalized }) {
            return false
        }
        if messages.contains(where: { $0.role == .assistant && $0.text == normalized }) {
            return false
        }
        return true
    }

    private func pollLatestAssistantMessage(completion: @escaping (Result<String?, Error>) -> Void) {
        if let concrete = webWorkbench as? WKWebViewWorkbench {
            concrete.fetchLatestAssistantMessage(completion: completion)
            return
        }
        completion(.success(nil))
    }
}
