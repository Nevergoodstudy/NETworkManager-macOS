# macOS 功能对照矩阵

这份矩阵按 Windows 版网站工具清单逐项记录 macOS 版的实际状态。`Native`
表示功能由 Swift/Core 实现；`System replacement` 表示使用 macOS 自带命令、URL
scheme 或 Terminal.app 完成相同目的；`Optional dependency` 表示需要用户安装
一个 macOS 客户端或命令；`Partial` 表示界面和核心路径已实现，但 macOS 没有
Windows 对应的公开 API，某些高级选项仍受平台限制。

| Windows 工具 | macOS 状态 | 实现与限制 |
| --- | --- | --- |
| Dashboard | Native | 运维工作台按监控、发现、诊断、操作和资源库分组工具；显示默认路由、接口、socket 和 ARP 返回值。网关 ICMP 仅在用户点击探测后发送。局域网发现每次最多 2,048 个 IPv4 地址、并发 32 个 ICMP 探测，并可把在线主机带入端口扫描器。 |
| Network Interface | Native | `getifaddrs` 枚举 IPv4/IPv6、掩码和接口状态；带宽与接口配置交给 macOS 系统设置。 |
| WiFi | System replacement | 通过 `system_profiler SPAirPortDataType` 解析当前网络、BSSID、信道和安全类型；连接、断开和主动信道扫描由 macOS 管理。 |
| IP Scanner | Native | CIDR、通配符、区间解析和原生 ICMP；原生 datagram socket 在某些 macOS 配置下收不到回包时，自动安全回退到参数化的 `/sbin/ping`。 |
| Port Scanner | Native | BSD TCP connect、端口表达式和并发扫描；不能把 TCP connect 结果等同于 Windows 原始 SYN 扫描。 |
| Ping Monitor | Native | 原生 ICMP 轮询并带 `/sbin/ping` 回退；当前默认运行有限次数，持续通知、声音和图表仍属于后续增强项。 |
| Traceroute | System replacement | 调用 macOS `traceroute`；依赖系统命令和网络权限。 |
| DNS Lookup | Native | UDP DNS、TCP fallback、常见记录解析和自定义服务器。 |
| Remote Desktop | Optional dependency | 通过 `rdp://` 交给已安装的 Microsoft Remote Desktop 或其他注册客户端；不再嵌入 Windows ActiveX。 |
| PowerShell | System replacement | 使用 `/bin/sh` 和 Terminal.app；PowerShell、WSL、k9s 可由用户安装后在终端中运行。 |
| PuTTY | Native SSH + system replacement | SSH 在应用内 SwiftTerm 标签中运行系统 OpenSSH，保留严格主机密钥确认；含只读命令模板与需要显式确认的自定义命令。Telnet 交给 Terminal.app；Serial、RAW、Rlogin 和 PuTTY 专用参数需第三方客户端。 |
| TigerVNC | Optional dependency | 通过 `vnc://` 交给 VNC 客户端；高级压缩和认证参数由客户端负责。 |
| Web Console | System replacement | Web 端点使用系统默认浏览器，诊断命令使用显式触发的 `/bin/sh`；没有 Windows WebView2 嵌入控件。 |
| SNMP | Native | v1/v2c 支持 GET、WALK、SET；SNMPv3 USM 支持 SHA-1/SHA-256 的 authNoPriv/authPriv GET、WALK，authPriv 使用 AES-128-CFB。凭据可从 Keychain 选择，也可仅在当前会话输入。尚无真实设备多厂商互操作验证；不支持 v3 SET、TLS 和完整 MIB 浏览器。 |
| SNTP Lookup | Native | 原生 UDP NTP 查询，显示偏移、延迟、层级和服务器时间。 |
| Hosts File Editor | Native + authorization | 编辑 `/etc/hosts`，保存时调用 macOS 管理员授权；复杂注释/条目级 CRUD 仍保留为文本编辑。 |
| Firewall | Partial system replacement | 读取 `socketfilterfw` 全局状态和应用列表；规则编辑需 macOS 私有/系统管理接口，当前不伪造 Windows 规则 CRUD。 |
| Discovery Protocol | Optional dependency | 优先调用 Homebrew `lldpcli`；未安装时明确提示；CDP 的完整解析取决于交换机和 lldpd 支持。 |
| Wake on LAN | Native | BSD UDP 广播 magic packet，支持自定义广播地址和端口。 |
| Whois | Native | TCP WHOIS 查询与服务器选择。 |
| IP Geolocation | Native + network service | 通过用户主动触发的 HTTPS `ipwho.is` 查询；地理信息依赖第三方服务及网络。 |
| Subnet Calculator | Native | IPv4 子网、拆分、主机范围和地址类别计算。 |
| Bit Calculator | Native | 二进制、十六进制、十进制和位宽计算。 |
| Lookup | Native | 复用原项目 OUI、端口和 WHOIS XML 数据。 |
| Connections | Native + system replacement | `lsof -n -P -i` 结构化解析进程、协议、本地/远端端点和状态。 |
| Listeners | Native + system replacement | 从 `lsof` 结构化筛选 LISTEN socket。 |
| Neighbor Table | Native + system replacement | `arp -an` 结构化解析地址、MAC、接口和状态。 |
| Profiles | Native | Application Support JSON、分组、Windows JSON/XML 导入转换和 AES-GCM 加密导出；新导出使用带随机 salt 与 120,000 次 PBKDF2-HMAC-SHA256 的 macOS `NME2` 容器，旧 `NME1` 仍可导入，与 Windows 加密容器不保证二进制兼容。 |
| MCP 客户端集成 | Native CLI | 可选 `NMCP` 使用官方 Swift SDK 0.12.1，通过 stdio 提供接口枚举、IPv4 子网、端口及 OUI 查询；`--allow-network` 额外启用单目标 Ping、DNS 和 TCP。另提供两项静态资源；不开放资产/配置写入、Keychain、SSH 或任意 shell。详见 [MCP.md](MCP.md)。 |

## MCP 实现范围（2026-11-07）

MCP 是客户端按需启动的独立命令行产品，GUI 无需运行，也不安装 daemon、
helper 或 HTTP 服务。默认四项本地工具，网络诊断必须通过进程参数
`--allow-network` 启用。参数校验、最多四个并发网络诊断、各阶段
`0.1...5` 秒超时和取消逻辑用于限制单次诊断；总请求时长可能包含多个阶段。
结果通过文本 JSON 和等价 `structuredContent` 返回，不写入应用诊断历史。
共享本地化会读取应用语言偏好，可能创建 Application Support 目录，但不为
MCP 调用保存诊断或修改配置；可用绝对路径环境变量
`NETWORKMANAGER_SUPPORT_DIRECTORY` 隔离验证目录。
设置初始化错误改为在初始化完成后按需本地化，避免损坏设置触发
`SettingsStore.shared` 与 `Loc.shared` 的递归初始化。
同步 DNS、TCP、SNTP、SNMP 及原生 ICMP 等待改由后台 Dispatch 队列执行，
避免少量 Swift cooperative 工作线程被占满后，后续请求与取消无法及时运行。
CI 为 MCP 集成套件设置 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`，覆盖受限
工作线程下的并发、取消及 EOF 退出。

包的构建工具链要求 Swift 6.2+，最低运行目标仍为 macOS 14。stdio 集成脚本
`Scripts/test-mcp.py` 使用本机 loopback TCP/DNS fixture 检查协议交互，验证
命令及客户端配置见 [MCP 使用指南](MCP.md)。启动脚本优先直接执行已有
Debug/Release 产物；更新源码后需显式重建，首次缺少二进制时的自动构建可能
超过客户端握手超时。

2026-11-07 本机（arm64、Swift 6.4.2）Debug/Release `NMCP` 构建及真实
stdio 集成套件通过，包含七项工具、资源、参数错误、loopback ICMP/TCP/DNS、
超时、取消、并发限制、在途请求 EOF、损坏 `settings.json` 原字节保留与
无新增应用 JSON 的独立进程回归。预编译产物经启动脚本在四秒预算内完成
握手、工具调用和 EOF 退出；存在其他 SwiftPM 构建时也验证通过。
`NMTest`、`NMCheck` 与 GUI Debug 构建复验通过。这些是本机验证结果，
不代表其他 macOS/CPU 或远端 CI 已通过。下方 2026-11-06 的历史记录不包含 MCP。

## 依赖与打包

局域网发现、网关探测和本机邻居读取受 macOS 本地网络隐私控制；`Info.plist`
包含 `NSLocalNetworkUsageDescription`。打包脚本默认 ad-hoc 签名，不能代替
Apple Developer 签名身份；发布签名与公证需由发布者通过 `CODESIGN_IDENTITY`
及 Apple Developer 流程完成。应用本身不捆绑 RDP、VNC、lldpd 或 PowerShell。这样可以保持 `.app` 和 DMG
可分发，并让用户选择符合组织策略的客户端。打包脚本会复制 SwiftPM 资源包，
支持 arm64 和 x86_64。

## 本机验证状态（2026-11-06）

最终 Universal 包 GUI 复核中，隔离 HOME 缺失凭据索引时显示恢复提示，新增/导出禁用且恢复入口可用；默认用户支持目录索引为空。钥匙串访问按应用 service 前缀筛选登录与 iCloud 钥匙串均无匹配项，因此当前没有可从应用列表选择的测试引用。隔离 GUI 进程与临时 HOME 已关闭并清理；`/tmp` 常见 SSH 私钥文件名及 loopback fixture 名称检查未发现文件。

本轮修复诊断证据导出对 JSON 字段、Basic Authorization、Cookie 与 URL userinfo 漏脱敏的问题；新增负向测试覆盖这些格式。Debug/Release `NMTest`、Release `NMCheck`、Universal 构建和 DMG 生命周期通过；隔离 HOME 中使用虚构 canary 的 GUI JSON 导出实测未泄漏任何 canary，测试目录已清理。

| 阶段 | 当前状态 | 本地证据与未满足项 |
| --- | --- | --- |
| P0 产品与权限基线 | 部分完成 | SwiftUI 工作台、系统托管主应用登录项和无专属 daemon/helper 的进程模型已实现；SwiftTerm 1.11.2 MIT 许可证已审查并随包分发；macOS 14/15+ 完整权限回归未完成。 |
| P1 资产上下文底座 | 本机核心与主要 GUI 路径通过 | 资产/诊断恢复、备份导入、Keychain CRUD 与设备凭据引用跨 store 重载有 NMTest 覆盖；损坏资产、设置、配置文件和凭据元数据会保留原件并提示恢复。凭据引用支持不含秘密的备份导出；恢复会验证原 Keychain 项仍可访问，缺失索引标记也会阻止误显示为空库。最终包 GUI 验证设备详情 Ping/DNS/TCP/Traceroute/SNMP 五个入口、全局历史重跑、工作区/站点/设备表单及子网 CIDR 错误/成功状态；站点级联删除预览明确列出设备与历史影响，已取消未执行。 |
| P2 可观测性连接 | 本地核心、HTTP fixture 与 NetBox 导入确认 GUI 通过，现场互操作未验证 | NetBox 覆盖 v1/v2 token 头、只读分页、重定向与跨源分页拦截、缺凭据、错误脱敏、资产字段映射、未命名设备和安全策略；同步结果先显示可选候选，重复项及无主 IP 设备不可选，显式确认后才调用本地资产合并；URL/凭据变化清除旧预览。新增 Zabbix 活动问题只读 JSON-RPC、Bearer token、trigger/host/interface 映射、HTTPS/loopback 限制及跨源重定向阻断；SNMPv3 标准向量与错误路径通过。真实 NetBox/Zabbix API 和多品牌 SNMP 设备尚未验证。 |
| P3 排障与证据链 | 本地核心、fixture 与缺凭据 GUI 通过，真实告警互操作未验证 | DNS 等待 UDP 响应时的父任务取消、DNS-SD 主机地址解析的取消/超时资源释放、`localhost` 解析后的真实 TCP loopback connect、已取消父任务启动 TCP 诊断时保留取消状态、异常退出恢复和脱敏导出有本地测试；资产诊断及独立 DNS/WHOIS/SNTP 查询写入同一可筛选历史，旧版无设备关联记录可兼容解码。独立 WHOIS/SNTP 现将取消贯通到底层 TCP/UDP I/O；loopback fixture 验证成功响应与取消，独立查询 GUI 的取消按钮和历史回写已实测。Zabbix 告警可对唯一映射的本地设备运行 Ping，事件 ID、来源、目标、状态与结果写入统一历史；逐主机反馈运行状态、结果摘要/延迟并可按事件打开历史，重复点击受拦截，重复 IP 不强行关联。2026-11-05 最终 GUI 已验证 DNS 成功、WHOIS 失败和 SNTP 超时均回写正确目标、状态及来源；Zabbix GUI 已验证无凭据状态与刷新禁用。真实监控平台闭环和跨 macOS 版本的解析器权限行为仍未测。 |
| P4 远程会话与受控操作 | 本机 SSH GUI 操作链通过，真实设备未验证 | loopback OpenSSH fixture 上通过严格主机密钥确认、Keychain 身份引用、公钥认证、shell 提示符、经确认发送 `whoami`、回显和脱敏操作记录；设备差异与实际写操作仍未验证。 |
| P5 稳定与正式分发 | 本地 Universal 构建与临时安装生命周期通过，正式发布未完成 | 最新 Universal `.app`/DMG 的架构、签名结构、plist、镜像校验及临时安装/替换安装/启动/卸载通过；ad-hoc 签名被 `spctl` 拒绝，当前 Keychain 中没有可用 Developer ID 身份。Developer ID、公证、Gatekeeper 首次运行及真实旧版本升级迁移未验证（现有归档 DMG 均为 2026.7.7.0）；当前本机 macOS 27.2 不替代最低支持 macOS 14 的实机测试。 |

- 2026-11-06 发布就绪复核：Release `NMTest`、Release `NMCheck` 和 workflow YAML 语法验证通过；从当前源码重建 Universal app/DMG，`lipo` 确认 `arm64`/`x86_64`，签名结构与 `Info.plist` 验证通过，`hdiutil verify` 和临时安装/启动/替换升级/卸载生命周期通过。该包为 ad-hoc 签名，`spctl` 明确拒绝；本机没有有效 Developer ID identity 或 `NETworkManagerRelease` Notary profile，因此正式签名、公证和 Gatekeeper 放行未完成。当前本地候选 DMG：`dist/macos-delivery-2026-11-06-local-adhoc/NETworkManager-macOS-2026.7.7.0-universal.dmg`；SHA-256：`442f869c8d1f97057699e3aa37e8a2e2693830cb518c880e87fe3c62bdfed442`。GitHub Actions 现对普通工作流仅授予 `contents: read`，正式发布 job 单独提权为 `contents: write`；`script/**` 与 `Images/**` 改动也会触发构建。当前目录没有 Git 提交历史或 remote，无法从此目录推送或创建 GitHub Release。真实 NetBox/Zabbix 与多厂商 SNMP 互操作、最低支持 macOS 14 实机回归仍未完成。 |

- 2026-11-05 补充统一运行历史：独立 DNS、WHOIS、SNTP 查询现在写入 `DiagnosticRun`，目标、参数、时间、结果、来源和错误分类可在诊断历史筛选及脱敏导出；独立记录不虚构设备/工作区关联，已有旧格式资产数据继续解码，删除资产不会误删独立历史。独立查询页复用共享 `DiagnosticService`，使 UI 错误状态与资产诊断一致，同时保留 DNS 表格、查询耗时和 WHOIS 原始响应展示，SNTP 超时使用协议专属错误说明；`NMTest` 覆盖独立记录持久化、旧格式解码、资产范围隔离、证据目标和级联删除保留。2026-11-05 最终 GUI 验证 DNS `localhost` 返回 `127.0.0.1` 并写入成功历史；WHOIS 指向本机关闭端口时写入失败记录，SNTP `localhost` 无服务时写入超时记录。
- 2026-11-05 补齐独立 WHOIS/SNTP 的运行中取消：取消信号贯通 DNS-SD 解析、TCP connect/write/read 与 SNTP UDP 等待；独立查询页提供取消按钮，并在离开页面时取消任务。loopback fixture 覆盖 WHOIS CRLF 请求/成功响应、WHOIS 挂起读取取消、SNTP UDP 成功响应及无响应取消。Universal GUI 实测 WHOIS 本地解析等待期间显示取消按钮，点击后立即结束，统一历史保存为 `WHOIS · 已取消`；本地查询结果均为 fixture/缺路由态，未连接真实 WHOIS 服务器。
- 2026-11-05 增补持久化损坏恢复：设置、资产、配置文件三类存储在无法读取/解码时保留原件并进入可见恢复状态；普通编辑不覆盖损坏文件。资产备份或配置导入恢复时先保存带时间戳的 `.corrupt-*` 副本；设置仅在 GUI 确认重置后备份原件并恢复默认值，命令行 `--reset-settings` 遇到损坏文件会延后并提示用户。`NMTest` 覆盖损坏数据不覆盖、无效导入拒绝、有效恢复及设置命令行延后。
- 资产与配置文件存储在 JSON 无法读取或解码失败时，不再静默启动空库并覆盖原文件；工作区显示恢复提示，禁用会造成误导的新增/导出操作。有效资产备份或配置文件导入写入前会将损坏原件保留为带时间戳的 `.corrupt-*` 文件；无效导入不改变现有状态。`NMTest` 覆盖损坏文件保留、无效恢复拒绝、有效恢复及配置文件 JSON 导入恢复。GUI 主资产工作流已实测，恢复横幅路径由同一 SwiftUI 状态驱动，尚未在真实用户数据目录制造损坏文件做破坏性 UI 演练。
- SNMPv3 离线检查覆盖 RFC 3414 SHA-1 password-to-key 向量、RFC 7860 HMAC-SHA-256 向量、AES-128-CFB 往返、engine boots/time 同步、超时、未知用户和错误认证报告。离线协议检查不代表已验证具体厂商设备。
- SNMPv3 页面提供 GET/WALK、认证算法、安全级别及 Keychain SNMP 凭据选择；SNMPv1/v2c 保留 GET/WALK/SET。真实 SNMP 设备不可用时，网络互操作仍标为未验证。
- 最终 Universal 包的资产详情 GUI 实测：Ping 到本机网关成功；DNS 到 `127.0.0.1` 返回 1 条记录；TCP 22 显示端口关闭；Traceroute 到本机成功；无本地 SNMP 服务时显示代理超时，状态区分正确。全局诊断历史中的重跑动作打开目标设备详情并再次执行 Ping，结果写入设备诊断历史。
- 本轮发现并修复 DNS 成功响应后的崩溃：诊断摘要曾用 `%@` 格式化整数记录数，导致 CoreFoundation 字符串格式化崩溃，现改为 `%d`。loopback UDP DNS fixture 覆盖成功响应格式化及答案解析，并另覆盖等待响应期间的父任务取消。
- NetBox 本机 Network.framework HTTP fixture 已验证：v1 `Token` 与 v2 `Bearer nbt_…` 头、只读 GET、分页、分页循环与上限、跨源重定向/分页阻断、无 token 不发请求、错误响应 token 脱敏、角色/状态/厂商及 IPv4/IPv6 地址映射、未命名设备回退标签和无地址设备过滤；UI 已实测缺少 Keychain token 时按钮禁用，以及非回环 HTTP 的 HTTPS 警告。2026-11-05 修复 v2 分页请求丢失 `Bearer` scheme 的问题，双页 fixture 断言每页均沿用 `Bearer` 头。本机未配置真实 NetBox endpoint 或 token，因此生产 API 连接、权限范围和同步结果仍未验证。
- 2026-11-05 新增只读 Zabbix 告警纵向切片：`problem.get` 只查询 trigger 类活动问题，随后以 `trigger.get` 与 `host.get` 读取关联主机和主接口；API token 从 Keychain 临时读取，连接配置只持久化 URL 与引用。HTTPS 为网络连接要求，HTTP 只允许 loopback fixture；同源重定向受限，JSON-RPC/HTTP 错误截断并脱敏。fixture 覆盖 Bearer 头、字符串型 API ID/数值、严重级别/确认状态、主接口目标优先、空队列、缺 token 不发请求、JSON-RPC 错误脱敏及跨源重定向阻断。从告警启动的 Ping 会把事件/触发器 ID、目标、来源和诊断结果写入统一历史；目标唯一匹配本地资产时关联设备，地址重复时保持独立证据。最终 GUI 确认无 Keychain token 时刷新按钮禁用并显示明确提示；实际输入外部 HTTP 地址会立即在状态行提示 HTTPS/loopback 策略，改回 HTTPS 后提示清除。没有真实 Zabbix endpoint/token，本地 fixture 不代表现场 API 互操作通过。
- 2026-11-05 本地 Universal DMG 位于 `dist/macos-delivery-2026-11-05-zabbix-ping-final/NETworkManager-macOS-2026.7.7.0-universal.dmg`，SHA-256：`32bfa1c1fa297fe1a933f3123715c5483fe80e6a605894b1e61a9e4fe1ff6359`。最终源码的 Debug/Release `NMTest`、Debug/Release `NMCheck` 与 Universal Release GUI 构建均通过；包架构、`codesign --verify --deep --strict`、Info.plist、`hdiutil verify` 和 DMG 临时安装/替换安装/启动/卸载生命周期验证均通过。当前本机为 macOS 27.2（build 26B123）；SwiftPM 仍有缺失 framework 搜索路径 warning。签名为 ad-hoc，`TeamIdentifier` 未设置且无 Hardened Runtime 标志；本机没有可用 Developer ID 身份，`release-dmg.sh --dry-run` 确认缺少 `CODESIGN_IDENTITY` 与 `NOTARY_PROFILE`，未执行真实发布步骤。ad-hoc 包不能通过 Gatekeeper 正式分发；Developer ID、公证、staple、Gatekeeper 首次运行、最低支持 macOS 实机回归和真实旧版本升级迁移仍未验证。
- 2026-11-05 补强凭据元数据恢复：`credentials.json` 损坏时保留原件并冻结新增、编辑和删除；旁路初始化标记检测到索引文件缺失时同样进入恢复态，避免 Keychain 秘密仍存在却误显示空凭据库。凭据页可导出只含引用/标签/账户元数据的 JSON 备份，并在恢复前验证每个引用仍能读取本机 Keychain 项；无效备份不覆盖原文件，有效恢复会先保留损坏原件副本。存储层也拒绝空标签，避免写出随后无法解码的引用。`NMTest` 覆盖损坏与缺失两种状态、修改拦截、无效备份、恢复、Keychain 读回和备份中无秘密；隔离 GUI 已验证损坏/缺失提示、添加/导出禁用与恢复文件选择器。该构建的 DMG checksum、生命周期和签名结构复核通过。
- 2026-11-05 本轮源码翻译更新后的 DMG 已再次重建并实测：GUI WHOIS 超时提示显示 `WHOIS 服务器未在规定时间内响应。`；运行中的查询显示取消按钮，点击后状态区与诊断历史均记录为 `WHOIS · 已取消`。检查凭据页显示“没有凭据”，此前确认的 `Temporary loopback SSH fixture` Keychain 引用已不存在。GUI 取消使用文档保留网段 `203.0.113.1`，未连接真实 WHOIS 服务；本地 `127.0.0.1:43` 监听因系统权限被拒绝，未启动监听器。该次 DMG 架构、签名结构、plist、镜像校验和安装生命周期复核均通过；该 DMG SHA-256 为 `1ed17a37df57deff2a2287e636113b05cef96238712af4cf9f286a6f2d854db4`。
- 2026-11-05 最终打包 GUI 资产验收：工作区、站点新增表单及站点编辑表单可打开，设备表单显示站点/子网/类型/凭据引用字段；类型菜单可选 Workstation、Server、Router、Switch、Firewall、Access point 和 Other。当前资产数据只有 `This Mac` 站点且没有子网；Keychain 凭据页显示“没有凭据”，因此设备子网与凭据引用控件禁用是当前数据状态，未创建测试数据。站点删除确认明确说明将同时移除 2 台设备及其诊断历史，本次已取消；现有资产未改变。最新 CIDR 修复版 GUI 输入 `not::ipv6/64` 后显示 IPv4/IPv6 CIDR 错误并禁用保存；输入有效 `2001:db8::1234/64` 后错误清除、保存启用，随后取消表单，没有持久化测试资产。SSH fixture 的临时凭据已清理；本次在最新 `netboxfix` 包中再次确认 Keychain 列表为空，没有残留凭据可删除。NetBox 页面显示“连接前请先在‘凭据’中添加 API 令牌”，凭据选择器、测试连接和只读同步按钮均禁用。
- 2026-11-05 修复资产子网 CIDR 校验：IPv4/IPv6 解析拒绝空前缀、额外斜杠和无效前缀；IPv6 使用系统 `inet_pton` 验证地址，并按前缀位清除主机位、通过 `inet_ntop` 规范化网络地址。`NMTest` 覆盖 IPv4/IPv6 规范化、非法 IPv6 文本、空前缀及多余组件；Debug/Release `NMTest`、Debug/Release `NMCheck` 与 Release GUI 构建均通过。Universal 包及 DMG 已从此源码重建，生命周期和 GUI 表单状态均已复测。
- 应用使用系统托管的可选主应用登录项，不安装项目专用 daemon/helper。Universal 包中仅有主可执行文件与 SwiftPM 资源包，没有 XPC、应用扩展、LaunchAgent 或 LaunchDaemon；本机也未发现历史 `com.networkmanager.mac.launcher` plist。`script/build_and_run.sh` 现在只按 `dist/macos/NETworkManager.app` 的实际可执行文件路径结束和检测进程；本轮结束时只保留当前工作台实例，旧 SSH fixture GUI 实例经路径确认后已关闭。GUI 检查不能替代最低支持 macOS 与其他 macOS 版本的回归。
- SSH 操作面板提供精确匹配的 Cisco IOS 只读命令模板；非模板命令会显示目标和完整命令并要求确认。发送前还需操作者确认已经接受主机密钥且远端提示符已就绪，避免把命令误送到首次连接或密码提示中。本轮 GUI 使用 loopback OpenSSH fixture 验证了首次主机密钥提示和严格接受流程、临时 Keychain 身份引用、公钥认证、提示符门控、经确认的 `whoami` 命令回显及不含命令正文/输出的审计记录。首次连接在主机密钥写入后于认证前超时；服务端记录 `Timeout before authentication`，已知主机重试后认证和 GUI 操作成功，未修改 SSH 实现代码。测试后已从应用删除临时 Keychain 引用，并移除临时密钥、sshd fixture 与本轮新增的 known_hosts 状态。离线策略和存储测试通过；真实网络设备、Cisco 命令兼容性、设备差异和实际写操作仍未验证。
- 本地 `operations-audit.json` 记录 SSH 会话启动/关闭以及通过应用发送的只读或已确认命令类别、目标和时间；不保存命令正文、终端输出或秘密。用户直接在终端输入的命令不在审计覆盖范围内。主机密钥交互和命令回显已在 loopback SSH fixture 的 GUI 测试中验证；真实 SSH 设备上的设备差异、Cisco 命令兼容性及实际写操作仍未验证。
- 本轮为 TCP、ICMP、DNS 自定义服务器、SNMP v1/v2c/v3、SNTP 与 WHOIS 引入共享 DNS-SD 地址解析；数字地址保持本地数值解析。`NMTest` 覆盖 resolver 等待取消/超时后的请求释放、真实 `localhost` 地址和 sockaddr 长度，以及经解析地址连接 loopback TCP listener；此前 DNS fixture、NetBox fixture、SNMPv3 向量与凭据恢复检查也通过。GUI 实测 DNS 页查询 `localhost` 得到 `127.0.0.1`，资产详情操作入口与历史可见，NetBox 无凭据时测试/同步按钮禁用。新 `macos/Scripts/verify-dmg-lifecycle.sh` 在 arm64 和最新 Universal DMG 上通过挂载、临时安装、启动、替换安装、再次启动与卸载；`.github/workflows/macos.yml` 已加入 macOS 15/26 测试矩阵、NMTest/NMCheck、GUI 启动冒烟、ad-hoc DMG 生成与校验及生命周期回归，本轮尚未执行远端 Actions。原 macOS 14 runner 于 2026-11-02 退役，CI 已迁移；应用部署目标仍是 macOS 14。SwiftPM 在仅安装 Command Line Tools 的主机上仍输出缺少 framework 搜索路径的 linker warning。外部告警闭环、真实设备互操作、正式 Developer ID 签名与公证、Gatekeeper 首次运行、最低支持 macOS 实机回归和真实旧版本升级仍未完成。([GitHub Actions runner notice](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/))
- 为使 GUI 测试数据与账户目录分离，`SettingsStore` 支持绝对路径环境变量 `NETWORKMANAGER_SUPPORT_DIRECTORY`，`NMTest` 覆盖路径解析；README 记录该验收入口。macOS 27.2 上从最新 Universal 构建实际启动 GUI，隔离数据目录中的诊断历史显示虚构单引号 token canary；通过应用“导出 JSON”保存后，导出详情为 `{'token': '[REDACTED]'}`，`jq` 验证输出不含原 canary。隔离目录已删除。凭据页显示“没有凭据”；此前确认的 loopback SSH Keychain 引用已删除，本轮没有新增 Keychain 项。
- 2026-11-05 完善 Zabbix 告警 Ping 交互：按 `eventID + hostID` 显示运行中状态并禁用重复点击；完成后呈现成功/失败/超时分类、摘要和延迟，结果来自持久化 `DiagnosticRun`；历史搜索支持事件与触发器 ID，告警行可直接打开按事件筛选的历史。`NMTest` 覆盖成功记录、事件 ID 搜索、确定性超时状态回写及唯一/重复资产地址关联。GUI 使用仅 Debug 可见的 loopback 样例验证 `127.0.0.1` Ping 成功、延迟反馈及事件历史入口；无 Zabbix 凭据时凭据选择器与刷新按钮禁用。真实 Zabbix API 和失败/超时 UI 尚未通过 GUI 验收；本轮没有新增 Keychain 项。最终源码重建的 Universal DMG 位于 `dist/macos-delivery-2026-11-05-zabbix-ping-final/NETworkManager-macOS-2026.7.7.0-universal.dmg`，SHA-256：`32bfa1c1fa297fe1a933f3123715c5483fe80e6a605894b1e61a9e4fe1ff6359`；arm64/x86_64、ad-hoc 签名结构、plist、镜像校验和临时安装/替换安装/启动/卸载生命周期检查通过。Developer ID、公证和 Gatekeeper 首次运行仍未验证。
- 2026-11-05 修复外部资产同步的新鲜度持久化：`AssetDevice.sourceFetchedAt` 单独记录来源抓取时间，保留 `updatedAt` 表示本地资产编辑时间；重复 NetBox 同步刷新来源时间但不覆盖用户字段，乱序旧响应不会回退来源时间，且无需新增设备也会保存更新。详情检查器显示来源与最近同步时间。Debug/Release `NMTest` 验证本地别名及编辑时间保留、来源时间跨存储重载、旧资产 JSON 兼容解码和乱序抓取；Debug/Release `NMCheck` 通过。使用项目 `build_and_run.sh --verify` 重建并启动 GUI，确认资产/历史界面可打开、NetBox 缺凭据时提示明确且测试/同步禁用。Universal 包 arm64/x86_64、签名结构、Info.plist、DMG 校验及安装/替换升级/启动/卸载回归通过。正式公证仍因本机无 Developer ID identity 与 Notary profile 未验证。
- 2026-11-05 扫描风险预检与取消完善：`HostRangeParser.preview` 以紧凑段描述计算目标数及首末地址，不为输入预览展开目标列表；IP Scanner 与 Dashboard 都在发包前显示范围和数量，超过 256 个目标要求确认，IP Scanner 上限 65,536、Dashboard 上限 2,048。IP Scanner 使用最多 32 个并发 ICMP 探测；共享取消信号贯通 ICMP 接收等待、TCP connect 和后续目标派发，停止后不再安排新目标，离开页面也会取消。`NMTest` 覆盖 `/24` 和组合范围边界、无需展开的 `/8` 预览、超限拒绝、已取消 TCP 不发探测及 ICMP 已取消快速返回；Debug `NMTest`、Debug `NMCheck` 与 Debug GUI 构建通过。GUI 在本机 loopback 验证单目标 ICMP 成功、257 目标预览与确认/取消；Ping Monitor 实测停止后记录“已停止：完成 1/10 个目标”；Dashboard 显示本机 `/24` 的 254 个可用主机并正确要求大范围确认。真实 LAN 扫描未执行。
- 2026-11-05 完成扫描变更后的 Release 交付复验：Debug/Release `NMTest` 与 `NMCheck` 全部通过；arm64、x86_64 Universal Release GUI 构建成功，实际打开最新 `.app` 并检查侧栏和 IP Scanner 首屏，扫描目标保持单个 `127.0.0.1` 且未启动。重建 DMG 的 SHA-256 为 `eddbd65846a76a0d41f3540a7bb786ecc6a5c6264e381a22f224058607e6ef83`；`lipo` 确认包含 arm64/x86_64，ad-hoc 签名结构、Info.plist、`hdiutil verify` 均通过，生命周期脚本完成挂载、临时安装、启动、替换安装、再次启动与卸载。签名仍为 ad-hoc；正式 Developer ID、公证、staple、Gatekeeper 首次运行、macOS 14 实机和真实旧版本升级尚未验证。SwiftPM 在当前仅安装 Command Line Tools 的主机上仍报告缺失的 framework/library 搜索路径 warning；测试和构建均成功。
- 2026-11-05 安全扫描封存后修复四项风险：SNMP 诊断结果在进入历史前精确脱敏 community 与 SNMPv3 密码；NetBox/Zabbix 响应体受 8 MiB 上限保护；profile 新导出升级为 `NME2`/PBKDF2-SHA256（120,000 次）且保留 `NME1` 导入兼容；SSH 命令审阅拒绝 Unicode format/bidi 控制字符并在确认文本中转义不可见字符。`NMTest` 覆盖这些回归路径。
- 2026-11-05 独立 SNMP 页面 GET/WALK/SET 现写入统一诊断历史，记录目标、版本、OID、端口及成功/失败/超时/取消状态；varbind 与历史详情使用同一秘密脱敏器。GUI 在本机 `127.0.0.1:161` 无代理时实测运行态、超时提示和历史回写均正确。
- 2026-11-05 文档收尾后重新生成最终交付包：`dist/macos-delivery-2026-11-05-zabbix-ping-final/NETworkManager.app` 与 Universal DMG 保留 `arm64`/`x86_64`，`codesign --verify --deep --strict`、Info.plist、`hdiutil verify` 和 DMG 安装/替换/启动/卸载生命周期均通过。当前 DMG SHA-256 为 `bceff533c8e582bd95957cc359bba62d8ad7f001b4ab0b747348e437c9ad12c2`。旧 `dist/macos/NETworkManager.app`、隔离 GUI 数据、Zabbix fixture、测试日志和 SwiftPM 构建缓存已清理；最终 `.app`/DMG 与源代码保留。正式 Developer ID 签名、公证和 Gatekeeper 仍未验证。

