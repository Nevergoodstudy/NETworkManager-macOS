# T06 单事件 Case/Observation 导出

**日期：2026-11-20** · 本文记录事件检索详情中的导出切片，不代表 T06 整项验收完成。

## 实现范围

- 事件详情提供 Markdown/JSON 格式选择和内容预览，并通过 macOS 文件保存面板导出。
- 导出只包含当前 Case、关联设备快照、当前事件的时间线 Observation，以及时间线明确关联的复测摘要；不包含来源路径、项目客户/站点信息、其他事件或无关复测。
- JSON 使用独立版本化结构和 ISO 8601 日期。Markdown 对动态内容进行语法转义；两种格式均复用 `DiagnosticEvidenceExporter` 的凭据脱敏。
- 新增简体中文界面用语和单个独立用例 `NMTest --case case-export`。

## 验证

- `git diff --check` 通过。
- `swift build --package-path macos -c release -Xswiftc -enable-testing --target TestRunner` 构建通过，包含 `NMCore`、`NMAssets` 和 `NMTest`。构建输出有既有的 Command Line Tools 搜索路径 linker warning。
- `swift run --package-path macos NMTest --case case-export` 在 Debug 配置下单独通过。用例按 Markdown 转义后的地址文本及当前语言的事件类型标签断言；本轮没有启动其他测试用例。
- 2026-11-23 重新运行独立 Release `NMTest --case case-export`，用例通过。
- 2026-11-23 在隔离数据目录的中文 Release arm64 App 中，从本地事件库导入包含两条合成事件的项目。选中其中一条，切换 Markdown 和 JSON 预览，分别通过系统保存面板导出。两份文件均保留所选事件的工单号和唯一观测，合成令牌已脱敏，来源文件名、项目站点和另一条事件均未写入。保存后的 Markdown 保留中文与转义，JSON 可解析且版本为 1。
- 2026-11-24 扩展 Release `NMTest --case service-project`。应用执行器发起回环 HTTP HEAD 并收到 204。用例显式附加复测、关联事件、保存并重开项目，导入事件库后移除临时项目文件，再用完整复测数据导出 Markdown 和 JSON。JSON 在既有 `retest` 中增加可选 `method` 和 `serviceEvidence`，沿用原有 schema 版本。两种导出均排除请求路径和来源文件名。独立 `case-export` 复验旧复测摘要和脱敏，`tls-untrusted` 复验系统信任拒绝自签名证书。
- 同日，Release `NMTest` 和 `NETworkManagerMac` 在 `-strict-concurrency=complete` 下构建通过。共享导出路径的 `pcapng-case-attachment` 单独通过。集中测试保持暂停。此次服务复测关联及导出通过定向用例验证。

## 未完成验收

可信 TLS 成功、受控 LAN/VPN 的 DNS、TCP、TLS/HTTP 复测链、现场资料审查和正式分发仍按 T06 与 T15 的整项验收执行。

## English summary

The incident search detail previews and exports one selected case and its observations as Markdown or JSON. The named Release check `NMTest --case case-export` passed on November 23. The isolated Chinese Release arm64 app saved both formats from an imported two-case fixture. The saved files contained the selected case and its observation, redacted the synthetic token, and omitted the source filename, site, and other case.
