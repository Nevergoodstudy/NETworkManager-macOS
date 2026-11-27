# T06 人工巡检模板与记录

**日期：2026-11-20** · 本文记录工作区实现切片，不代表 T06 整项验收完成。

## 实现范围

- `NMCore` 新增项目内巡检模板、模板项、巡检记录及记录项。每个项目最多保存 20 个模板、30 条记录；每个模板最多 40 项。记录保存负责人、时间、逐项判据、结果、证据、整改责任人与期限。
- 创建记录时复制模板标题、版本和各项内容。之后修改模板只影响新记录，不会改写既有记录快照。缺少负责人、判据或必要证据时拒绝保存或不把结果计为通过。
- 首次保存巡检数据时项目 schema 升至 6。未使用巡检功能的旧项目保持原 schema；schema 5 文件不能携带 schema 6 巡检字段。
- 售后维护视图接入模板编辑、开始巡检及记录编辑。巡检由工程师手工录入，不调用网络探测。
- 普通报告只列记录数和结果计数；详细报告才包含模板、负责人、判据、证据和整改信息，并复用诊断导出的凭据脱敏逻辑。
- 新增中文界面本地化。入口位于现场项目的「售后维护」视图中的「人工巡检」。

## 验证

- `swift run --package-path macos -c release -Xswiftc -enable-testing NMTest --case inspection-project`：本轮之前已单独运行并通过；未并行启动其他测试用例。该用例覆盖旧 schema 不因未使用功能而升级、必填结果证据、模板快照、schema 6 保存重开、报告字段边界与凭据脱敏、拒绝无效记录及超量模板。
- 使用隔离输出目录和支持目录的 Release arm64 GUI/NMCP 构建成功，签名校验完成，应用保持运行。日志包含缺少 Command Line Tools 框架搜索路径的 linker warning，但构建成功。
- 初次中文 Release 界面检查在临时项目中填写并查看了结论、证据、整改责任人与期限，关闭时未保存项目。
- 2026-11-24，中文 arm64 Release 应用验证空巡检项显示校验提示，缺少负责人时保存按钮禁用。有效模板和记录通过 `⌘S` 保存为 schema 6，退出后重新打开项目可查到负责人和巡检项，落盘记录继续引用原模板 ID。
- 复验发现打开项目时 SwiftUI 会用相同的项目值写回文档绑定，引发退出保存提示。文档视图现在跳过这种写回。修复后，打开项目、切换到售后维护和预览报告均保持文档未编辑。默认报告显示巡检次数，打开详情后显示模板、负责人和巡检项。进程正常退出，项目文件字节保持一致。

## 未完成验收

人工巡检的本机界面检查已完成。最低支持 macOS 和客户现场环境仍待验证。整项 T06 还需验证受控 LAN/VPN 服务复测链和真实集成。发布门槛见 [T01–T16 实施与验收清单](NEXT_GENERATION_BACKLOG_2026-11-09.md)。

## English summary

This working-tree slice adds reusable manual inspection templates and per-record template snapshots to field projects. The named Release case `inspection-project` passed. On November 24, the isolated Chinese arm64 Release app rejected an empty template item and disabled saving a record without an owner. A valid template and record were saved as schema 6 and reopened. The document binding now ignores identical project values. Opening the project, switching phases, and previewing summary and detailed reports left the document unedited. The app exited normally and the project bytes stayed identical. T06 service retests on controlled LAN/VPN, live integrations and the release matrix remain open.
