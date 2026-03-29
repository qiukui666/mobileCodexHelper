# MobileCodex 快版 iOS 客户端（中文界面）

这是一个“先可用”的 iOS 快版：
- App 内打开远程工作台页面
- App 内发送预设指令
- 提供 Tailscale 一键拉起入口（不内置VPN内核）

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
- 该快版通过 URL Scheme 调起 Tailscale App。
- 首次网络与权限行为依系统策略，无法绕过 iOS 系统弹窗。
