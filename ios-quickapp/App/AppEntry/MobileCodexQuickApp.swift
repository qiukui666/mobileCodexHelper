import SwiftUI

@main
struct MobileCodexQuickApp: App {
    @StateObject private var viewModel = QuickAppDependencies.makeViewModel()

    var body: some Scene {
        WindowGroup {
            QuickAppRootView(viewModel: viewModel)
        }
    }
}

struct QuickAppRootView: View {
    @ObservedObject var viewModel: QuickAppViewModel

    var body: some View {
        VStack(spacing: 8) {
            QuickChatHomeView(
                urlText: $viewModel.urlText,
                connectionState: toConnectionState(viewModel.tailscaleStatus),
                onOpenWorkspace: viewModel.openWorkbench,
                onSendPresetCommand: sendDefaultPreset,
                onClearSession: viewModel.clearSession
            ) {
                WebWorkbenchContainerView(webView: viewModel.webView)
                    .frame(minHeight: 300)
            }

            HStack(spacing: 12) {
                Button("检测 Tailscale") {
                    viewModel.refreshTailscaleStatus()
                }
                .buttonStyle(.bordered)

                Button("打开 Tailscale") {
                    viewModel.openTailscale()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)

            if !viewModel.lastActionMessage.isEmpty {
                Text(viewModel.lastActionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        }
        .task {
            viewModel.start()
        }
    }

    private func sendDefaultPreset() {
        guard let first = viewModel.commandPresets.first else { return }
        viewModel.sendPreset(first)
    }

    private func toConnectionState(_ status: TailscaleStatus) -> QuickConnectionState {
        switch status {
        case .available:
            return .connected
        case .unavailable:
            return .disconnected
        }
    }
}
