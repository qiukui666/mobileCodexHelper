import Foundation
import UIKit

enum TailscaleStatus: Equatable {
    case available(scheme: String)
    case unavailable
}

@MainActor
protocol TailscaleLaunching {
    func detectStatus() -> TailscaleStatus
    func launch() -> Bool
}

@MainActor
final class TailscaleLauncher: TailscaleLaunching {
    private let application: UIApplication
    // `tailscale://` 在部分版本上会进入 deeplink 校验路径并报 Unable to verify deeplink。
    // 优先使用 `ts-vpn://` 只做应用拉起。
    private let supportedSchemes = ["ts-vpn://", "tailscale://"]

    init(application: UIApplication = .shared) {
        self.application = application
    }

    func detectStatus() -> TailscaleStatus {
        for rawScheme in supportedSchemes {
            guard let url = URL(string: rawScheme) else { continue }
            if application.canOpenURL(url) {
                return .available(scheme: rawScheme)
            }
        }
        return .unavailable
    }

    func launch() -> Bool {
        guard case let .available(scheme) = detectStatus(),
              let url = URL(string: scheme) else {
            return false
        }

        application.open(url, options: [:], completionHandler: nil)
        return true
    }
}

extension TailscaleStatus {
    var displayText: String {
        switch self {
        case let .available(scheme):
            return "已安装（\(scheme)）"
        case .unavailable:
            return "未检测到 Tailscale"
        }
    }
}
