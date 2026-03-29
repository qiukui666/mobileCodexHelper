import Foundation

struct CommandPreset: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let command: String
}

struct QuickAppConfig: Hashable, Codable {
    let defaultWorkbenchURL: URL
    let commandPresets: [CommandPreset]

    static let `default` = QuickAppConfig(
        defaultWorkbenchURL: URL(string: "https://desktop-lk0um3a-1.taild2d00d.ts.net/session/019d34bb-26ea-79f2-af3c-a012edb6e5c2")!,
        commandPresets: [
            CommandPreset(
                id: "summarize",
                title: "总结当前上下文",
                command: "请先总结当前上下文，然后给出下一步执行计划。"
            ),
            CommandPreset(
                id: "fix",
                title: "修复报错",
                command: "请定位并修复当前错误，输出最小修改集。"
            ),
            CommandPreset(
                id: "review",
                title: "代码审查",
                command: "请对当前改动做代码审查，优先列出风险与缺失测试。"
            )
        ]
    )

    func preset(forID id: String) -> CommandPreset? {
        commandPresets.first(where: { $0.id == id })
    }
}
