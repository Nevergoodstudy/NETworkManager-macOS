# T05 / T06 后续开发：接口双栈快照与项目事件检索

**日期：2026-11-19** · 当前工作区增量，尚未提交或合并。

[现场计划](FIELD_ENGINEERING_PLAN.md) · [前一轮身份与事件切片](T05_T06_LOCAL_SLICES_2026-11-19.md) · [工程清单](NEXT_GENERATION_BACKLOG_2026-11-09.md)

## T05：按设备读取接口、双栈地址与路由域

NetBox 设备列表继续沿用显式预览与确认导入。基本读取同时保留 IPv4/IPv6 两个主地址，并优先使用结构化 `address` 字段；不改变已有本地诊断目标的选择规则。在某台设备的预览行点击“读取接口与地址”，才会读取该设备的接口与地址页；只发 GET，使用 `device_id` 过滤和已有凭据、同源分页及响应体限制。

完整读取有 30 秒总预算，每个端点最多 10 页，最多 512 个接口与 2048 个地址。两个端点均成功且整个映射有效后才更新预览；401/403、损坏记录、跨设备接口、错误链接、重复对象、超限或取消均不会提交半份接口清单。预览仍需确认本地更新后才会保存。无主 IP 的设备继续遵循既有不可导入规则。

接口与地址按来源实例、对象类型和远端 ID 保持关联，不按 IP 去重。记录接口名称、可取得的配置启用状态、MTU、MAC、VRF，以及各地址的 CIDR、地址族、主地址标记和所属接口。地址自身的 VRF 不由接口名称推断；显式 `vrf: null` 与字段缺失分别表示全局表与未知。数值相同的 VM/FHRP 对象 ID 不会被当作设备接口。范围是所选设备返回的可见接口及其关联地址，不声称包括其他分配类型或不可见数据。官方当前地址过滤实现使用 `vc_interfaces()`；若端点返回虚拟机箱其他成员的地址，客户端仅保留实际已读取接口集合中的关联地址。

资产详情新增“配置接口与地址”。来源主地址和扩展接口清单分别展示；接口清单有独立读取时间，基本设备刷新不会给旧清单补上新时间。新清单替换旧清单，来源已删除的接口/地址不继续累积。本地设备 UUID、人工名称/备注/凭据、手动改址及旧诊断目标继续保留。设备搜索也能匹配已保存的其他地址。

这些是来源配置快照，不能证明接口当前可达、Mac 实际出口或 VRF 探测能力。SQLite 沿用 Codable payload，不新增数据库 schema。

实现：[快照模型](../Sources/NMCore/AssetNetworkInventory.swift) · [NetBox 读取与映射](../Sources/NMIntegrations/NetBoxNetworkInventory.swift) · [导入预览](../Sources/NMIntegrations/NetBoxView.swift) · [资产详情](../Sources/NMAssets/AssetNetworkInventoryView.swift)

## T06：项目内筛选与跨文件只读检索

售后维护中的事件选择增加文本和状态筛选。文本按空白拆分为多个条件，全部条件都需匹配；可跨标题、负责人、工单号、资产快照和时间线作者/备注查找。

“现场项目”入口新增“检索项目事件”。工程师显式选择最多 40 个 `.nmfieldproject` 文件后，在此窗口中查看已保存快照。每个文件只读取到 512 KB 上限加一个字节后交给原项目解码器校验，读取在后台任务执行。损坏或超限文件独立显示错误；刷新失败保留该文件之前的快照。关闭窗口结束本次检索会话，不自动扫描目录或新增持久化副本。

检索支持文本、事件状态、发生时间范围和设备关联组合；空时间线按事件创建时间匹配，其他事件按条目发生时间匹配。默认按最近发生时间排序，同时间按来源和事件 ID 稳定排序，每页 25 个事件。复制的项目文件保持独立来源，不把两份同 ID 的事件悄悄合并。可查看来源文件、载入时间、交接版本、资产快照、完整时间线及复测引用，并打开源项目。

在详情选择“查找此设备的事件”时，优先按稳定远端身份匹配，找回换 IP 前后的事件；无远端身份时使用本地设备 UUID，不凭相同 IP 关联其他设备。未保存编辑不会出现在检索快照中，需先保存再刷新。当前能力是有界的会话内只读汇总，不替代完整 SQLite Case/Observation 库或持久化全文索引。

实现：[检索与分页](../Sources/NMCore/FieldIncidentSearch.swift) · [有界文件读取](../Sources/NMAssets/FieldIncidentFileLoader.swift) · [检索界面](../Sources/NMAssets/FieldIncidentCatalogView.swift)

## 集中验证

本轮遵循先实现本批功能、最后集中验证的顺序，没有重复 DNS 深测。

| 项目 | 结果 |
|---|---|
| Release `NMTest --next-development-only` | 通过。使用 `swift run --package-path macos -c release -Xswiftc -enable-testing NMTest --next-development-only`，最终输出 `NMTest: next development checks passed`。包含前一轮身份与现场项目检查，以及本轮接口/双栈/路由域、SQLite 往返、只读回环 NetBox 请求、事件检索/分页/有界文件读取检查。 |
| Release GUI / NMCP 构建 | 通过。使用隔离输出与支持目录运行 `script/build_and_run.sh --verify`，GUI 和 NMCP Release 构建、arm64-only bundle 检查、ad-hoc 签名与应用启动均通过。仅见既有 CommandLineTools 搜索路径 linker warning。 |
| 中文事件检索 GUI | 通过简短检查。在「现场项目 → 检索项目事件」显式载入合成项目，观察到 1 个文件、1 个匹配事件；选中后可见来源、工单、交接版本和报障时间线。工单 `SYNTH-20261119-01` 保留 1 个结果，无匹配词显示 0 个，清空后恢复 1 个；关闭后返回现场项目入口。 |
| 静态与文档检查 | `git diff --check`、本地化重复键及新增 UI 文案覆盖、修改文档的本地链接检查通过。 |

GUI 使用 `/private/tmp/nm-network-search-20261119.mKHQV1/dist/NETworkManager.app`，支持目录为同级 `support/`。载入的合成文件是 `/private/tmp/nm-next-slices-20261119-7vjljtts/fixtures/maintenance-incidents.nmfieldproject`。此次 GUI 没有执行项目中的诊断，也没有验收 NetBox 接口读取、确认导入和资产详情的完整界面路径；这部分目前的证据来自模型及回环 HTTP 检查。

所有数据为合成资料；远端请求仅使用临时回环 HTTP fixture，不探测返回的文档示例 IP。真实 NetBox 版本/权限组合、FHRP/VM 互操作、macOS 最低版本、LAN/VPN 和正式分发仍需独立验收。

## 官方研究依据

本轮调用网络搜索/打开能力未得到可用页面正文，随后通过 HTTPS 成功读取 NetBox 官方 `netbox-community/netbox` 仓库的 `main` 文档：

- [IP address model](https://github.com/netbox-community/netbox/blob/main/docs/models/ipam/ipaddress.md)：IPv4/IPv6 各有主地址；地址保留主机地址与掩码，未分配 VRF 的地址属于全局表。
- [Interface model](https://github.com/netbox-community/netbox/blob/main/docs/models/dcim/interface.md)：接口有 VRF，`mac_address` 可反映关联的主 MAC 地址。
- [REST API](https://github.com/netbox-community/netbox/blob/main/docs/integrations/rest-api.md)：对象通过类型与数值主键标识，地址关联使用 `assigned_object_type` 和 `assigned_object_id`；接口列表可按设备过滤。
- [地址过滤源码](https://github.com/netbox-community/netbox/blob/main/netbox/ipam/filtersets.py)：收尾阶段通过 HTTPS 重试读取成功。`IPAddressFilterSet.device_id` 使用主键与 `filter_device`，后者按 `device.vc_interfaces()` 关联的接口过滤地址。客户端另外校验实际读取的接口集合。本轮回环 fixture 验证客户端发送的过滤参数和映射，具体部署版本、虚拟机箱范围与权限仍需真实实例验收。

本机研究缓存位于 `/private/tmp/nm-next-development-20261119-research/`。这是 2026-11-19 读取到的未固定版本文档，不据此声称验证了最新发布版或实际 NetBox 部署。

## 剩余开发

T05 继续保留来源站点迁移策略、旧记录显式认领和真实集成验收；T06 继续实现持久化 Case/Observation 库、巡检模板及独立 TLS/HTTP 阶段。本批是两项的进一步切片，整项验收保持开放。
