# T05 / T06：稳定资产身份与本地事件时间线

**日期：2026-11-19** · 本地工作区增量，尚未提交或合并。目标平台为 Apple Silicon、macOS 14+。

[现场工程计划](FIELD_ENGINEERING_PLAN.md) · [工程任务清单](NEXT_GENERATION_BACKLOG_2026-11-09.md) · [文档索引](README.md)

## 交付范围

后续增量见[接口双栈快照与项目事件检索](T05_T06_NETWORK_SEARCH_2026-11-19.md)，下文保留前一个切片完成时的范围。

用户要求在必要验证后继续其他功能开发，本轮从 DNS GUI 深测转入 T05、T06。已合并的基线仍覆盖 T01–T04（4/16）；本地工作区另有 T05、T06 的部分实现。**0/16 整项验收完成。** 下列切片不代表接口双栈模型、服务诊断链或现场互操作全部完成。

## T05：地址变化后保留设备身份

- 用 `instance + objectType + remoteID` 标识外部对象。NetBox 设备映射保留 `dcim.device` 和正数设备主键。实例使用规范化的 base URL，与 Keychain 凭据引用分离；清除 URL 凭据、查询和 fragment，保留 base path 以区分同主机上的实例。此设计对应 NetBox REST 文档中的对象类型 endpoint 和数据库 `id`。
- 在同一工作区按稳定身份刷新，IPv4/IPv6 地址、来源站点名称变化不另建同一设备；保留本地 UUID、名称、备注、凭据引用、站点关联、编辑时间和历史诊断目标。来源更新只接受更晚的抓取时间，vendor/role 只填空。
- `sourceAddress` 与当前 `address` 分开保存。当前地址仍等于上次来源地址时才跟随来源刷新；手工改址保留，来源地址和抓取时间继续前进。设备详情展示远端对象和不同的来源地址。
- NetBox 预览允许显式选择“新增或刷新”，展示存储错误并区分处理数量与新增数量。不同 remoteID、实例、base path、对象类型的同 IP 对象可并存；同工作区的重复稳定身份由 Repository 校验拒绝。
- 老数据缺少新字段时仍可读取。没有 remoteID 的旧来源继续使用原有匹配规则；**不会仅凭同 IP 把旧资产自动认领为带新 remoteID 的对象**，因此首次导入可能出现需要工程师辨认的旧记录和新记录。SQLite 使用现有 Codable payload，无 schema 迁移。

主要实现：[身份](../Sources/NMCore/ExternalAssetIdentity.swift)、[合并](../Sources/NMCore/Assets.swift)、[仓库校验](../Sources/NMCore/AssetRepository.swift)、[NetBox 映射](../Sources/NMIntegrations/NetBox.swift)、[刷新界面](../Sources/NMIntegrations/NetBoxView.swift)。

剩余：完整接口及双栈地址集合、VRF/路由域、来源站点迁移策略、旧记录的显式关联流程、真实 NetBox 互操作和异常存储矩阵。

## T06：一个项目记录多个维护事件

售后维护页新增“维护事件”。一个项目最多 20 个事件，每个事件最多 60 条时间线记录；512 KB 文档总限制继续生效。可以录入标题、负责人、外部工单号，手动设置处理中、恢复观察中或已解决。新建时显式选择交接版本和可选设备快照；应用中创建后的关联保持固定，修改事件资料不重写历史资产地址。

时间线类型包括报障、响应、升级、临时恢复、复测和备注。发生时间与记录时间独立保存，补录按发生时间排序。选择“记录复测”时，可以显式关联与该事件交接版本一致的已保存复测，也可以保留无诊断链接的人工记录。时间线操作不执行网络请求、不自动改交接结论，事件状态由工程师维护。删除项目中的复测结果只清除对应链接，人工时间线文字保留。

首次保存事件时项目升级到 schema 4；旧 schema 1–3 无需先迁移即可打开，没有事件时不补造事件。事件写入通过整个文档的字段、数量、版本/复测引用及体积校验后再提交值。项目文件仍是明文 JSON，源记录中的客户资料和人工备注由工程师管理。

普通项目报告默认只显示事件数量、状态和条目数。打开“详细内容”才包含标题、负责人、工单、设备快照、远端身份、作者和备注；详细导出对已知凭据形式应用现有 redactor。结构化验收报告保持原有逐行选字段流程。

使用：现场项目 → 售后维护 → 新建事件 → 选择关联并保存 → 添加时间线条目；使用 `⌘S` 保存项目。切换事件可分别回看，不需要启动任何诊断。

主要实现：[事件模型](../Sources/NMCore/FieldIncident.swift)、[文档校验与报告](../Sources/NMCore/FieldProject.swift)、[事件界面](../Sources/NMAssets/FieldIncidentView.swift)。

剩余：Repository 中完整 Case/Observation 库及分页检索、按稳定设备身份跨文件追溯、巡检模板、TLS/HTTP 独立阶段、外部工单接口和正式现场验收。工单号目前只是本地文字引用。

## 本轮验证

| 检查 | 结果与边界 |
|---|---|
| Release `NMTest --field-project-only` | 通过。包含原项目/验收/复测检查及新事件检查；覆盖旧格式、两个独立事件、补录排序、设备快照、v4 往返、错误基线/复测引用、删除复测后保留人工记录、数量上限、拒绝后的原值不变、默认报告隐私和详细内容脱敏。 |
| 同一 Release 可执行文件 `NMTest --asset-identity-only` | 通过。只用合成资产和本机临时 SQLite，覆盖规范化、映射、换 IP/地址族、乱序快照、本地编辑保护、同 IP 对象隔离、SQLite 重开与历史分页读取。没有访问 NetBox 或探测合成 IP。 |
| Release 应用构建启动 | 通过。使用仓库 `script/build_and_run.sh --verify`，GUI 与内置 NMCP 均构建完成，arm64-only、包内代码及签名检查通过，隔离 `.app` 启动成功。只有既有 CommandLineTools 搜索路径 linker warning。本轮不重复 DMG 生命周期验证。 |
| 新事件界面 | 中文 Release GUI 通过简短路径：打开合成项目 → 售后维护 → 新建事件，填写标题/负责人/工单号并关联交接版本 1 → 添加报障条目 → `⌘S` → 关闭文档并重开。重开后标题、负责人、工单号、原版本关联和报障文字均保留，显示 1/60 条目。本次没有选择设备或从界面关联复测，也没有启动任何网络诊断；多事件隔离与引用规则由上述定向检查覆盖。 |

隔离应用：`/private/tmp/nm-next-slices-20261119-7vjljtts/dist/NETworkManager.app`。支持目录：同级 `support/`。合成项目：同级 `fixtures/maintenance-incidents.nmfieldproject`，21,947 B，schema 4，1 个事件、1 条时间线、原有 2 个交接版本和 4 条复测。SHA-256：`f51b8a55f26c6b2253c0f686ed73482beed1cd54747847ac1c2b09de13ad1186`。临时路径清理后不可用，不属于发布资产。

诊断网络矩阵沿用 [P0 验收记录](FIELD_ACCEPTANCE_VALIDATION_2026-11-19.md)，本轮不重复执行 DNS 或现场网络测试。最低系统、真实 LAN/VPN、Apple 签名权限恢复、公证和客户现场仍开放。

## 官方资料与研究边界

NetBox REST API 文档：<https://netbox.readthedocs.io/en/stable/integrations/rest-api/>。本轮网络搜索/打开工具没有返回可用内容，直接重新抓取收到 HTTP 403；对象主键规则通过同日已获取的官方文档缓存复核。没有据此宣称核实了最新 NetBox 版本或真实实例行为。

## English summary

Two working-tree slices advance T05 and T06. NetBox device identity now uses source instance, object type and remote primary key so address changes retain local history while explicit local edits survive refresh. A portable field project can keep multiple manual incident timelines, frozen asset/revision associations and explicit references to saved retests. Focused Release checks and the packaged GUI/NMCP build passed. A short Chinese GUI check created an incident and a reported entry, saved the project and verified both after reopening, without running diagnostics. Full dual-stack/interface modeling, persistent Case/Observation queries, TLS/HTTP stages and field/release acceptance remain open; neither whole task is marked complete.
