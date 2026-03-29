# MobileCodex 快版 iOS 客户端（中文界面）

这是一个“先可用”的 iOS 快版：
- 原生聊天样式界面（消息气泡 + 输入框）
- 后台承载远程工作台连接（不直接展示网页）
- 手动打开 Tailscale 后即可在 App 内发指令

## 目录
- `App/UI`：界面层（机器人1）
- `App/Core`：功能层（机器人2）
- `App/AppEntry`：应用入口

## 在 Mac 上生成工程与构建
1. 安装 XcodeGen：`brew install xcodegen`
2. 在本目录执行：`xcodegen generate`
3. 用 Xcode 打开 `MobileCodexQuick.xcodeproj`
4. 选择真机后构建运行

## 打包 IPA（TrollStore 场景）
1. 在 Xcode 构建出 `.app`
2. 执行：`./scripts/package-ipa.sh <你的 .app 路径> MobileCodexQuick.ipa`
3. 把 `MobileCodexQuick.ipa` 传到手机用 TrollStore 安装

## 说明
- 当前版本不再提供“打开 Tailscale”按钮，建议先手动连接 Tailscale。
- 若要真正做到“全原生聊天并显示助手回复”，下一步需要对接稳定的后端聊天 API（而非网页注入）。
