Codex Focus Monitor — Codex 项目跟进与聚焦工具

项目：https://github.com/Metrio-ch/codex-focus-monitor

安装
1. 将 Kayla Monitor.app 拖到旁边的 Applications 文件夹。
2. 从“应用程序”打开 Kayla Monitor，再推出这个磁盘映像。
3. 将鼠标移到屏幕顶部中央，展开拉片，用 + 选择最多三个任务。

应用保留 Kayla Monitor 这个原名称及数据目录，以兼容已有安装。
本安装包按发布资产名称标注架构；arm64 包适用于 Apple Silicon Mac。
需要本机安装 Codex 桌面应用，并且已有可读取的任务会话。

安全与隐私
- 本包只有 ad-hoc 签名，没有 Apple Developer ID 签名及公证。
  macOS 可能阻止首次打开。请先核对下载来源和 SHA-256；不确定时不要打开。
  也可以从仓库审阅并自行构建。不要关闭 Gatekeeper 或系统完整性保护。
  Apple 说明：https://support.apple.com/102445
- 这是第三方辅助工具，非 OpenAI 官方产品。
- 拖拽安装不会修改全局 hooks、安装命令行插件或自动开启登录启动。
- 面板数据写入 ~/Library/Application Support/Kayla Monitor/，包含有限对话摘录。
- 应用只读观察已选任务的本地会话文件，不会自行上传任务数据。

使用边界
“疑似停滞”表示 15 分钟没有检测到新活动，不代表任务确认失败。
“今日阶段完成”需要手动确认；本轮回复结束只显示“等你判断”。
完整的范围外活动监听需要可选 hooks，请查看仓库 README 后自行决定是否安装。

卸载或更新前，请先右键顶部拉片，退出 Kayla Monitor。
具体数据保留规则、完整安装、卸载方法和已知限制请阅读仓库 README。
