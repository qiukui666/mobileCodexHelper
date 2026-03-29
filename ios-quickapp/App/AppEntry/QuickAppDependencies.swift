import Foundation

@MainActor
enum QuickAppDependencies {
    static func makeViewModel(config: QuickAppConfig = .default) -> QuickAppViewModel {
        let webWorkbench = WKWebViewWorkbench(config: config)
        let tailscaleLauncher = TailscaleLauncher()
        return QuickAppViewModel(
            config: config,
            webWorkbench: webWorkbench,
            tailscaleLauncher: tailscaleLauncher
        )
    }
}
