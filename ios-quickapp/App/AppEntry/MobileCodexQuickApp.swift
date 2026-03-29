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
        NativeChatShellView(viewModel: viewModel)
        .task {
            viewModel.start()
        }
    }
}
