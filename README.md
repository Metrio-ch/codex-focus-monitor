# Codex Focus Monitor · Codex 项目跟进与聚焦

一个贴在 macOS 屏幕顶部的轻量原生监控台，帮助你在与 AI 并行协作时，跟进任务进展、集中处理需要判断的事项，并在切换任务后快速找回上下文。

**最多三个探索线程，一个当前焦点。** 任务可以同时在后台执行，你只需要一次关注一件事。开始讨论时不必先写出完整目标或方案。

当前版本：**v0.3.4 / Build 8 · 预览版**。使用 SwiftUI + AppKit 构建，无第三方 Swift 依赖。这是个人开发的辅助工具，非 OpenAI 官方项目；文中的 Codex 指被监控的桌面应用及其本机组件。仓库使用新名称，应用仍叫 **Kayla Monitor**，与已有安装及本地数据保持兼容。

## 下载安装

从 [GitHub Releases](https://github.com/Metrio-ch/codex-focus-monitor/releases) 下载 DMG 和对应的 `.sha256` 文件。当前安装包只验证了 **Apple Silicon / arm64**；应用声明支持 macOS 13 及以上，旧系统尚未逐版实测。运行安装包不需要 Swift 或 Python，电脑需已有可用的 Codex 桌面环境。

```bash
shasum -a 256 -c Codex-Focus-Monitor-0.3.4-macOS-arm64.dmg.sha256
```

确认校验通过后打开 DMG，将 `Kayla Monitor.app` 拖入 `Applications`，再从“应用程序”启动。更新前请先退出旧版；不要同时运行两份应用。

**安装包仅作 ad-hoc 签名，未经 Apple Developer ID 签名和公证。** macOS 可能阻止首次打开。请核对下载来源并阅读 [Apple 的安全说明](https://support.apple.com/102445)；不确定来源时不要运行，不需要关闭系统安全防护。也可以审阅源码后自行构建。

拖拽安装不会修改全局 hooks，也不会自动开启登录启动。它能观察已选任务的本地日志；需要范围外活动等 hooks 能力时，再选择下方的“完整安装”。

## 能做什么

- **顶部拉片**：收起时约 150 × 28 pt，深色实底、无窗口阴影，贴紧屏幕物理顶边；显示三个状态灯和待处理数量。
- **悬停展开**：鼠标移入约 150 ms 后展开，移出约 700 ms 后收起。固定面板或编辑恢复点时保持展开。
- **轻量提醒**：检测到需要你处理的事项时，短暂展开约五秒。普通显示不主动获取键盘焦点，编辑时才进入可输入状态。
- **三张任务卡片**：分别呈现 Kayla 的执行状态和你的注意力状态；今日范围外的活动单独提示，不自动添加第四张卡片。
- **本轮计时**：处理中每秒更新，从本轮开始计算经过时间；本轮结束或中断后保留耗时。该值包含等待时间，并非模型的纯计算耗时。
- **停靠与恢复**：从最近用户消息及 Kayla 回复中，用本地规则提炼可编辑的恢复点草稿；确认后保存。恢复时先查看恢复点，再打开任务。
- **直接回到对话**：通过 `codex://threads/{threadId}` 打开对应任务。
- **显示器切换**：当前优先使用名为 `T270CF` 的外接显示器，断开后回到内建显示器，重新连接后迁回。
- **登录时启动**：在设置中主动开启，默认关闭；macOS 可能要求确认登录项。

## 状态如何判断

执行状态和注意力状态互相独立。一个任务被“停靠”，并不会暂停它的后台执行。

| 卡片显示 | 含义 |
| --- | --- |
| 处理中 | 检测到本轮开始或新消息提交 |
| 等你判断 | 检测到本轮回复结束，需要你决定下一步；不代表整个任务已完成 |
| 状态待确认 | 暂时缺少足够证据确认执行状态，例如重启后尚未恢复观察 |
| 等你授权 / 等你答复 | 从可识别的工具请求中推断需要人工操作 |
| 执行已中断 | 检测到本轮中断事件 |
| 疑似停滞 | 仍处于处理中、没有其他已知阻塞，且连续 **15 分钟**没有可识别的新活动 |
| 今日阶段完成 | 仅由你手动确认 |

注意力状态为“当前焦点”或“已停靠”，最多一个任务处于当前焦点。

“疑似停滞”只是检查提示。长时间思考、工具运行、睡眠或日志未更新都可能触发它，不能据此判断任务已经失败。工具调用、工具返回和可识别的会话活动会刷新活动时间；单纯的 token 计数记录不计入活动。

## 源码构建环境

- macOS：包配置最低为 macOS 13，实际兼容性仍取决于所用 Swift 工具链和 SDK；目前主要在 Apple Silicon Mac 上验证。
- Swift 6 工具链与 macOS SDK：已验证 Swift 6.3.3。可使用 Command Line Tools，不要求完整 Xcode。
- Python 3：hooks 配置工具及其测试使用 `/usr/bin/python3`。
- 本机 Codex 环境：可读取自己的会话记录；任务跳转需要桌面应用注册对应 URL scheme。

可先检查本机工具：

```bash
swift --version
xcrun --sdk macosx --show-sdk-path
/usr/bin/python3 --version
```

当前最近任务适配器按顺序查找以下 CLI 路径：

```text
/Applications/Codex.app/Contents/Resources/codex
~/Applications/Codex.app/Contents/Resources/codex
/Applications/ChatGPT.app/Contents/Resources/codex
/usr/local/bin/codex
/opt/homebrew/bin/codex
```

若你的组件在其他位置，需要调整 [RecentThreadReader.swift](Sources/KaylaMonitor/RecentThreadReader.swift) 中的 `executableCandidates`。面板也支持手动输入任务 ID 或完整任务链接。

## 从源码构建

```bash
git clone https://github.com/Metrio-ch/codex-focus-monitor.git
cd codex-focus-monitor
./scripts/test-core.sh
./scripts/test-hooks-config.sh
./scripts/build-app.sh
```

构建脚本通过 `xcrun` 查找当前 macOS SDK，将缓存放在项目的 `work/` 中。发布二进制使用路径映射并移除调试信息，打包前检查是否残留当前用户主目录路径。

产物为 `outputs/Kayla Monitor.app`。构建脚本会替换此位置的旧产物；需要保留时请先另行备份。产物仅作本地 ad-hoc 签名，未经 Developer ID 签名及 Apple 公证。

### 制作 DMG

```bash
./scripts/build-dmg.sh
```

脚本重新构建应用，制作包含应用、Applications 快捷入口和中文安装说明的压缩磁盘映像，验证映像并生成 SHA-256 校验文件。产物位于 `outputs/Codex-Focus-Monitor-<版本>-macOS-<架构>.dmg`，同名安装包已存在时会拒绝覆盖。架构取自当前构建主机，不生成 Universal 包。

### 只试运行，不修改全局 hooks

```bash
open "outputs/Kayla Monitor.app"
```

这种方式可以观察已选任务的本地会话日志，但仍会在 Application Support 中写入面板自身的状态。未配置事件 helper 时，范围外活动等依赖 hooks 的能力不完整。

### 完整安装

**此步骤会修改 `~/.codex/hooks.json`，请先确认你允许这一跨项目配置变更。** 若已有监控台在运行，请先从拉片右键菜单退出，再执行。若此前通过 DMG 装到了 `/Applications`，此脚本会另装一份到 `~/Applications`；之后请只运行脚本安装的那一份。

```bash
./scripts/install.sh
```

安装脚本会：

1. 构建应用并安装至 `~/Applications/Kayla Monitor.app`；已有应用移入备份目录。
2. 将独立 helper 安装至 `~/Library/Application Support/Kayla Monitor/bin/`。
3. 在备份 hooks 配置后，幂等追加 `UserPromptSubmit` 和 `Stop` 异步监听器，保留其他 handlers。
4. 打开应用。

helper 只追加本地事件，正常处理错误时也返回成功，避免妨碍主任务；它不负责判断任务最终完成。面板未启动时，helper 仍可记录事件，供下次启动补读。

## 日常使用

1. 将鼠标移到屏幕顶部拉片，点击 `+`，从最近任务中选择最多三个探索线程，也可粘贴任务 ID 或链接。
2. 把当前需要你讨论、检查或决策的任务设为“聚焦”；其他任务可以继续在后台运行。
3. 切换前点击“停靠”，检查并修改“当前讨论到”和“回来后先做”，确认保存。
4. 收到提醒后查看对应卡片，先确认上下文，再进入任务继续对话。
5. 当天的阶段确实告一段落时，手动标记阶段完成。该操作会清除这张卡片的恢复点。

右键拉片可进入设置或退出。当前显示器偏好写在 [PanelController.swift](Sources/KaylaMonitor/PanelController.swift) 的 `preferredDisplayName` 中，尚无图形化显示器选择器。

## 本地数据与隐私

监控台自身的数据默认保存在：

```text
~/Library/Application Support/Kayla Monitor/
├── state.json       # 卡片、恢复点、有限摘录和去重信息
├── events.jsonl     # helper 追加的事件
├── bin/             # 独立 helper
└── backups/         # 安装时保存的应用和 hooks 备份
```

- 通过只读方式观察选中任务在 `~/.codex/sessions/` 中已有的会话文件，不修改原始对话。
- 已选任务的输入和回复摘录，每侧最多 **2,048 个字符**；不会另行复制完整对话作为面板数据库。
- 未选任务的事件不保留输入和回复正文，仅保留任务 ID、项目、事件类型及时间等元数据。
- 摘录、恢复点和备份属于敏感本地数据。任务移出面板后，历史事件文件中可能仍有它曾被选中时的有限摘录；当前没有自动清理策略。
- 应用没有自行上传任务数据的网络客户端，也不调用远程模型生成摘要。最近任务读取通过本机 `codex app-server --stdio` 适配器完成；Codex 本身的网络行为由其自身配置决定。
- 源码仓库不包含运行数据、会话日志、凭证、应用二进制或本机备份；`.gitignore` 已排除对应文件与构建缓存。分发二进制仅作为 Release 附件提供。

## 实现结构

```text
Sources/
├── KaylaMonitor/        # AppKit 悬浮窗、SwiftUI 界面、任务读取与观察
├── KaylaMonitorCore/    # 状态模型、事件归并、会话解析、持久化
└── KaylaMonitorHook/    # 事件 helper 和核心自检入口
Resources/              # 应用标识、版本及 DMG 安装说明
Tests/python/           # hooks 配置工具测试
scripts/                # 应用/DMG 构建、安装、卸载与测试入口
docs/                   # 发布说明
```

主要状态来源是选中任务的本地会话日志；全局 hooks 提供提交与结束事件作为补充。监控台约每 0.4 秒检查输入，事件日志增量读取；状态 JSON 使用原子写入。最近任务列表的 app-server 读取逻辑封装在独立适配器中。

## 验证与版本记录

v0.3.4 提供 DMG 打包与校验文件，移除分发二进制中的本机构建路径，并补充标准 `Codex.app` 的 CLI 查找路径。本机通过 23 项核心自检、3 项 hooks 配置测试，以及 DMG 只读挂载、包内 helper 自检、签名完整性和 SHA-256 校验。未在全新 Mac 上完成首次安装实测。签名、架构与兼容性边界见 [发布说明](docs/release-notes-v0.3.4.md)。

v0.3.3 已通过 **23 项核心自检、3 项 hooks 配置测试**，覆盖状态切换、事件去重与乱序、三任务与单焦点限制、有限摘录、恢复点、计时、显示器选择、阻塞识别，以及配置安装/卸载保留其他 handlers。

v0.3.3 重点修复：

- 事件量超过 500 条后，全量回放与有限去重缓存叠加导致重复处理。
- 历史提交、延迟事件和旧会话快照导致最后活动时间倒退。
- 重启后，hook 接收时间晚于本轮开始时间时的同轮状态恢复。

新增回归覆盖了 1,201 条事件、半条日志追加、日志截断/替换、离线事件补读。**疑似停滞仍使用 15 分钟阈值，文案未变。**

## 已知限制与排查

- **状态并非权威任务接口**：会话格式、hooks 或 app-server 协议改变后，可能需要更新适配器；无法保证识别所有审批方式、失败或后台活动。
- **摘要需要检查**：恢复点是本地文本规则提炼，不是远程模型生成的完整总结。
- **顶部空间可能冲突**：面板位于系统顶栏层级，当前未单独处理所有刘海和菜单栏拥挤布局；请在自己的显示器组合中验证。
- **重启后显示不确定**：先打开原任务确认；监控台会根据可读日志恢复状态，不应把“状态待确认”当作完成。
- **最近任务为空**：检查前述 CLI 路径、app-server 是否可用，以及本机会话文件是否可读；也可以手动添加任务。
- **构建失败**：检查 `swift --version`、`xcode-select -p` 和 SDK 路径是否可用。只在本机可信源码上构建，不需要关闭系统安全防护。
- **疑似停滞**：先检查原任务是否仍有新活动；长时间运行的工具也可能达到 15 分钟提示条件。
- **更新后仍像旧版**：先退出旧进程再打开新应用；仅替换磁盘上的应用并不会自动重启已运行的版本。

## 卸载

仅通过 DMG 安装时，先退出应用、在设置中关闭已主动开启的登录启动，再将 `/Applications/Kayla Monitor.app` 移到废纸篓。本地恢复点保留在上述 Application Support 目录，需要清理时先确认有无应保留的数据。

通过源码脚本完整安装过 hooks 时，先退出监控台、关闭已开启的登录启动，再运行：

```bash
./scripts/uninstall.sh
```

卸载脚本只移除 Kayla Monitor 自己的 hooks 条目，并将 `~/Applications` 下的应用和整个 Application Support 目录移到废纸篓中的带时间戳目录。确认不再需要恢复点和备份之前，不要清空该目录。其他 hooks handlers 保留；DMG 安装在 `/Applications` 的副本需手动移除。
