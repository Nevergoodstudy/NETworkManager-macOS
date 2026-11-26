# MacBook 网络工程工具对标与实施顺序调整

**2026-11-18 初稿 · 2026-11-19 修订**

[计划入口](README.md) · [原中文方案](NEXT_GENERATION_RESEARCH_2026-11-09.zh-CN.md) · [16 项任务](NEXT_GENERATION_BACKLOG_2026-11-09.md) · [当前移植状态](../PORTING_STATUS.md)

**首个联网场景是 MacBook 换网后复测一个业务服务。** 工程师复用交接项的目标，查看当前和上次的观测条件，定位 DNS、连接、证书或 HTTP 阶段，并把结果交给下一班。各单项工具仍可独立运行。

先验收中文交接单与离线基线回看，随后开展联网复测。现场交付顺序由 [现场工程改进计划](FIELD_ENGINEERING_PLAN.md) 维护。本页记录工具对标和 MacBook 实机验收用例。

## 现状与调整边界

本次对照 `main` 的 `b21fe63`：已有 SwiftPM、SwiftUI/AppKit 原生应用，平台政策仍为 **Apple Silicon（arm64）、macOS 14+**。T01–T04 有九个已合并切片，**4/16 项有实现，0/16 整项完成验收**。SQLite 和默认工作区独占所有权已经落地；历史分页的 UI 接入、异步写入和异常存储矩阵仍未完成。单台 M4 Pro 的 [ad-hoc 打包实测](APPLE_SILICON_VALIDATION_2026-11-18.md)、[SQLite 基础](T04_SQLITE_FOUNDATION_2026-11-18.md)与[所有权验证](T04_WORKSPACE_OWNERSHIP_2026-11-18.md)不能替代最低系统、真实设备和正式分发验收。

本页调整的是**下一轮实施顺序与交付范围**。保留 T01–T16 的编号、原优先级、依赖、估算和整项验收；原 JSON、CSV、HTML 与 DOCX 继续作为基线，不用本页把任何事项标为完成。

2026-11-19 的工作区另外新增 [T05 稳定资产身份与 T06 多事件时间线切片](T05_T06_LOCAL_SLICES_2026-11-19.md)。NetBox 地址变化可保留本地身份与历史，项目内可记录独立事件并关联交接版本、设备快照和已保存复测。定向 Release 检查、GUI/NMCP 构建启动及中文事件保存重开已通过；两项尚未整项验收。必要检查后继续接口双栈和 Case/Observation 开发，受控网络矩阵单独保留。

## 对标：学具体工作流，不照搬整套产品

依据厂商文档与发布页面核对；未安装竞品，也未测试性能、功耗或现场兼容性。系统要求和功能以各厂商页面为准。

| Mac 同类工具／官方资料 | 值得对标的体验 | 纳入本项目的决定 |
|---|---|---|
| [Neo Network Utility](https://www.devontechnologies.com/apps/freeware/networkutility) · 通用诊断（macOS 13+） | 在原生界面查看网卡和链路状态，使用 Ping、Lookup、Traceroute，支持键盘操作和多窗口 | 在打包 App 中用键盘从验收项打开复测并自动带入目标，换网后新结果读取当前上下文，旧运行保留原值。 |
| [PingPlotter](https://www.pingplotter.com/download/release-notes/) · [路由回看](https://www.pingplotter.com/manual/route_changes/) | Apple Silicon 原生版。可以从目标延迟和丢包历史回看逐跳与路由变化 | 先按时间、实际对端和路径来源对照两次结果。关键条件有变或缺失时标为不可直接比较。受控用例中中间跳不回应、终点正常时，终点维持正常。短时前台时间线后排。 |
| [PeakHour](https://help.peakhour.app/user-guide/main-view/internet-dashboard/) · [系统要求](https://help.peakhour.app/user-guide/requirements/)（macOS 14.6+） | 将本机、路由器、ISP、互联网分开展示；网关吞吐依赖设备支持 | 分开标注观测点、接口速率、RTT 和实测吞吐。休眠、切网记录为缺口或新分段，不用零值补齐，不根据相邻跳 RTT 差值归因。 |
| [WiFi Signal](https://www.intuitibits.com/products/wifisignal/) · [WiFi Explorer Pro 3](https://www.intuitibits.com/products/wifiexplorerpro3/) | 前者展示当前连接的信号及变化，后者提供接入点、信道和传感器视图 | 先做当前连接快照。区分未连接、字段不可取得和实际观测值。切到 USB 网卡后保留旧 Wi-Fi 观测时间，默认报告省略 SSID/BSSID。专业扫描、频谱和传感器后排。 |
| [LanScan](https://apps.apple.com/us/app/lanscan/id472226235?mt=12) · 本地设备盘点（macOS 12+） | 识别接口并展示 IPv4／IPv6、名称来源和 CSV 导出 | 资产阶段先预览再人工确认。相同链路本地 IPv6 在不同接口上的观测分别呈现。设备身份由站点、路由域和稳定引用决定。 |
| [Royal TSX](https://www.royalapps.com/ts/mac/features) · 远程会话 | 连接、凭据引用和 SSH 网关可分开管理 | T08 先做从设备打开连接、选用站点跳板、验证主机密钥；恢复窗口不自动连接、转发或执行命令。不先追求 RDP／VNC 功能对齐。 |
| [Wireshark](https://www.wireshark.org/download.html) · [离线捕获文件手册](https://www.wireshark.org/docs/wsug_html_chunked/ChIOOpenSection.html) | macOS 安装包含 arm64，支持打开既有 `pcapng` 并预览文件信息 | T12 优先处理用户选取的离线证据和受限摘要。受控用例覆盖损坏、超限和取消，默认报告省略包内容及原文件。深度分析交给外部工具。 |
| [Cisco ThousandEyes Endpoint Experience](https://docs.thousandeyes.com/product-documentation/end-user-monitoring/viewing-data/endpoint-agent-views-reference) · 端点可观测性 | 按 DNS、VPN、HTTP 和网络路径等维度检查观测，并可回看历史 | 参考结果组织方式。对照同一受控服务在 VPN 内外的两次人工复测，报告保留各次实际对端和 DNS 模式。 |

## 单服务复测验收矩阵

先用隔离数据和受控目标验证系统 DNS 与 TCP，再加入 TLS 和 HTTP 分层结果。记录实际验证过的 App、系统版本、接口条件与结果。项目级交接顺序及设备身份、事件存储的依赖见 [现场工程计划](FIELD_ENGINEERING_PLAN.md) 和 [工程清单](NEXT_GENERATION_BACKLOG_2026-11-09.md)。

| 用例 | 验收观察 |
|---|---|
| 同一目标在 Wi-Fi、USB 网卡、测试 VPN 间切换 | 新旧运行独立，迟到回调不会覆盖新运行。列出各自地址族、实际对端、DNS 模式和上下文来源。系统默认路由标为快照。关键条件不同或取不到时提示不可直接比较。 |
| 双栈、IPv6-only、VPN split DNS 与 `.local` | 记录系统解析结果和来源。系统解析失败时，允许用户另发起已知 IP 的 TCP 对照。显式 DNS 结果独立保存。 |
| TCP 拒绝、超时、权限受阻与取消 | 受控目标逐项核对，依赖前一阶段的步骤显示未执行，已结束的结果可回看，退出后清理本次任务。 |
| HTTPS 接入后分别验证证书不受信与 HTTP 非成功响应 | 留下各阶段的独立结果与实际对端。默认交接摘要省略敏感字段，预览和落盘一致。 |
| 睡眠恢复、Wi-Fi 字段缺失与 Local Network 权限 | 观测缺口与零值分开。分别记录位置权限、Local Network 首次询问和拒绝后恢复。 |

截至 2026-11-19，单服务复测代码与 `NMTest --field-project-only` 的验证范围已覆盖授权校验、状态映射、结果记录、持久化和基线关联；中文 GUI 已直接观察两条授权回环 TCP 记录、回环 DNS 成功和中文超时提示。离开视图取消有 GUI 操作及 SQLite `cancelled` 终态证据；点击取消按钮/Escape 路径和旧 DNS 文档关闭重开尚未验收。回环 fixture 不证明 LAN 权限、VPN 分流、跨接口或正式签名行为。逐项环境、样例哈希与剩余门禁见[2026-11-19 验收记录](FIELD_ACCEPTANCE_VALIDATION_2026-11-19.md)。

## 实现与 MacBook 实机验收约束

- **复用已有模块。** 保留 [SwiftPM targets](../Package.swift) 和 [主窗口](../Sources/NMApp/main.swift)；从总览或资产进入同一诊断界面。将执行的接口收敛为目标、明确的 DNS 模式、总预算与取消，快照及探测作为可注入 adapter。复用 [DiagnosticService](../Sources/NMCore/DiagnosticService.swift)、[Repository](../Sources/NMCore/AssetRepository.swift) 和 [现有 JSON／Markdown 导出](../Sources/NMCore/DiagnosticEvidence.swift)，不新增第二套运行或存储。独立工具与新界面共用结果语义；常用操作可用键盘触达，不要求此次改写所有现有视图。
- **记录观测，不替工程师下结论。** 标注实际地址族、目标地址、时间、测试方法；若只知道默认路由则标明“系统快照”，不可声称是该目标的实际出口。路径变化时标记不可直接比较，不合并为同一段数据；不写死 `en0`。HTTP 可评估 `URLSession`，独立 TLS 观察可评估 `NWConnection`（见 [Apple TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)）；HTTP 不自动跟随跨主机重定向，TLS 不跳过系统信任校验。若各阶段使用独立连接，应保留各自实际对端，不暗示它们是同一连接。
- **权限与发布分开取证。** [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 说明 macOS 自动允许从 Terminal/SSH 启动的命令行工具及其子进程访问本地网络，因此 CLI 测试不能证明 `.app` 的权限行为。注意本地网络上的系统 DNS 请求属于文档列明的豁免情形；应使用非 DNS 的局域网对端检查 App 权限提示，指定 DNS 服务器的直接请求另行记录。Local Network 权限从 macOS 15.0 引入，15.1 修复相关问题；用 Apple 签发身份签名且主程序 UUID 唯一的 `.app`，在有直接 Wi-Fi 或以太网对端的受控 LAN 上记录首次询问、拒绝及允许后重试。macOS 27.2 起可在「系统设置 → 隐私与安全性 → 本地网络」移除应用条目重置授权；更早系统没有该重置入口，可用 VM 快照或新用户隔离状态。本机 macOS 27.2.1 支持此入口。无法判定权限时保留未知状态。Location Services/Wi-Fi 字段另测；[现有 CoreWLAN 评估](PROGRESS_2026-11-14.md#t01corewlan-字段能力评估)不等于已验证。T15 还需真实现场互操作，并按[已有发包脚本](../Scripts/release-dmg.sh)对 App 和内置 helper 检查 Developer ID 签名与 Hardened Runtime，实测公证、票据装订及下载后由 Finder 安装与 Gatekeeper 首次打开。
- **本地优先。** 用户发起单一获授权目标诊断，不默认扫网、测速、抓包或运行常驻 helper；不自动把内网名称发给公共 DNS 作对照。分享前预览并遮盖凭据、SSID/BSSID 和可选的内部地址／主机名；不收集 HTTP 正文、不自动上传。退出不留下本项目探测进程；已有命令行工具的测试不替代图形应用证据。

**受控网络验收包：** 用一台 Apple Silicon MacBook、一处受控 LAN 和一个有 split DNS 的测试 VPN，验证「VPN 内的主机名解析失败，但用户使用已知 IP 单独做 TCP 对照时连得上」能被界面和导出准确区分；再切到 USB 网卡或断开 VPN 复跑一次。分别记录 fixture、打包 App 和真实网络的证据，未测项明确留空。该验收包独立保留，不阻塞接口双栈、事件检索及 TLS/HTTP 功能开发。

## English summary

The first connected workflow compares observations of one authorized service before and after a MacBook network change. Test system DNS and TCP first, then report TLS and HTTP as separate stages. Preserve each run's address, timestamp and evidence source. The field plan defines the delivery order, beginning with offline handoff. This comparison is based on vendor documentation. The matrix defines the remaining reproducible tests for packaged apps and controlled networks.
