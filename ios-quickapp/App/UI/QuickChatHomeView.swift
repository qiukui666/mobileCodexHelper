import SwiftUI

public enum QuickConnectionState: Equatable {
    case connected
    case connecting
    case disconnected

    var title: String {
        switch self {
        case .connected:
            return "已连接"
        case .connecting:
            return "连接中"
        case .disconnected:
            return "未连接"
        }
    }

    var iconName: String {
        switch self {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "dot.radiowaves.left.and.right"
        case .disconnected:
            return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }
}

public struct QuickChatHomeView<Container: View>: View {
    @Binding private var urlText: String

    private let connectionState: QuickConnectionState
    private let onOpenWorkspace: () -> Void
    private let onSendPresetCommand: () -> Void
    private let onClearSession: () -> Void
    private let container: Container

    public init(
        urlText: Binding<String>,
        connectionState: QuickConnectionState,
        onOpenWorkspace: @escaping () -> Void,
        onSendPresetCommand: @escaping () -> Void,
        onClearSession: @escaping () -> Void,
        @ViewBuilder container: () -> Container
    ) {
        self._urlText = urlText
        self.connectionState = connectionState
        self.onOpenWorkspace = onOpenWorkspace
        self.onSendPresetCommand = onSendPresetCommand
        self.onClearSession = onClearSession
        self.container = container()
    }

    public var body: some View {
        VStack(spacing: 12) {
            ConnectionStatusBar(state: connectionState)

            VStack(spacing: 10) {
                URLInputCard(urlText: $urlText)

                ActionButtonsCard(
                    onOpenWorkspace: onOpenWorkspace,
                    onSendPresetCommand: onSendPresetCommand,
                    onClearSession: onClearSession
                )
            }

            WebContainerCard {
                container
            }
        }
        .padding(16)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

public extension QuickChatHomeView where Container == WebContainerPlaceholderView {
    init(
        urlText: Binding<String>,
        connectionState: QuickConnectionState,
        onOpenWorkspace: @escaping () -> Void,
        onSendPresetCommand: @escaping () -> Void,
        onClearSession: @escaping () -> Void
    ) {
        self.init(
            urlText: urlText,
            connectionState: connectionState,
            onOpenWorkspace: onOpenWorkspace,
            onSendPresetCommand: onSendPresetCommand,
            onClearSession: onClearSession,
            container: { WebContainerPlaceholderView() }
        )
    }
}

public struct ConnectionStatusBar: View {
    let state: QuickConnectionState

    public init(state: QuickConnectionState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.iconName)
                .font(.headline)
                .foregroundStyle(state.tint)

            Text("连接状态：\(state.title)")
                .font(.subheadline.weight(.semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

public struct URLInputCard: View {
    @Binding var urlText: String

    public init(urlText: Binding<String>) {
        self._urlText = urlText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务地址")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("请输入服务 URL（例如：https://example.com）", text: $urlText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

public struct ActionButtonsCard: View {
    let onOpenWorkspace: () -> Void
    let onSendPresetCommand: () -> Void
    let onClearSession: () -> Void

    public init(
        onOpenWorkspace: @escaping () -> Void,
        onSendPresetCommand: @escaping () -> Void,
        onClearSession: @escaping () -> Void
    ) {
        self.onOpenWorkspace = onOpenWorkspace
        self.onSendPresetCommand = onSendPresetCommand
        self.onClearSession = onClearSession
    }

    public var body: some View {
        VStack(spacing: 10) {
            Button("打开工作台", action: onOpenWorkspace)
                .buttonStyle(QuickPrimaryButtonStyle())

            Button("发送预设指令", action: onSendPresetCommand)
                .buttonStyle(QuickSecondaryButtonStyle())

            Button("清空会话", role: .destructive, action: onClearSession)
                .buttonStyle(QuickDangerButtonStyle())
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

public struct WebContainerCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内嵌页面")
                .font(.footnote)
                .foregroundStyle(.secondary)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public struct WebContainerPlaceholderView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("WebView 占位容器")
                .font(.subheadline.weight(.semibold))

            Text("此区域用于承载网页内容\n当前仅提供 UI 容器接口")
                .multilineTextAlignment(.center)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(16)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }
}

public struct QuickPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .font(.headline)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

public struct QuickSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .font(.headline)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.10 : 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

public struct QuickDangerButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .font(.headline)
            .foregroundStyle(.red)
            .background(Color.red.opacity(configuration.isPressed ? 0.08 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var url = "https://example.com"
        @State private var state: QuickConnectionState = .connecting

        var body: some View {
            QuickChatHomeView(
                urlText: $url,
                connectionState: state,
                onOpenWorkspace: {},
                onSendPresetCommand: {},
                onClearSession: {}
            )
        }
    }

    return PreviewHost()
}
