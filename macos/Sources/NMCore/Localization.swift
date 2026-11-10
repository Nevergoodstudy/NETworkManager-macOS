import Foundation
import SwiftUI

/// Application language selection.
public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case english
    case chineseSimplified

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return Loc.shared.t("System default")
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }

    /// Two letter code, used for `.lproj`-style lookups and `Locale` construction.
    public var code: String {
        switch self {
        case .system: return Loc.systemPrefersChinese ? "zh-Hans" : "en"
        case .english: return "en"
        case .chineseSimplified: return "zh-Hans"
        }
    }
}

/// Centralized localization registry.
///
/// Design notes:
///  * English source strings are used as lookup keys. Missing translations simply
///    fall back to the English text, so the UI never shows raw keys.
///  * Every feature module registers its own table via `register(zh:en:)` at
///    application start-up, which keeps the modules independent of each other.
public final class Loc: ObservableObject {
    public static let shared = Loc()

    private let lock = NSLock()
    private var zhTable: [String: String] = [:]
    private var enTable: [String: String] = [:]

    /// Bumped on every language change so that SwiftUI re-renders observers.
    @Published public private(set) var revision: Int = 0

    @Published public var language: AppLanguage = .system {
        didSet {
            guard language != oldValue else { return }
            revision &+= 1
            SettingsStore.shared.language = language
            objectWillChange.send()
        }
    }

    public init() {
        if let stored = SettingsStore.shared.language {
            language = stored
        }
        registerCoreStrings()
    }

    // MARK: - Registration

    public func register(zh: [String: String], en: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in zh { zhTable[key] = value }
        for (key, value) in en { enTable[key] = value }
        if Thread.isMainThread {
            revision &+= 1
        }
    }

    // MARK: - Queries

    public static var systemPrefersChinese: Bool {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh")
    }

    public var isChinese: Bool {
        switch language {
        case .chineseSimplified: return true
        case .english: return false
        case .system: return Self.systemPrefersChinese
        }
    }

    public var locale: Locale {
        Locale(identifier: isChinese ? "zh_Hans_CN" : "en_US")
    }

    public var resolvedLanguage: AppLanguage {
        isChinese ? .chineseSimplified : .english
    }

    /// Translate an English source string.
    public func t(_ english: String) -> String {
        lock.lock()
        let zh = zhTable[english]
        let en = enTable[english]
        lock.unlock()

        if isChinese {
            if let zh { return zh }
            if let en { return en }
            return english
        }
        return en ?? english
    }

    /// Translate + `String(format:)` style arguments.
    public func tf(_ english: String, _ args: CVarArg...) -> String {
        String(format: t(english), locale: locale, arguments: args)
    }

    // MARK: - Core strings

    private func registerCoreStrings() {
        register(zh: [
            // Generic
            "System default": "跟随系统",
            "English": "English",
            "OK": "确定",
            "Cancel": "取消",
            "Close": "关闭",
            "Save": "保存",
            "Delete": "删除",
            "Remove": "移除",
            "Add": "添加",
            "Edit": "编辑",
            "Copy": "拷贝",
            "Export": "导出",
            "Import": "导入",
            "Start": "开始",
            "Stop": "停止",
            "Clear": "清空",
            "Reload": "重新加载",
            "Refresh": "刷新",
            "Search": "搜索",
            "Filter": "筛选",
            "Reset": "重置",
            "Apply": "应用",
            "Browse": "浏览",
            "Open": "打开",
            "Retry": "重试",
            "Details": "详细信息",
            "Name": "名称",
            "Type": "类型",
            "Status": "状态",
            "Description": "描述",
            "Value": "值",
            "Host": "主机",
            "Hostname": "主机名",
            "Port": "端口",
            "Username (optional)": "用户名（可选）",
            "Connect": "连接",
            "Remote": "远程访问",
            "Connection": "连接",
            "SSH host keys are verified by OpenSSH. First connections prompt in the terminal; changed keys are rejected.": "SSH 主机密钥由 OpenSSH 验证。首次连接会在终端中提示确认；密钥变更时连接将被拒绝。",
            "SSH sessions run in this window. RDP and VNC open compatible installed clients; web protocols use the default browser.": "SSH 会话在此窗口中运行。RDP 和 VNC 将打开已安装的兼容客户端；Web 协议使用默认浏览器。",
            "Enter a valid host or IP address": "请输入有效的主机名或 IP 地址",
            "Enter a valid host and port": "请输入有效的主机名和端口",
            "Close SSH session": "关闭 SSH 会话",
            "SSH terminal opened for %@": "已打开到 %@ 的 SSH 终端",
            "SSH exited with code %@": "SSH 已退出，代码 %@",
            "SSH session opened": "SSH 会话已打开",
            "Read-only command submitted": "已发送只读命令",
            "Confirmed command submitted": "已发送确认的命令",
            "SSH session closed": "SSH 会话已关闭",
            "SSH operations": "SSH 操作",
            "Remote prompt is ready": "远端命令提示符已就绪",
            "Read-only template": "只读模板",
            "Show version": "查看版本",
            "Interface summary": "接口摘要",
            "Interface status": "接口状态",
            "LLDP neighbors": "LLDP 邻居",
            "Command": "命令",
            "Only exact built-in templates are treated as read-only. Other commands require review and confirmation.": "只有完全匹配的内置模板会被视为只读。其他命令必须先检查并确认。",
            "Send": "发送",
            "Review & send": "检查并发送",
            "Confirm SSH operation": "确认 SSH 操作",
            "Send command": "发送命令",
            "Target: %@\nCommand:\n%@": "目标：%@\n命令：\n%@",
            "I have accepted the host key and can see the device prompt.": "我已接受主机密钥，并确认当前显示设备命令提示符。",
            "Enter a command to send.": "请输入要发送的命令。",
            "Commands must be 512 characters or fewer.": "命令长度不能超过 512 个字符。",
            "Commands cannot contain line breaks or control characters.": "命令不能包含换行符或控制字符。",
            "Command submitted to the active SSH session": "命令已发送到当前 SSH 会话",
            "Operation history": "操作记录",
            "No operations recorded": "暂无操作记录",
            "The audit log stores target, time, and action category. It does not store command text or output; direct terminal input is not recorded.": "审计日志仅保存目标、时间和操作类别，不保存命令内容或输出；直接在终端输入的命令不会记录。",
            "Protocol": "协议",
            "Address": "地址",
            "Results": "结果",
            "Settings": "设置",
            "Profiles": "配置文件",
            "Profile recovery required": "需要恢复配置文件",
            "Import profiles to recover": "导入配置文件以恢复",
            "Profile data is damaged or from an unsupported format. The original file was preserved. Import a valid profile export to recover this library.": "配置文件数据已损坏或格式不受支持。原文件已保留。请导入有效配置文件以恢复此库。",
            "Profile library could not be saved: %@": "无法保存配置文件库：%@",
            "Profile import failed: %@": "导入配置文件失败：%@",
            "Profile": "配置文件",
            "General": "常规",
            "Appearance": "外观",
            "Language": "语言",
            "Network": "网络",
            "About": "关于",
            "This build does not include MCP. Install a current NETworkManager app.": "此构建不包含 MCP。请安装新版 NETworkManager 应用。",
            "Move NETworkManager to Applications and open it there before connecting MCP.": "请先将 NETworkManager 移到“应用程序”并从那里打开，再连接 MCP。",
            "MCP included and ready": "已内置 MCP，可直接连接",
            "Updating Codex connection…": "正在更新 Codex 连接…",
            "Choose your Codex app to connect without using Terminal.": "请选择 Codex 应用即可连接，无需使用终端。",
            "Configured. Open a new Codex chat to use networkmanager.": "连接已配置。请新建 Codex 聊天以使用 networkmanager。",
            "Update the existing networkmanager connection to use this app and these options.": "请更新已有的 networkmanager 连接，以使用当前应用和所选选项。",
            "Connect once. Codex will start MCP automatically when needed, even after this app closes.": "连接一次后，Codex 会按需自动启动 MCP；关闭本应用后仍可使用。",
            "Codex did not confirm the MCP connection. Try Refresh.": "尚未确认 Codex 的 MCP 连接，请点击“刷新”重试。",
            "Codex did not confirm removal of the MCP connection. Try Refresh.": "尚未确认 Codex 已移除 MCP 连接，请点击“刷新”重试。",
            "The selected app does not contain Codex. Choose the Codex app or its executable.": "所选应用不包含 Codex。请选择 Codex 应用或其可执行文件。",
            "Could not read Codex MCP settings. Choose a current Codex app and try again.": "无法读取 Codex 的 MCP 设置。请选择新版 Codex 应用后重试。",
            "Codex did not respond in time. Try again or choose a current Codex app.": "Codex 响应超时，请重试或选择新版 Codex 应用。",
            "Codex connection failed: %@": "Codex 连接失败：%@",
            "Use network tools from Codex with natural language. No Terminal commands or API key are needed.": "在 Codex 中通过自然语言使用网络工具，无需终端命令或 API key。",
            "Include Ping, DNS, and TCP diagnostics": "启用 Ping、DNS 和 TCP 诊断",
            "Update Codex connection": "更新 Codex 连接",
            "Connect Codex": "连接 Codex",
            "Disconnect Codex": "断开 Codex 连接",
            "Choose Codex…": "选择 Codex…",
            "Choose the Codex app or its executable. No command or path needs to be typed.": "请选择 Codex 应用或其可执行文件，无需输入命令或路径。",
            "Version": "版本",
            "Nothing to show": "暂无内容",
            "No results": "无结果",
            "Loading…": "加载中…",
            "Ready": "就绪",
            "Running…": "运行中…",
            "Completed": "已完成",
            "Stopped": "已停止",
            "Failed": "失败",
            "Enabled": "已启用",
            "Disabled": "已禁用",
            "Unknown": "未知",
            "Enter a host or IP address": "请输入主机名或 IP 地址",
            "Invalid input": "输入无效",
            "This feature requires macOS 14 or later.": "此功能需要 macOS 14 或更高版本。",
            "Diagnostics": "诊断",
            "Confirm": "确认",
            "Yes": "是",
            "No": "否",
            "Second(s)": "秒",
            "Millisecond(s)": "毫秒",
            "Byte(s)": "字节",
            "Copied to clipboard": "已拷贝到剪贴板",
            "Timestamp": "时间",
            "Message": "消息",
            "Total": "总计",
            "Count": "数量",
            "Success": "成功",
            "Error": "错误",
            "Warning": "警告",
            "Information": "信息",

            // Navigation / tool names
            "Dashboard": "仪表板",
            "Zabbix problems": "Zabbix 告警",
            "Read active monitoring problems and launch a diagnostic against a host interface.": "读取活动监控告警，并对关联主机接口发起诊断。",
            "Zabbix base URL": "Zabbix 基础 URL",
            "Refresh problems": "刷新告警",
            "Read-only · problems and host interfaces": "只读 · 查询问题及主机接口",
            "Severity": "严重性",
            "Problem": "问题",
            "Host / target": "主机 / 目标",
            "Operational data": "运行数据",
            "Acknowledged": "已确认",
            "No problem data": "暂无告警数据",
            "Connect to Zabbix to load active problems.": "连接 Zabbix 以加载活动告警。",
            "No active problems": "没有活动告警",
            "Zabbix returned no active problems.": "Zabbix 未返回活动告警。",
            "Active problems · updated %@": "活动告警 · 更新于 %@",
            "Not classified": "未分类",
            "Average": "一般",
            "High": "高",
            "Disaster": "灾难",
            "Event %@ · %@": "事件 %@ · %@",
            "No interface address": "没有接口地址",
            "No linked host": "没有关联主机",
            "Ping host and save evidence": "Ping 主机并保存证据",
            "Loading Zabbix problems…": "正在加载 Zabbix 告警…",
            "Zabbix problem queue ready": "Zabbix 告警队列已就绪",
            "%d active problem(s)": "%d 个活动告警",
            "Enter an HTTPS Zabbix URL. HTTP is limited to loopback testing.": "请输入 HTTPS Zabbix URL。HTTP 仅限本机回环测试。",
            "Zabbix request failed": "Zabbix 请求失败",
            "Network Interface": "网络接口",
            "WiFi": "WiFi",
            "IP Scanner": "IP 扫描器",
            "Port Scanner": "端口扫描器",
            "Ping Monitor": "Ping 监视器",
            "Traceroute": "路由追踪",
            "DNS Lookup": "DNS 查询",
            "SNTP Lookup": "SNTP 查询",
            "SNMP": "SNMP",
            "WHOIS": "WHOIS",
            "IP Geolocation": "IP 地理位置",
            "IP address or hostname": "IP 地址或主机名",
            "The address is sent to the selected public geolocation service only when you start a lookup.": "只有在开始查询后，地址才会发送到所选的公共地理位置服务。",
            "Country code": "国家代码",
            "Coordinates": "坐标",
            "Timezone": "时区",
            "ISP": "ISP",
            "Organization": "组织",
            "Operation": "操作",
            "Agent": "代理",
            "Community": "团体字符串",
            "Username": "用户名",
            "Authentication": "认证算法",
            "Security level": "安全级别",
            "Authentication password": "认证口令",
            "Privacy password": "隐私口令",
            "Authentication password or community": "认证口令或团体字符串",
            "Privacy password (SNMPv3 authPriv, optional)": "隐私口令（SNMPv3 authPriv，可选）",
            "OID": "OID",
            "Response in %@": "%@ 后收到响应",
            "Completed: %d result(s)": "已完成：%d 个结果",
            "Native SNMP v1/v2c uses UDP sockets. Credentials are sent as the configured community string.": "原生 SNMP v1/v2c 使用 UDP 套接字，并以配置的团体字符串发送凭据。",
            "Enter a valid numeric OID, for example 1.3.6.1.2.1.1.1.0.": "请输入有效的数字 OID，例如 1.3.6.1.2.1.1.1.0。",
            "The SNMP agent did not answer in time.": "SNMP 代理在超时前没有响应。",
            "Unexpected SNMP request ID.": "SNMP 响应中的请求 ID 与当前请求不匹配。",
            "SNMP agent error %d at index %d.": "SNMP 代理返回错误 %d，位置索引为 %d。",
            "Unexpected end of SNMP response.": "SNMP 响应意外结束。",
            "SNMPv3 supports authenticated GET and WALK with SHA-1 or SHA-256; authPriv uses AES-128-CFB. Device interoperability still requires field testing.": "SNMPv3 支持使用 SHA-1 或 SHA-256 认证的 GET 和 WALK；authPriv 使用 AES-128-CFB。设备互操作性仍需现场测试。",
            "SNMPv3 username must contain 1 to 32 UTF-8 octets.": "SNMPv3 用户名必须为 1 到 32 个 UTF-8 字节。",
            "Authentication password must contain at least 8 octets.": "认证口令至少需要 8 个字节。",
            "Privacy password must contain at least 8 octets for authPriv.": "authPriv 隐私口令至少需要 8 个字节。",
            "The SNMPv3 authoritative engine ID is invalid.": "SNMPv3 权威引擎 ID 无效。",
            "The SNMPv3 agent did not answer before the timeout.": "SNMPv3 代理在超时前没有响应。",
            "SNMPv3 authentication failed. Check the username and authentication password.": "SNMPv3 认证失败。请检查用户名和认证口令。",
            "The SNMPv3 agent does not recognize this user.": "SNMPv3 代理不识别此用户。",
            "The SNMPv3 agent could not decrypt the request. Check the privacy password and protocol.": "SNMPv3 代理无法解密请求。请检查隐私口令和协议。",
            "SNMPv3 engine time is outside the accepted time window.": "SNMPv3 引擎时间超出允许的时间窗口。",
            "The SNMPv3 authoritative engine restarted; time synchronization is required.": "SNMPv3 权威引擎已重启，需要重新同步时间。",
            "Process": "进程",
            "Local": "本地",
            "MAC address": "MAC 地址",
            "Interface": "接口",
            "Channel": "信道",
            "Security": "安全性",
            "Signal": "信号",
            "No WiFi data was returned by macOS.": "macOS 没有返回 WiFi 数据。",
            "Install lldpd with Homebrew to enable LLDP/CDP discovery.": "请通过 Homebrew 安装 lldpd 以启用 LLDP/CDP 发现。",
            "AWS Session Manager": "AWS 会话管理器",
            "Instance ID": "实例 ID",
            "Profile (optional)": "配置（可选）",
            "Region (optional)": "区域（可选）",
            "AWS Session Manager uses the installed AWS CLI and session-manager-plugin in Terminal.app.": "AWS 会话管理器会在 Terminal.app 中使用已安装的 AWS CLI 和 session-manager-plugin。",
            "URL": "URL",
            "Web Console opens the address in the default macOS browser.": "Web 控制台会在 macOS 默认浏览器中打开地址。",
            "Enter a valid HTTP or HTTPS URL.": "请输入有效的 HTTP 或 HTTPS URL。",
            "Enter an EC2 instance ID.": "请输入 EC2 实例 ID。",
            "This profile file is not a supported NETworkManager or Windows profile export.": "此配置文件不是受支持的 NETworkManager 或 Windows 配置导出文件。",
            "Use the SNMP tool to query this profile.": "请使用 SNMP 工具查询此配置文件。",
            "Lookup": "查找",
            "Connections": "连接",
            "Listeners": "监听端口",
            "Neighbor Table": "邻居表",
            "Bit Calculator": "比特计算器",
            "Subnet Calculator": "子网计算器",
            "Wake on LAN": "网络唤醒",
            "Hosts File Editor": "Hosts 文件编辑器",
            "Discovery Protocol": "发现协议",
            "Speed Test": "速度测试",
            "Firewall": "防火墙",
            "Remote Desktop": "远程桌面",
            "PuTTY": "SSH / Telnet",
            "PowerShell": "终端",
            "TigerVNC": "VNC",
            "Web Console": "Web 控制台",
            "Tools": "工具",
            "Monitor": "监控",
            "Discover": "发现",
            "Diagnose": "诊断",
            "Operate": "运维操作",
            "Reference": "参考查询",
            "Library": "资源库",
            "Find tools": "查找工具",
            "Find a tool or workflow": "查找工具或工作流",
            "Clear search": "清除搜索",
            "Operations overview": "运维总览",
            "This Mac": "本机",
            "Collecting…": "正在采集…",
            "Primary IPv4": "主 IPv4",
            "Active sockets": "活动套接字",
            "Known neighbors": "已知邻居",
            "No default interface": "无默认接口",
            "Connections and listeners": "连接与监听",
            "macOS ARP cache": "macOS ARP 缓存",
            "No ARP data returned": "未返回 ARP 数据",
            "Last collection": "最近采集",
            "Default route": "默认路由",
            "Gateway": "网关",
            "Gateway probe": "网关探测",
            "Probe gateway": "探测网关",
            "Probing…": "正在探测…",
            "No default route": "无默认路由",
            "Unavailable": "不可用",
            "Not tested": "尚未测试",
            "Checking…": "正在检测…",
            "Checking gateway": "正在检测网关",
            "Reachable": "可达",
            "No ICMP echo reply": "未收到 ICMP 回显",
            "Probe failed": "探测失败",
            "Probe failed after %@": "探测失败：%@",
            "No default route detected": "未检测到默认路由",
            "Route telemetry unavailable": "路由信息不可用",
            "Default route available": "默认路由可用",
            "Gateway reachable": "网关可达",
            "Gateway probe failed": "网关探测失败",
            "Check the macOS network service and interface state.": "请检查 macOS 网络服务及接口状态。",
            "A route exists, but the gateway may filter ICMP echo requests.": "路由存在，但网关可能过滤了 ICMP 回显请求。",
            "Default route through %@": "默认路由经由 %@",
            "Unable to read the default route.": "无法读取默认路由。",
            "macOS returned no default gateway or interface.": "macOS 未返回默认网关或接口。",
            "Unable to create an ICMP probe.": "无法创建 ICMP 探测。",
            "Subnet discovery": "网段发现",
            "Probe a local IPv4 range and list hosts that answer ICMP.": "探测本地 IPv4 网段，并列出响应 ICMP 的主机。",
            "CIDR or host range": "CIDR 或主机范围",
            "Start discovery": "开始发现",
            "%d targets: %@ to %@": "共 %d 个目标：%@ 至 %@",
            "Confirm large network scan": "确认大范围网络扫描",
            "Scan %d addresses": "扫描 %d 个地址",
            "Range %@ contains %d addresses. Continue?": "范围 %@ 包含 %d 个地址。是否继续？",
            "The range contains %d addresses, exceeding the scan limit of %d.": "范围包含 %d 个地址，超过 %d 个地址的扫描上限。",
            "%d of %d targets": "已完成 %d/%d 个目标",
            "Stopped after %d of %d targets.": "已停止：完成 %d/%d 个目标。",
            "Stopping…": "正在停止…",
            "Stopped after %d of %d addresses.": "已停止：探测了 %d/%d 个地址。",
            "Completed: %d of %d hosts responded.": "已完成：%d/%d 台主机响应。",
            "Use a range of 2,048 addresses or fewer for dashboard discovery.": "仪表板网段发现最多支持 2,048 个地址。",
            "Scan ports on %@": "扫描 %@ 的端口",
            "Diagnostic tools": "诊断工具",
            "Trace route": "追踪路由",
            "Interfaces": "网络接口",
            "Local neighbors": "本地邻居",
            "Live sockets": "实时套接字",
            "View all interfaces": "查看全部接口",
            "Open neighbor table": "打开邻居表",
            "Inspect all connections": "检查全部连接",
            "Copy address": "复制地址",
            "No network interfaces were found.": "未发现网络接口。",
            "macOS returned no neighbor records.": "macOS 未返回邻居记录。",
            "No IP sockets were returned by macOS.": "macOS 未返回 IP 套接字。",
            "Help": "帮助",
            "Welcome": "欢迎",
            "Documentation": "文档",
            "Report an issue": "报告问题",
            "Check for updates": "检查更新",
            "Quit NETworkManager": "退出 NETworkManager",
            "Status bar": "状态栏",
            "Application": "应用程序",
            "System": "系统",
            "Light": "浅色",
            "Dark": "深色",
            "Accent color": "主题色",
            "Accent": "主题色",
            "Start with Windows": "开机启动",
            "Start with macOS": "开机启动",
            "This opens the visible app at login. It does not keep a background worker running.": "此选项会在登录时打开应用，不会在退出后保留后台工作进程。",
            "NETworkManager runs as a visible app and exits when its last window closes. It does not install a separate daemon.": "NETworkManager 以可见应用运行，并在最后一个窗口关闭时退出；不会安装独立守护进程。",
            "Assets": "资产",
            "Workspace": "工作区",
            "All workspaces": "所有工作区",
            "Add workspace": "添加工作区",
            "Add workspace or site": "添加工作区或站点",
            "Workspace name": "工作区名称",
            "Add site": "添加站点",
            "Edit site": "编辑站点",
            "Delete site": "删除站点",
            "Site actions": "站点操作",
            "Site": "站点",
            "Location": "位置",
            "Add subnet": "添加子网",
            "Edit subnet": "编辑子网",
            "Subnet": "子网",
            "CIDR": "CIDR",
            "Purpose": "用途",
            "Enter a valid IPv4 or IPv6 CIDR.": "请输入有效的 IPv4 或 IPv6 CIDR。",
            "Add asset": "添加资产",
            "Delete selected asset group?": "删除所选资产组？",
            "Deleting this site removes %d devices and their diagnostic history.": "删除此站点将同时移除 %d 台设备及其诊断历史。",
            "Deleting a subnet keeps its devices and clears their subnet association.": "删除子网会保留设备，并清除设备的子网关联。",
            "Local operations": "本地运维",
            "Search assets": "搜索资产",
            "Select a device": "选择设备",
            "Choose an asset to inspect status and run diagnostics.": "选择资产以查看状态并运行诊断。",
            "Workspace recovery required": "需要恢复工作区",
            "Import backup to recover": "导入备份以恢复",
            "Asset data could not be read. The original file was preserved. Import a valid backup to restore this workspace. (%@)": "无法读取资产数据。原文件已保留。请导入有效备份以恢复此工作区。（%@）",
            "Asset data is damaged or from an unsupported format. The original file was preserved. Import a valid backup to restore this workspace.": "资产数据已损坏或格式不受支持。原文件已保留。请导入有效备份以恢复此工作区。",
            "Asset workspace could not be saved: %@": "无法保存资产工作区：%@",
            "Damaged data copy: %@": "损坏数据副本：%@",
            "Settings recovery required": "需要恢复设置",
            "The settings file is damaged and was preserved. Open Settings to review recovery before resetting preferences.": "设置文件已损坏且已保留。请打开设置页查看恢复提示，再重置偏好设置。",
            "Reset settings and recover": "重置设置并恢复",
            "Reset settings and recover?": "重置设置并恢复？",
            "This restores default preferences and keeps a copy of the damaged settings file.": "此操作会恢复默认偏好设置，并保留一份损坏设置文件副本。",
            "Settings could not be read. The original file was preserved. Reset settings to recover. (%@)": "无法读取设置。原文件已保留。请重置设置以恢复。（%@）",
            "Settings data is damaged or from an unsupported format. The original file was preserved. Reset settings to recover.": "设置数据已损坏或格式不受支持。原文件已保留。请重置设置以恢复。",
            "Settings could not be saved: %@": "无法保存设置：%@",
            "Damaged settings could not be preserved: %@": "无法保留损坏的设置文件：%@",
            "Add device": "添加设备",
            "Address or hostname": "地址或主机名",
            "Workstation": "工作站",
            "Server": "服务器",
            "Router": "路由器",
            "Switch": "交换机",
            "Access point": "无线接入点",
            "Other": "其他",
            "Role": "角色",
            "Vendor": "厂商",
            "Notes": "备注",
            "Operator workstation": "运维工作站",
            "Diagnostic history": "诊断历史",
            "%d runs": "%d 次运行",
            "No diagnostics have been run for this device.": "此设备尚未运行诊断。",
            "Ping": "Ping",
            "Login item enabled": "登录项已启用",
            "Login item disabled": "登录项已禁用",
            "Login item unavailable for this app bundle": "此应用包当前无法使用登录项",
            "Login item status unavailable": "登录项状态不可用",
            "Login item error": "登录项错误",
            "Approval required in System Settings": "需要在系统设置中批准",
            "Open Login Items": "打开登录项设置",
            "A legacy login item was found and will be removed when this setting is changed.": "发现旧版登录项；更改此设置时会将其移除。"
            ,"NetBox": "NetBox",
            "NetBox connection": "NetBox 连接",
            "Read-only asset context from your NetBox source of truth.": "从 NetBox 权威资产源读取只读资产信息。",
            "NetBox base URL": "NetBox 基础 URL",
            "API token in Keychain": "Keychain 中的 API 令牌",
            "Select a credential": "选择凭据",
            "Add an API token in Credentials before connecting.": "连接前请先在“凭据”中添加 API 令牌。",
            "Test connection": "测试连接",
            "Sync read-only": "只读同步",
            "Read-only · no changes are sent to NetBox": "只读 · 不会向 NetBox 写入更改",
            "Not connected": "未连接",
            "Connecting to NetBox…": "正在连接 NetBox…",
            "NetBox connection ready": "NetBox 连接正常",
            "Action required": "需要处理",
            "NetBox request failed": "NetBox 请求失败",
            "Offline preview loaded": "离线预览已载入",
            "Last connection test: %@": "最近连接测试：%@",
            "Devices imported": "读取设备数",
            "Sites imported": "读取站点数",
            "Devices read": "读取设备数",
            "Sites read": "读取站点数",
            "Pages read": "读取页数",
            "Last synced": "最近同步",
            "Source": "来源",
            "NetBox devices": "NetBox 设备",
            "NetBox returned no devices.": "NetBox 未返回设备。",
            "Read-only sync completed. %d new assets added; local assets were not overwritten.": "只读同步完成，新增 %d 项资产；未覆盖本地资产。",
            "Read-only sync completed. Review %d devices; %d are eligible to add.": "只读同步完成：请审核 %d 台设备，其中 %d 台可添加。",
            "NetBox import preview": "NetBox 导入预览",
            "%d selected of %d importable": "已选择 %d 台，可导入 %d 台",
            "Select new": "选择新增项",
            "Clear selection": "清除选择",
            "Add selected": "添加所选项",
            "No NetBox devices are available to review.": "没有可审核的 NetBox 设备。",
            "Select": "选择",
            "Import status": "导入状态",
            "Select %@ for import": "选择导入 %@",
            "No primary IP; cannot add": "没有主 IP，无法添加",
            "No primary address": "没有主地址",
            "Duplicate in NetBox results": "NetBox 结果中重复",
            "Local workspace is unavailable": "本地工作区不可用",
            "Already in local assets": "已存在于本地资产",
            "Ready to add": "可添加",
            "Confirm local asset import": "确认导入本地资产",
            "Add %d selected devices": "添加所选 %d 台设备",
            "Selected NetBox devices will be added to the local workspace. No changes will be sent to NetBox.": "所选 NetBox 设备将添加到本地工作区，不会向 NetBox 写入任何更改。",
            "Added %d new devices to the local workspace.": "已向本地工作区添加 %d 台新设备。",
            "The selected devices are already present or cannot be imported.": "所选设备已存在或无法导入。",
            "Connection changed. Sync again to review devices from the current source.": "连接配置已更改。请重新同步并审核当前来源的设备。",
            "Connection changed while NetBox was responding. Sync again to review the current source.": "NetBox 响应期间连接配置已更改。请重新同步并审核当前来源。",
            "Load import preview fixture": "载入导入预览样例",
            "Offline preview fixture loaded. No service was contacted and no assets were changed.": "离线预览样例已载入。未连接任何服务，也未更改资产。",
            "Reading device and site pages from NetBox.": "正在从 NetBox 读取设备和站点分页。",
            "NetBox API is reachable with this credential.": "使用此凭据可以访问 NetBox API。",
            "Enter a valid NetBox base URL using HTTPS.": "请输入有效的 HTTPS NetBox 基础 URL。",
            "Enter an HTTPS NetBox URL with no credentials or query parameters. HTTP is limited to loopback testing.": "请输入不含凭据或查询参数的 HTTPS NetBox URL。HTTP 仅允许用于本机回环测试。",
            "HTTP is allowed only for loopback testing. Use HTTPS for network NetBox instances.": "HTTP 仅允许用于本机回环测试。连接网络中的 NetBox 实例请使用 HTTPS。",
            "No API token is available in Keychain.": "Keychain 中没有可用的 API 令牌。",
            "Select a Keychain API token before connecting.": "连接前请选择 Keychain API 令牌。",
            "The selected Keychain credential is no longer available.": "所选 Keychain 凭据已不可用。",
            "The selected Keychain credential does not contain an API token.": "所选 Keychain 凭据不包含 API 令牌。",
            "The NetBox request timed out. Check the URL and network path, then retry.": "NetBox 请求超时。请检查 URL 和网络路径后重试。",
            "Credentials": "凭据",
            "Add credential": "添加凭据",
            "Secrets are stored in the macOS Keychain. This list contains references and metadata only.": "秘密信息存储在 macOS Keychain 中。此列表仅显示引用和元数据。",
            "No credentials": "没有凭据",
            "Add a credential reference for a network device or service.": "为网络设备或服务添加凭据引用。",
            "Export credential references": "导出凭据引用",
            "Restore credential references": "恢复凭据引用",
            "Credential metadata needs recovery": "凭据元数据需要恢复",
            "Reference backups contain metadata only and can be restored only while their Keychain items remain available on this Mac.": "引用备份只包含元数据；只有此 Mac 的 Keychain 中仍保留对应项目时才能恢复。",
            "Credential metadata is damaged or invalid. The original file was preserved. Restore a valid reference backup.": "凭据元数据已损坏或无效。原文件已保留，请恢复有效的引用备份。",
            "Credential metadata is missing, but Keychain items may still exist. Restore a valid reference backup before changing credentials.": "凭据元数据文件缺失，但 Keychain 中可能仍有秘密项目。修改凭据前请先恢复有效的引用备份。",
            "Credential metadata could not be read. The original file was preserved. Restore an exported reference backup. (%@)": "无法读取凭据元数据。原文件已保留，请恢复导出的引用备份。（%@）",
            "Credential metadata marker could not be saved: %@": "无法保存凭据元数据标记：%@",
            "Credential references restored.": "凭据引用已恢复。",
            "Credential reference backup export failed: %@": "导出凭据引用备份失败：%@",
            "Credential reference import failed: %@": "导入凭据引用备份失败：%@",
            "Credential not found.": "找不到凭据。",
            "Credential reference not found.": "找不到凭据引用。",
            "Credential changes are disabled until metadata is restored.": "恢复元数据前，凭据修改功能已停用。",
            "Credential metadata recovery is not needed.": "凭据元数据当前无需恢复。",
            "Credential reference backup is invalid.": "凭据引用备份无效。",
            "The backup refers to a Keychain item that is unavailable: %@": "备份引用的 Keychain 项目不可用：%@",
            "Credential metadata could not be saved: %@": "无法保存凭据元数据：%@",
            "Credential metadata backup could not be preserved: %@": "无法保留原凭据元数据副本：%@",
            "Credential was not saved and its temporary Keychain item could not be removed: %@": "凭据未保存，且无法删除临时 Keychain 项目：%@",
            "Credential metadata could not be saved and the previous Keychain value could not be restored: %@": "无法保存凭据元数据，也无法恢复之前的 Keychain 值：%@",
            "Credential metadata could not be restored after a failed Keychain deletion: %@": "Keychain 删除失败后无法恢复凭据元数据：%@",
            "Credential saved to Keychain": "凭据已保存到 Keychain",
            "Edit credential": "编辑凭据",
            "Credential updated": "凭据已更新",
            "Replace secret in Keychain": "替换 Keychain 中的秘密",
            "Credential removed": "凭据已移除",
            "Delete credential": "删除凭据",
            "Label": "标签",
            "Account or username (optional)": "账户或用户名（可选）",
            "Password": "密码",
            "API token": "API 令牌",
            "SNMP community or secret": "SNMP 团体字符串或密钥",
            "Private key path": "私钥路径",
            "Passphrase (optional)": "口令（可选）",
            "Enter a label": "请输入标签",
            "Enter the required secret value": "请输入必需的秘密值",
            "SSH key reference": "SSH 密钥引用",
            "SSH identity in Keychain": "Keychain 中的 SSH 身份",
            "No SSH identity": "不指定 SSH 身份",
            "OpenSSH prompts for key passphrases in the terminal.": "OpenSSH 会在终端中提示输入私钥口令。",
            "Credential reference": "凭据引用",
            "None": "无",
            "Export backup": "导出备份",
            "Import backup": "导入备份",
            "Asset workspace actions": "资产工作区操作",
            "Asset backup imported.": "资产备份已导入。",
            "Backup export failed: %@": "备份导出失败：%@",
            "Backup import failed: %@": "备份导入失败：%@",
            "Export Markdown": "导出 Markdown",
            "Export JSON": "导出 JSON",
            "Export redacted diagnostic evidence": "导出已脱敏的诊断证据",
            "Filter by device, target or result": "按设备、目标或结果筛选",
            "All checks": "全部检查",
            "Period": "时间范围",
            "All time": "全部时间",
            "Last 24 hours": "最近 24 小时",
            "Last 7 days": "最近 7 天",
            "Export filtered evidence": "导出筛选后的证据",
            "No matching diagnostics": "没有匹配的诊断记录",
            "Completed checks and standalone lookups will appear here.": "资产诊断和独立查询记录会显示在这里。",
            "Standalone check": "独立查询",
            "Enter a valid WHOIS query.": "请输入有效的 WHOIS 查询。",
            "Cannot resolve WHOIS server %@": "无法解析 WHOIS 服务器 %@",
            "The WHOIS server did not answer in time.": "WHOIS 服务器未在规定时间内响应。",
            "WHOIS response received from %@": "已收到来自 %@ 的 WHOIS 响应",
            "%d field(s) parsed": "已解析 %d 个字段",
            "SNTP response from %@": "收到来自 %@ 的 SNTP 响应",
            "Unknown device": "未知设备",
            "Running": "运行中",
            "Succeeded": "成功",
            "Cancelled": "已取消",
            "Interrupted when app closed": "应用关闭时中断",
            "Interrupted": "已中断",
            "SNMPv3 requires a credential with a username and authentication password.": "SNMPv3 需要包含用户名和认证口令的凭据。",
            "This device was removed, so the diagnostic cannot be repeated.": "此设备已删除，无法重复运行该诊断。",
            "Repeat with saved parameters": "使用已保存的参数重跑",
            "Repeat diagnostic": "重跑诊断",
            "Timed out": "超时",
            "Permission denied": "权限被拒绝",
            "Unreachable": "不可达",
            "Target: %@": "目标：%@",
            "Rerun with same parameters": "使用相同参数重跑",
            "Diagnostic cancelled": "诊断已取消",
            "Traceroute cancelled": "路由追踪已取消",
            "Ping in progress": "Ping 正在进行",
            "Ping host": "Ping 主机",
            "View event history": "查看事件历史",
            "View history for event %@": "查看事件 %@ 的历史",
            "No diagnostic record was returned.": "未返回诊断记录。",
            "Load loopback fixture": "加载回环测试告警",
            "Local loopback fixture": "本机回环测试主机",
            "Local loopback diagnostic fixture": "本机回环诊断测试告警",
            "No external service was contacted.": "未连接任何外部服务。",
            "Local loopback fixture loaded; no external service was contacted.": "本机回环测试告警已加载；未连接任何外部服务。"
        ])
    }
}

// MARK: - Shorthand

/// Translate an English source string using the shared registry.
///
/// Not main-actor isolated so that models, background workers and tests can use it too.
public func t(_ english: String) -> String { Loc.shared.t(english) }

/// Translate + format.
public func tf(_ english: String, _ args: CVarArg...) -> String {
    String(format: Loc.shared.t(english), locale: Loc.shared.locale, arguments: args)
}

/// Register Chinese translations for a feature module.
public func registerZh(_ table: [String: String]) {
    Loc.shared.register(zh: table)
}
