# T06 外部工单追溯

**日期：2026-11-21** · 本文记录外部工单追溯切片，不代表 T06 整项验收完成。

## 实现范围

- 会话检索和本地事件库的事件详情显示可点击的外部工单号。点击后清空其他检索条件，按完整工单号匹配，并排除当前来源与事件 ID 组成的复合 Case 身份。
- 工单匹配保留大小写，忽略首尾空白并做 NFC 规范化。规范化键使用 Base64 UTF-8 写入 SQLite，避免 NUL 或特殊字符改变 SQL 绑定语义。
- 本地事件库 schema 2 为 Case 增加非空 `ticket_key` 列和工单索引。新库直接创建 schema 2。schema 1 在写入和读取前于一个事务中添加列、从保存的项目快照回填、建立索引，最后更新 `user_version`。
- 总数查询和分页查询共用工单及复合身份排除条件。来源快照、Observation、版本令牌和分页排序继续保持原有语义。
- 新增 `NMTest --case ticket-trace`，覆盖完整匹配、大小写、前缀排除、复制来源、稳定分页总数和 schema 1 迁移后的工单索引与 Observation 保留。

## 验证状态

- Release `TestRunner` 编译通过：`swift build --package-path macos -c release -Xswiftc -enable-testing --target TestRunner`。
- Release GUI 编译通过：`swift build --package-path macos -c release -Xswiftc -enable-testing --product NETworkManagerMac`。
- 2026-11-23 单独运行 Release `NMTest --case ticket-trace` 通过。修正了只写入第一条 Observation 的 schema 1 测试样本。用例核对迁移后的完整时间线、复测链接、工单索引和 schema 版本，并确认会话与 SQLite 检索对同一工单的复合 Case 排除结果一致。
- 2026-11-23 在隔离数据目录运行中文 Release arm64 App。两份合成项目各有 15 条事件，两份文件使用相同的 15 个事件 ID 和同一个工单号。会话检索和本地事件库均显示 30 条。点击第一份项目中一条事件的工单号后，两处均只排除该条事件，保留另一份项目的同 ID 记录，总数为 29。筛选后的第二页显示 4 条，不能继续翻页。清除筛选恢复 30 条并回到第一页。
- 关闭并重开本地事件库窗口后，仍显示 2 个来源和 30 条事件。对隔离 SQLite 库的只读检查确认 schema 2、30 条 Case 和 15 个不同的事件 ID。
- 编译输出仍有本机 Command Line Tools 搜索路径缺失警告，没有阻止上述目标完成。
- 本轮没有进行 GUI 操作、远程工单写回或现场网络探测。

## 未完成验收

正常导入和导入完成后的状态已验证。两份小文件很快读完，导入进行中控件是否正确禁用仍需观察。受控 LAN、VPN、真实现场及签名公证发布继续属于独立验收门禁。

## English summary

The shared session catalog and persistent local case library now expose external ticket references as exact, case-sensitive links. Clicking a ticket clears unrelated filters, keeps copied cases from explicitly imported sources, and excludes only the selected composite source plus incident identity. Schema 2 stores a normalized Base64 UTF-8 ticket key with an index. Schema 1 migration backfills from saved project snapshots in one transaction and updates `user_version` last. On November 23, the named Release `NMTest --case ticket-trace` check passed after the schema 1 fixture was corrected to seed all observations. The check verifies the complete ordered timeline, retest link, index and schema version, along with matching Case exclusion in session and SQLite searches. The Chinese Release GUI passed import, ticket selection, pagination and clearing in both views. Reopening the local library window restored both sources. Control state during import remains unverified.
