[English](./README.md)

# Codex Usage Widget

这是一个注重隐私的原生 macOS 应用和 WidgetKit 小组件，用于显示当前 Mac 上已经登录的 Codex 账号剩余用量窗口。

<p align="center">
  <img src="Docs/Images/widget-small-light.png" alt="浅色模式下的小尺寸 Codex Usage 小组件" width="158">
  &nbsp;&nbsp;
  <img src="Docs/Images/widget-medium-dark.png" alt="深色模式下的中尺寸 Codex Usage 小组件" width="338">
</p>

<p align="center"><sub>截图使用的是合成预览数据，并非真实账号数据。</sub></p>

> [!IMPORTANT]
> 当前仓库只发布源代码，尚未提供经过 Developer ID 签名和 Apple 公证的可下载应用。现在如需使用，请按照下面的步骤在 Xcode 中进行本地构建和签名。

## 主要功能

- 使用已经确认的 **A · Clarity** 设计，提供 Small 和 Medium 两种 macOS 桌面小组件。
- 显示七天用量窗口；如果 Codex 以后重新提供五小时窗口，也会自动显示。
- 正确处理单窗口、双窗口、未知时长、过期、暂停、未登录和错误状态，不会编造数据。
- 应用图标支持 Default、Dark 和 Mono/tinted 外观，并使用 Apple Icon Composer 制作。
- 提供立即刷新、暂停/恢复、安全重新检测 Codex、可选的登录时启动以及脱敏诊断功能。
- 不包含遥测、网页抓取、API Key 账单集成，也不会直接读取凭据文件。

小组件的刷新时机由 WidgetKit 调度，因此它适合快速查看，而不是逐秒实时计量。每份快照都会明确显示更新时间或过期状态。

## 系统要求

- macOS 14 或更高版本。
- Xcode 26 或更高版本，并包含 Swift 6 工具链；当前项目已使用 Xcode 26.6 验证。
- Xcode 中可用于本地代码签名的 Apple ID/Team；主应用和 Widget 扩展必须选择同一个 Team。
- 当前版本的 ChatGPT 桌面应用或 Codex CLI，并且已经登录到能够提供 Codex 用量限制的账号。

免费的 Personal Team 可能可以用于本机测试，但 Apple 可能要求定期重新签名；本项目尚未把它验证为长期安装方案。如果未来提供普通用户可直接下载的版本，则需要维护者使用付费 Developer ID 完成签名和公证，最终用户不需要安装 Xcode。

应用会依次检查 Codex 应用包、`/Applications/ChatGPT.app` 内置的 Codex、Homebrew 常见位置以及 `PATH`。开发者也可以通过 `CODEX_USAGE_CODEX_PATH` 指定 Codex 的绝对路径。

## 从源代码安装

1. 安装当前版本的 [ChatGPT 桌面应用](https://chatgpt.com/download/) 或 Codex CLI，并完成登录。
2. 克隆仓库：

   ```sh
   git clone https://github.com/henryue/CodexUsageWidget.git
   cd CodexUsageWidget
   ```

3. 使用 Xcode 打开 `CodexUsageWidget.xcodeproj`。
4. 选择 `CodexUsage` target，打开 **Signing & Capabilities**，启用自动签名并选择你的 Team。
5. 对 `CodexUsageWidget` target 选择同一个 Team。两个 target 必须使用同一 Team。
6. 如果 Xcode 提示 Bundle Identifier 不可用，请把 `com.henryyue.CodexUsage` 改成你自己控制的唯一反向域名标识符，并把 Widget 标识符设为相同值加 `.Widget`。
7. 选择 `CodexUsage` scheme 和 **My Mac**，然后执行 **Product › Run**。
8. 如需稳定安装，请从 Xcode 的构建产物中找到 `Codex Usage.app`，将它复制到 `/Applications` 或 `~/Applications`，然后至少启动一次该副本。

项目使用 macOS 的 Team 前缀 App Group 格式：

```text
$(TeamIdentifierPrefix)com.henryyue.CodexUsageWidget
```

两个 target 中使用的是同一个值。按照 Apple 的说明，这种 macOS 格式会通过签名 Team 进行身份隔离，不需要 App Group provisioning profile。如果需要自定义，请同时修改主应用和 Widget 中的值。

### 添加桌面小组件

1. 启动 **Codex Usage**，点击 **Refresh Now**。
2. 确认应用已经显示当前用量快照。
3. 右键点击桌面，选择 **Edit Widgets**，搜索 **Codex Usage**，然后添加 Small 或 Medium 小组件。
4. 只有在希望登录后继续自动刷新时，才需要启用 **Launch at Login**。

### 常见安装问题

- **Shared usage storage is unavailable：** 确认两个 target 选择了同一个签名 Team，然后清理构建文件并重新构建。
- **Codex was not found：** 安装或更新 ChatGPT/Codex、确认已经登录，然后点击 **Re-detect Codex**。
- **组件列表中找不到：** 把已签名的应用移动到 Applications，启动一次，再重新打开组件列表。
- **数据显示过期：** 打开主应用并点击 **Refresh Now**；WidgetKit 可能会延迟桌面重绘。

## 隐私与安全设计

- 主应用需要启动已经安装的 Codex 可执行文件，因此有意不启用 App Sandbox。它只使用固定参数调用 `Process`，不会启动 shell。
- Widget 扩展仍然启用 Sandbox，不会启动 Codex、读取账号文件或发起网络请求。
- 主应用通过本地 Codex app-server 读取用量，将响应缩减为剩余百分比、重置时间、窗口时长和状态，再以原子方式写入版本化的 App Group 快照。
- 项目不会读取 `~/.codex/auth.json`、浏览器 Cookie、Keychain token 或原始账号网页。
- 脱敏诊断不会包含凭据、账号标识、用户目录路径、原始协议消息或实时用量数值。

这是一个非官方社区项目，与 OpenAI 不存在隶属或背书关系。Codex、ChatGPT 和 OpenAI 是其各自权利人的商标。

## 构建与测试

无签名构建：

```sh
xcodebuild clean build \
  -project CodexUsageWidget.xcodeproj \
  -scheme CodexUsage \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/CodexUsageWidget-Release \
  CODE_SIGNING_ALLOWED=NO
```

运行 Swift Package 测试：

```sh
swift test \
  --disable-sandbox \
  --scratch-path /tmp/CodexUsageWidget-SPM
```

运行 Xcode 测试：

```sh
CUW_TEST_DIR="$(mktemp -d /tmp/CodexUsageWidget-Tests.XXXXXX)"

xcodebuild test \
  -project CodexUsageWidget.xcodeproj \
  -scheme CodexUsage \
  -destination 'platform=macOS' \
  -derivedDataPath "$CUW_TEST_DIR/DerivedData" \
  -resultBundlePath "$CUW_TEST_DIR/Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

可选的 `CodexUsageSmoke` 会执行一次真实的本地初始化和读取握手，将结果缩减为脱敏模型，通过临时容器进行往返验证，并确认由测试启动的 app-server 进程已经退出。它不会输出实时百分比。

有关数据处理范围，请参阅 [PRIVACY.md](./PRIVACY.md)；如需负责任地报告安全问题，请参阅 [SECURITY.md](./SECURITY.md)。

当前源码验证的范围和结果记录在 [Docs/VALIDATION.md](./Docs/VALIDATION.md) 中。

## 卸载

1. 在应用内或 **System Settings › General › Login Items** 中关闭 **Launch at Login**。
2. 退出 Codex Usage。
3. 删除 `Codex Usage.app`，并从桌面移除小组件。

应用不会手动安装 launch-agent plist，也不会修改 ChatGPT、Codex 或它们的登录状态。

## 当前限制

- 本地 Codex app-server 的数据格式可能会随着 Codex 版本更新而变化。
- 刷新时机部分由 WidgetKit 控制。
- 当前架构适合本地或直接分发，不适合 Mac App Store，因为主应用需要启动其应用包之外的可执行文件。
- 如果要提供无障碍的一键下载版本，还需要 Developer ID 签名、Hardened Runtime 验证、Apple 公证、安装包制作以及干净系统安装测试。

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交修改前请先阅读 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 许可证

Codex Usage Widget 使用 [MIT License](./LICENSE) 开源。
