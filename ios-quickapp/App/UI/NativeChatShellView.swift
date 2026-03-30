import SwiftUI
import UIKit
import WebKit

struct NativeChatShellView: View {
    @ObservedObject var viewModel: QuickAppViewModel
    @State private var showWebLoginSheet = false
    @State private var loginWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: config)
    }()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                messages
                composer
            }

            // 后台承载工作台：保持真实可布局尺寸，否则部分站点会因视口过小不渲染输入框。
            WebWorkbenchContainerView(webView: viewModel.webView)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showWebLoginSheet) {
            NavigationStack {
                WebWorkbenchContainerView(webView: loginWebView)
                    .onAppear {
                        let target = URL(string: viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
                            ?? URL(string: viewModel.defaultURLString)
                        if let target {
                            loginWebView.load(URLRequest(url: target))
                        }
                    }
                    .navigationTitle("网页登录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { showWebLoginSheet = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("刷新") { loginWebView.reload() }
                        }
                    }
            }
        }
        .onChange(of: showWebLoginSheet) { showing in
            if !showing {
                // 登录页关闭后刷新后台工作台，确保会话 cookie/state 立即生效到后台收发链路。
                viewModel.reloadWorkbench()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("移动 Codex")
                .font(.headline)
            TextField("服务地址", text: $viewModel.urlText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 10) {
                Button("连接") { viewModel.openWorkbench() }
                Button("网页登录") { showWebLoginSheet = true }
                Button("发送预设") {
                    if let first = viewModel.commandPresets.first {
                        viewModel.sendPreset(first)
                    }
                }
                Button("清空") { viewModel.clearSession() }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("输入指令...", text: $viewModel.inputText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button("发送") {
                viewModel.sendInputMessage()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    copyButton(text: message.text)
                }
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    copyButton(text: message.text)
                }
                Spacer()
            }
        case .system:
            VStack(spacing: 4) {
                Text(message.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                copyButton(text: message.text)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func copyButton(text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("复制", systemImage: "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}
