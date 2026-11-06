#!/usr/bin/env python3
"""Generate the research-backed macOS workbench roadmap DOCX."""

from pathlib import Path

from docx import Document
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "macos" / "NETworkManager-macOS-Workbench-Research-Roadmap-v2-2026-11-03.docx"

NAVY = "17324D"
TEAL = "007E87"
PALE = "EAF2F4"
PALE_BLUE = "EAF0F6"
MID = "5B6875"
GRID = "CCD5DC"
WHITE = "FFFFFF"


def set_cell_shading(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), fill)


def set_cell_border(cell, **kwargs):
    tc = cell._tc
    tc_pr = tc.get_or_add_tcPr()
    borders = tc_pr.first_child_found_in("w:tcBorders")
    if borders is None:
        borders = OxmlElement("w:tcBorders")
        tc_pr.append(borders)
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        if edge not in kwargs:
            continue
        tag = "w:{}".format(edge)
        element = borders.find(qn(tag))
        if element is None:
            element = OxmlElement(tag)
            borders.append(element)
        for key in ("val", "sz", "space", "color"):
            if key in kwargs[edge]:
                element.set(qn("w:" + key), str(kwargs[edge][key]))


def set_repeat_table_header(row):
    tr_pr = row._tr.get_or_add_trPr()
    tbl_header = OxmlElement("w:tblHeader")
    tbl_header.set(qn("w:val"), "true")
    tr_pr.append(tbl_header)


def set_cant_split(row):
    tr_pr = row._tr.get_or_add_trPr()
    tr_pr.append(OxmlElement("w:cantSplit"))


def set_cell_margins(cell, top=90, start=105, bottom=90, end=105):
    tc_pr = cell._tc.get_or_add_tcPr()
    tc_mar = tc_pr.first_child_found_in("w:tcMar")
    if tc_mar is None:
        tc_mar = OxmlElement("w:tcMar")
        tc_pr.append(tc_mar)
    for margin, value in (("top", top), ("start", start), ("bottom", bottom), ("end", end)):
        node = tc_mar.find(qn("w:" + margin))
        if node is None:
            node = OxmlElement("w:" + margin)
            tc_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def set_run_font(run, name="Hiragino Sans GB", size=10.2, color=NAVY, bold=False):
    run.font.name = name
    run.font.size = Pt(size)
    run.font.color.rgb = RGBColor.from_string(color)
    run.bold = bold
    r_pr = run._element.get_or_add_rPr()
    r_fonts = r_pr.rFonts
    if r_fonts is None:
        r_fonts = OxmlElement("w:rFonts")
        r_pr.insert(0, r_fonts)
    for font_attr in ("ascii", "hAnsi", "eastAsia", "cs"):
        r_fonts.set(qn("w:" + font_attr), name)


def add_hyperlink(paragraph, text, url):
    relationship_id = paragraph.part.relate_to(
        url,
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
        is_external=True,
    )
    hyperlink = OxmlElement("w:hyperlink")
    hyperlink.set(qn("r:id"), relationship_id)
    run = OxmlElement("w:r")
    props = OxmlElement("w:rPr")
    color = OxmlElement("w:color")
    color.set(qn("w:val"), TEAL)
    props.append(color)
    underline = OxmlElement("w:u")
    underline.set(qn("w:val"), "single")
    props.append(underline)
    fonts = OxmlElement("w:rFonts")
    fonts.set(qn("w:eastAsia"), "Hiragino Sans GB")
    props.append(fonts)
    run.append(props)
    value = OxmlElement("w:t")
    value.text = text
    run.append(value)
    hyperlink.append(run)
    paragraph._p.append(hyperlink)


def set_paragraph(paragraph, before=0, after=5, line=1.12, keep=False):
    fmt = paragraph.paragraph_format
    fmt.space_before = Pt(before)
    fmt.space_after = Pt(after)
    fmt.line_spacing = line
    fmt.keep_with_next = keep


def add_text(doc, text, style=None, before=0, after=5, color=NAVY, size=10.2, bold=False):
    paragraph = doc.add_paragraph(style=style)
    set_paragraph(paragraph, before, after)
    run = paragraph.add_run(text)
    set_run_font(run, size=size, color=color, bold=bold)
    return paragraph


def add_bullet(doc, text, level=0):
    paragraph = doc.add_paragraph(style="List Bullet" if level == 0 else "List Bullet 2")
    set_paragraph(paragraph, after=2.5, line=1.08)
    run = paragraph.add_run(text)
    set_run_font(run, size=9.8, color=NAVY)
    return paragraph


def add_number(doc, text):
    paragraph = doc.add_paragraph(style="List Number")
    set_paragraph(paragraph, after=3, line=1.08)
    run = paragraph.add_run(text)
    set_run_font(run, size=9.8, color=NAVY)
    return paragraph


def add_heading(doc, text, level=1):
    paragraph = doc.add_paragraph(style="Heading {}".format(level))
    set_paragraph(paragraph, before=9 if level == 1 else 6, after=4, line=1.0, keep=True)
    run = paragraph.add_run(text)
    set_run_font(run, size={1: 16, 2: 12, 3: 10.5}[level], color=TEAL if level > 1 else NAVY, bold=True)
    return paragraph


def add_callout(doc, title, text, fill=PALE_BLUE):
    table = doc.add_table(rows=1, cols=1)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    cell = table.cell(0, 0)
    set_cell_shading(cell, fill)
    set_cell_margins(cell, top=150, bottom=150, start=180, end=180)
    set_cell_border(cell, left={"val": "single", "sz": 22, "color": TEAL})
    p = cell.paragraphs[0]
    set_paragraph(p, after=4, line=1.08)
    r = p.add_run(title)
    set_run_font(r, size=10.5, color=TEAL, bold=True)
    p2 = cell.add_paragraph()
    set_paragraph(p2, after=0, line=1.12)
    r = p2.add_run(text)
    set_run_font(r, size=10, color=NAVY)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)


def add_table(doc, headers, rows, widths=None, font_size=8.5):
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    table.style = "Table Grid"
    header_row = table.rows[0]
    set_repeat_table_header(header_row)
    set_cant_split(header_row)
    for idx, header in enumerate(headers):
        cell = header_row.cells[idx]
        set_cell_shading(cell, NAVY)
        set_cell_margins(cell)
        cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
        p = cell.paragraphs[0]
        set_paragraph(p, after=0, line=1.0)
        r = p.add_run(header)
        set_run_font(r, size=font_size, color=WHITE, bold=True)
    for row_index, values in enumerate(rows):
        row = table.add_row()
        set_cant_split(row)
        for idx, value in enumerate(values):
            cell = row.cells[idx]
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.TOP
            set_cell_margins(cell)
            set_cell_border(cell, bottom={"val": "single", "sz": 3, "color": GRID})
            if row_index % 2 == 1:
                set_cell_shading(cell, "F5F8FA")
            p = cell.paragraphs[0]
            set_paragraph(p, after=0, line=1.05)
            r = p.add_run(value)
            set_run_font(r, size=font_size, color=NAVY, bold=(idx == 0))
        if widths:
            for cell, width in zip(row.cells, widths):
                cell.width = Inches(width)
    if widths:
        for cell, width in zip(header_row.cells, widths):
            cell.width = Inches(width)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)
    return table


def add_source(doc, number, title, organization, url, use):
    p = doc.add_paragraph()
    set_paragraph(p, after=3, line=1.04)
    r = p.add_run("[{}] {} - {}. ".format(number, title, organization))
    set_run_font(r, size=8.7, color=NAVY, bold=True)
    add_hyperlink(p, url, url)
    r = p.add_run("  |  核验用途：" + use)
    set_run_font(r, size=8.5, color=MID)


def add_page_number(paragraph):
    paragraph.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    r = paragraph.add_run("NETworkManager macOS 路线图  |  ")
    set_run_font(r, size=8, color=MID)
    field = OxmlElement("w:fldSimple")
    field.set(qn("w:instr"), "PAGE")
    paragraph._p.append(field)


def configure(doc):
    section = doc.sections[0]
    section.page_width = Inches(8.27)
    section.page_height = Inches(11.69)
    section.top_margin = Inches(0.62)
    section.bottom_margin = Inches(0.62)
    section.left_margin = Inches(0.7)
    section.right_margin = Inches(0.7)
    section.header_distance = Inches(0.28)
    section.footer_distance = Inches(0.28)

    normal = doc.styles["Normal"]
    normal.font.name = "Hiragino Sans GB"
    normal.font.size = Pt(10.2)
    normal.font.color.rgb = RGBColor.from_string(NAVY)
    normal._element.rPr.rFonts.set(qn("w:eastAsia"), "Hiragino Sans GB")
    for style_name in ("List Bullet", "List Bullet 2", "List Number"):
        style = doc.styles[style_name]
        style.font.name = "Hiragino Sans GB"
        style.font.size = Pt(9.8)
        style._element.rPr.rFonts.set(qn("w:eastAsia"), "Hiragino Sans GB")

    header = section.header.paragraphs[0]
    set_paragraph(header, after=0)
    run = header.add_run("PRODUCT & ENGINEERING ROADMAP  /  MACOS")
    set_run_font(run, size=7.5, color=MID, bold=True)
    add_page_number(section.footer.paragraphs[0])

    props = doc.core_properties
    props.title = "NETworkManager macOS 超级网络运维工作台：调研版路线图 v2.0"
    props.subject = "基于仓库现状、Apple 平台文档与网络运维平台一手资料的产品和工程计划"
    props.author = "NETworkManager project planning"
    props.keywords = "macOS, SwiftUI, Network Operations, Roadmap, NetBox, Zabbix, LibreNMS"


def build():
    doc = Document()
    configure(doc)

    p = doc.add_paragraph()
    set_paragraph(p, before=44, after=8, line=1.0)
    r = p.add_run("NETworkManager")
    set_run_font(r, size=15, color=TEAL, bold=True)

    p = doc.add_paragraph()
    set_paragraph(p, after=4, line=1.0)
    r = p.add_run("macOS 超级网络运维工作台")
    set_run_font(r, size=28, color=NAVY, bold=True)

    p = doc.add_paragraph()
    set_paragraph(p, after=17, line=1.0)
    r = p.add_run("调研驱动的产品与工程路线图  |  V2.0")
    set_run_font(r, size=14, color=TEAL, bold=True)

    add_text(doc, "方案基准：2026 年 11 月 3 日", after=3, color=MID, size=10)
    add_text(doc, "范围：重新定义 macOS 版的工作流、界面、技术边界、阶段目标和发布验收。", after=16, color=MID, size=10)

    add_callout(
        doc,
        "核心建议",
        "把产品做成网络工程师随手打开的本机运维工作台：围绕环境与资产组织工具，连接现有资产源和监控平台，把诊断、会话、操作记录串成完整流程。首发不复制一个新的常驻 NMS，也不安装 NETworkManager 专属后台守护进程。",
    )
    add_heading(doc, "本版基于什么", 2)
    add_bullet(doc, "直接检查仓库中的 SwiftUI/AppKit 代码、macos/PORTING_STATUS.md、打包脚本和设置持久化实现。")
    add_bullet(doc, "在线核对 Apple Developer、NetBox、LibreNMS、Zabbix、Wireshark 与 IETF RFC 的一手文档；来源清单和用途在文末。")
    add_bullet(doc, "将已核实的平台事实与产品取舍分开标注。方案尚未包含现场访谈、用户数据分析、第三方 API 兼容性实测或商业市场规模研究。")

    add_heading(doc, "一句话产品定义", 2)
    add_text(doc, "面向网络工程师和 IT 运维人员的 macOS 桌面控制台：让操作者快速回答“哪个环境、哪台设备、出了什么问题、下一步怎样验证、执行过什么”，并把结果交给团队或现有系统。", after=2)

    doc.add_page_break()
    add_heading(doc, "1. 仓库基线与关键差距")
    add_text(doc, "截至本方案日期，macOS 端不是从零开始：它已有可运行的 SwiftPM 应用和 Universal App/DMG 打包路径。下一阶段的主要问题是把独立工具组织成工作流，并补齐资产、凭据、历史、平台权限和分发质量。")
    add_table(doc, ["领域", "已经具备", "关键缺口 / 计划处理"], [
        ("应用与 UI", "SwiftUI + AppKit；macOS 14+；分组导航、工具搜索、设置窗口、操作台概览。", "仍以工具入口为中心；没有环境上下文、设备详情检查器、事件队列和任务时间线。先重做导航与主窗口工作流。"),
        ("诊断能力", "接口信息、IPv4 发现、TCP 连接扫描、有限次数 Ping、DNS、Traceroute、SNTP、WHOIS、Wake-on-LAN、子网计算、本机连接/邻居信息。", "Ping Monitor 不是持续服务；诊断结果没有统一历史与资产关联；增加取消、超时、重试与新鲜度语义。"),
        ("SNMP / 邻居", "原生 BER 支持 SNMP v1/v2c GET、WALK、SET；LLDP/CDP 依赖可选 lldpcli。", "没有 SNMPv3 USM。先按 RFC 实现并用多厂商测试矩阵验证；抓包能力不放进无守护进程的首发范围。"),
        ("资产与秘密", "JSON 配置文件、Windows JSON/XML 导入、密码加密导出。", "没有统一 Site/Device/Subnet/Run 模型；凭据没有 Keychain 存储与引用；配置文件 JSON 不应承担明文秘密仓库。"),
        ("远程访问", "RDP/VNC URL scheme、Terminal.app、浏览器或外部工具交接。", "内嵌 SSH/SFTP 会话、已知主机密钥确认和多会话工作区尚未形成；RDP/VNC 客户端仍是外部依赖。"),
        ("后台与发布", "脚本可生成 arm64、x86_64、Universal .app 与 DMG；默认 ad-hoc 签名。", "开机启动当前直接写用户 LaunchAgents plist 并调用 launchctl；发布脚本尚未完成 Developer ID、Notary 提交、staple 与安装回归。"),
    ], widths=[1.0, 2.65, 3.35], font_size=8.2)

    add_callout(
        doc,
        "需要先纠正的后台行为",
        "macos/Sources/NMCore/Settings.swift 中的 LaunchAgent 实现会写入 ~/Library/LaunchAgents 并调用 launchctl。建议 P0 将其迁移到 Apple 的 SMAppService.mainAppService 用户可见登录项，或在完成迁移前关闭开机启动。登录时启动的仍是 NETworkManager 主应用，不应启动隐藏的采集守护进程；应用退出后不得留下本项目后台进程。",
        fill="F0F5F7",
    )

    add_heading(doc, "2. 调研结论：产品应该站在哪里")
    add_table(doc, ["系统 / 资料", "它擅长什么", "对本项目的含义"], [
        ("NetBox", "网络的设计状态与 Source of Truth：站点、设备、线缆、IPv4/IPv6 IPAM、VRF、VLAN、权限和 API。官方明确区分设计状态与运行状态，并不把网络监控作为核心职责。", "不要另造一套企业 CMDB/IPAM。先做只读 API 连接器；用 NetBox 的资产上下文发起探测，把实时观察值和权威配置值并列显示；任何写回都放到后续审批阶段。"),
        ("Zabbix", "周期性范围发现、服务可用性检查和 SNMP 数据采集；适合持续监控。其网络发现文档明确说明该机制本身不发现网络拓扑。", "工作台可消费告警、最新数据和资产链接；拓扑视图由 LLDP/CDP/平台数据另外构建，不把 IP 范围扫描伪装成拓扑发现。"),
        ("LibreNMS", "持续自动发现及 SNMP 轮询、告警和 API；自动发现可使用 CDP/FDP/LLDP、OSPF、BGP、SNMP、ARP。", "对于已运行 LibreNMS 的客户，优先把它作为长期采集/发现后端，macOS 端做一线诊断与告警处置入口，避免重复部署监控栈。"),
        ("Wireshark", "完整抓包和协议分析。其 macOS 指南要求安装 ChmodBPF launch daemon 才能捕获数据包。", "原生抓包与“无专属后台服务、独立可分发”的目标存在冲突。V1 暂不捆绑；可保留用户自行安装 Wireshark 后的显式交接。只有有明确需求且用户同意时才设计可卸载的权限组件。"),
    ], widths=[1.08, 2.8, 3.12], font_size=8.0)

    add_heading(doc, "平台事实及其设计后果", 2)
    add_bullet(doc, "macOS 15 引入本地网络隐私授权。使用局域网扫描、网关探测或设备连接前，要用清楚的 NSLocalNetworkUsageDescription 解释用途，并在用户拒绝后给出可操作的状态说明。当前最低版本为 macOS 14，因此必须分别验证 14 与 15+ 行为。[1]")
    add_bullet(doc, "Apple 的 Network framework 适合 TCP/UDP/TLS 等应用层连接；权限等待、断开、取消与重试要成为服务层行为，不能只在 UI 上显示旋转图标。[2]")
    add_bullet(doc, "macOS 13+ 提供 SMAppService 注册/管理登录项、LaunchAgent 和 LaunchDaemon 的系统 API。产品应使用主应用登录项，并公开其状态与关闭入口；任何长期后台采集都需要另立决策。[3]")
    add_bullet(doc, "Apple Keychain Services 专为保存小型密码、令牌等秘密设计。资产文件只保存凭据引用；复制、导出和日志流程都默认脱敏。[4]")
    add_bullet(doc, "SNMPv3 USM 不是给 v2c 加一个用户名字段：它涉及引擎发现、时间窗同步、认证/隐私算法和错误报告。实现以 RFC 3414 为基础，并至少对 RFC 7860 SHA-2 认证方案做向量测试，再验证设备差异。[11][12]")
    add_bullet(doc, "Apple Notary 服务检查 Developer ID 签名软件的恶意代码和签名问题；公证不等于 App Review。当前脚本的 ad-hoc 签名只适合本机测试，不能作为下载分发门槛。[13]")

    doc.add_page_break()
    add_heading(doc, "3. 运维人员界面：从工具菜单改成任务工作区")
    add_text(doc, "目标不是把更多图表塞进首页，而是给工程师稳定的环境上下文、清楚的异常队列和连续的排障动作。采用原生 macOS 多栏布局，支持鼠标、键盘、窗口分离和系统外观。")
    add_table(doc, ["界面区域", "推荐内容与行为"], [
        ("工作区栏", "当前客户 / 环境 / 站点，连接健康度、数据来源、最近同步时间。切换环境时，查询、终端、历史记录和导出范围都跟随该上下文。"),
        ("左侧导航", "工作台、资产、监测、发现、诊断、会话、自动化、操作记录。工具仍可独立打开，但主流程从环境或设备出发。"),
        ("主内容区", "按工作流选择列表、事件队列、端口/接口表、拓扑或诊断运行结果。默认用密集但可扫读的表格和分组；状态同时显示“值、来源、采集时间、新鲜度”。"),
        ("详情检查器", "选中设备时显示接口、地址、最近告警、关联会话和快捷诊断；诊断结果可回连设备、工单标签和运行记录。"),
        ("任务与会话", "任务可取消、重跑、复制参数并打开详情；SSH 会话以标签页呈现。关键操作在工具栏、菜单、命令搜索和键盘快捷键都可达。"),
    ], widths=[1.22, 5.78], font_size=8.6)

    add_heading(doc, "四条必须在原型中走通的路径", 2)
    add_number(doc, "告警处置：选告警 -> 定位环境和设备 -> 查看最近状态与上次健康值 -> 执行 Ping / DNS / TCP / 路由 / SNMP 检查 -> 保存证据 -> 复制可脱敏的摘要。")
    add_number(doc, "新设备接入：导入或从 NetBox 选择设备 -> 校验地址、端口与凭据引用 -> 发起单台/小范围发现 -> 人工确认名称、角色与观测结果 -> 写入本机工作区。")
    add_number(doc, "连通性排查：选择站点/子网/设备 -> 显示预计探测数量与授权范围 -> 运行可取消任务 -> 按在线、超时、拒绝、解析失败分类 -> 从结果继续端口和服务检查。")
    add_number(doc, "远程处理：从已选设备打开 SSH 会话 -> 展示主机密钥变化 -> 在可见终端执行 -> 操作历史记录操作者、目标、时间和结果摘要，不记录秘密或未经同意的完整命令输出。")

    add_callout(doc, "首页的信息优先级", "先显示事件影响、受影响资产数、数据新鲜度和下一步入口；折线图、吞吐量趋势和健康分值必须能追溯到来源与时间。没有数据时显示“未知 / 尚未检查”，不把“没有发现问题”显示为“网络正常”。")

    add_heading(doc, "4. 产品与架构决策")
    add_table(doc, ["决策", "V1 建议", "原因 / 边界"], [
        ("产品边界", "本机运维工作台 + 连接器。", "长时间轮询、告警路由和规模化发现使用现有 Zabbix/LibreNMS；NetBox 继续承载权威设计状态。"),
        ("默认进程模型", "只运行可见主应用。不开机常驻采集，不安装独立守护进程。", "关闭最后窗口退出；退出时取消本应用任务。登录启动只重开主应用且需用户选择，并在系统登录项中可管理。"),
        ("本地数据", "版本化本机数据库保存工作区覆盖层、诊断运行和操作记录；迁移决策先用资产/历史规模原型验证。", "保持离线可用，支持按环境备份、导入和导出。NetBox 与 NMS 的数据标注来源和同步时间，禁止无声覆盖。"),
        ("凭据", "Keychain 存用户名密码、SNMP 密钥、API token 与 SSH 私钥引用；数据库只存 item ID 和非秘密属性。", "提供每环境最小权限凭据、访问/删除、备份迁移说明和脱敏导出。不要把秘密塞进 JSON profile。"),
        ("集成策略", "先只读 NetBox、Zabbix、LibreNMS。支持连接测试、范围映射、分页、速率限制、版本兼容提示和断线重试。", "只读连接器能快速获得资产与告警上下文，也降低把本地观测误写为权威资产的风险。NetBox 写 API 令牌应单独授权且默认关闭。"),
        ("高级权限", "原生 TCP/UDP 诊断优先；抓包、内核扩展和管理员 helper 不在首发。", "macOS 抓包需要系统级 BPF 权限配置；若未来做 helper，需独立安装、可见状态、可卸载和单独安全评审。"),
        ("平台与分发", "继续 SwiftUI/AppKit 和 macOS 14+；先做 Developer ID + Hardened Runtime + notarized Universal DMG。", "当前 Package.swift 和 Info.plist 已以 14.0 为最低系统；App Store 作为单独兼容性与沙盒评估，不阻塞独立 DMG。"),
    ], widths=[1.12, 2.88, 3.0], font_size=8.0)

    add_heading(doc, "5. 分阶段路线")
    add_text(doc, "按依赖顺序交付；每阶段都产生可操作的 GUI 结果。下面的阶段顺序比固定日期更可靠。工期需在原型与协议实测后重新估算。")
    add_table(doc, ["阶段", "交付", "退出条件"], [
        ("P0 产品与权限基线", "四条关键流程的可点击原型；重排主导航/窗口；明确工作区与数据所有权；修正/移除手写 LaunchAgent；第三方库与许可证审查。", "一名网络工程师能在原型中完成告警到证据流程；启动、退出和登录项行为符合无隐藏服务原则。"),
        ("P1 资产上下文底座", "Workspace / Site / Subnet / Device / CredentialRef / DiagnosticRun 模型；本地搜索、筛选、导入与备份；设备详情检查器；Keychain 凭据 CRUD。", "从设备详情可启动 Ping、DNS、TCP、Traceroute、SNMP；重开应用后资产、凭据引用和运行历史正确恢复。"),
        ("P2 可观测性连接", "只读 NetBox、Zabbix 或 LibreNMS 连接器中的一个先完成纵向切片；状态新鲜度、告警队列、同步来源；SNMPv3 GET/WALK。", "连接器可断线恢复且不重复资产；SNMPv3 覆盖 RFC 向量、超时、错误凭据、引擎重启及多品牌设备。明确现状是“实时连接”还是“周期采集”。"),
        ("P3 排障与证据链", "诊断任务统一控制、取消、参数快照、结果标签、导出报告；运行历史可按环境/设备/时间查询。", "用户可从告警复现同一组检查；导出可脱敏、包含时间/来源/目标与错误阶段；失败和拒绝权限不伪装成离线。"),
        ("P4 远程会话与受控操作", "先把 SSH 主机会话做成应用内标签工作流；评估维护中的 SSH/SFTP Swift 库、许可证和安全记录；known_hosts 首次确认/变更告警；常用无副作用命令模版。", "没有绕过主机密钥校验；写操作显示目标、命令/差异、影响范围，明确确认后运行；操作记录不泄漏凭据。RDP/VNC 继续显式交给用户安装的客户端。"),
        ("P5 稳定与正式分发", "自动构建 arm64/x86_64 与 Universal；自动化核心协议测试、GUI 冒烟、签名验证、Notary 提交/日志、staple、DMG 安装/升级/卸载回归；隐私说明与支持包脱敏。", "在最低支持 macOS 与当前 macOS 版本通过安装、权限拒绝恢复、升级、退出清理；Gatekeeper 首次运行不需用户绕过；无遗留进程、LaunchAgent、临时授权或日志秘密。"),
    ], widths=[1.15, 3.45, 2.4], font_size=7.9)

    add_heading(doc, "推荐首发 MVP", 2)
    add_bullet(doc, "运维工作区主窗口重做：全局环境、资产上下文、异常队列、设备检查器、可重跑任务和操作历史。")
    add_bullet(doc, "本地资产/子网管理与 Windows profile 导入；凭据由 Keychain 管理，导出默认不含秘密。")
    add_bullet(doc, "基于设备直接触发 Ping、DNS、TCP、Traceroute 与 SNMP 读操作；保存诊断时间、参数、来源、结果和新鲜度。")
    add_bullet(doc, "一项只读外部集成先做端到端验证，优先根据目标客户现有部署选择 NetBox 或 Zabbix/LibreNMS，不假设客户同时运行全部系统。")
    add_bullet(doc, "默认前台运行、退出无后台服务；Developer ID 签名、公证、Universal DMG 和升级/移除检查。")

    add_heading(doc, "首发明确不包含", 2)
    add_text(doc, "自建 24/7 NMS 服务端、隐藏常驻 daemon、内置 BPF 抓包授权组件、自动修改 NetBox/NMS 权威数据、无确认批量变更、强制捆绑 Homebrew/Python/PowerShell/RDP/VNC 服务。")

    add_heading(doc, "6. 首月执行顺序")
    add_table(doc, ["时段", "工作", "可评审产物"], [
        ("第 1 周", "重做信息架构与设备页原型；验证告警处理、子网排查、设备接入、远程会话四条路径；明确默认无服务约束。", "可点击 SwiftUI 原型；每条流程有开始/完成/错误状态；P0 决策记录。"),
        ("第 2 周", "定义环境、站点、设备、接口、地址、凭据引用、检查运行的数据模型与来源字段；实现环境上下文贯穿导航。", "可搜索资产表和详情页；结构化数据迁移/导入格式；Keychain 冒烟。"),
        ("第 3 周", "把已有 Ping、DNS、TCP、Traceroute 工具接到已选设备；统一取消、超时、错误状态、结果时间和记录存储。", "从设备页完整发起与回看一次诊断；敏感字段导出与日志检查。"),
        ("第 4 周", "挑一项真实 API 集成做只读纵向切片；整理 SNMPv3 实现拆解与设备矩阵；在 macOS 14 和 macOS 15+ 做本地网络权限回归。", "连接器演示、兼容性清单、阶段风险与更新后的 P2 估算。"),
    ], widths=[0.85, 3.65, 2.5], font_size=8.3)
    add_text(doc, "首月不是产品发布日期承诺。以上假设有一名主要开发者可持续投入，并能访问至少一个真实 NetBox/Zabbix/LibreNMS 实例和 SNMP 设备；若缺少测试设备，协议兼容性仍未验证。", after=6, color=MID, size=8.8)

    add_heading(doc, "7. 风险和发布门槛")
    add_table(doc, ["风险", "应对 / 完成判据"], [
        ("错误扫描或变更扩大影响", "扫描前显示目标数量与范围；默认小范围；高并发和写操作单独确认；记录目标集与最终结果。"),
        ("资产值与现场状态冲突", "保留数据源、拉取时间、用户修改和运行观察；不自动覆盖 NetBox；用“设计 / 观测 / 未知”三种状态。"),
        ("凭据意外泄漏", "Keychain ACL；UI/日志/崩溃报告/导出统一脱敏；测试 profile、数据库和诊断包均无秘密值。"),
        ("权限拒绝导致误判", "局域网首次授权先解释；拒绝、系统不支持、超时分别显示；提供打开系统设置与重试指引；macOS 14 和 15+ 分别测。"),
        ("登录项或 helper 破坏独立运行", "V1 仅主应用登录项；没有 agent/daemon；安装、关闭开机启动、卸载后清理均以文件系统和进程检查验证。抓包 helper 不随包静默安装。"),
        ("不同品牌设备 SNMPv3 差异", "按算法、security level、engine ID/time、packet loss、tooBig、分页 walk 建协议矩阵；标准向量通过不代表所有设备兼容。"),
        ("发布包信任失败", "配置真实 Developer ID 身份与 secure CI secret；启用 Hardened Runtime；提交 notarytool、审查日志并 staple；验证嵌套代码和全新用户首次安装。"),
    ], widths=[1.6, 5.4], font_size=8.2)

    add_heading(doc, "完成定义")
    add_bullet(doc, "用户能仅通过 GUI 完成核心工作流；错误、空数据、权限拒绝、取消、超时和失联都有不同且可恢复的状态。")
    add_bullet(doc, "数据行始终能说明来源与时间；每次探测都有可重现参数；未知不会被渲染成正常。")
    add_bullet(doc, "没有需要安装的项目专用 daemon；主应用退出后进程与临时任务清理；登录项 opt-in 且由系统显示/管理。")
    add_bullet(doc, "凭据默认进入 Keychain；测试证明不会出现在日志、导出、诊断包或窗口标题。")
    add_bullet(doc, "协议核心具备单元/互操作测试；正式 DMG 经过真实签名、公证、安装/升级/移除和 Gatekeeper 首次运行验证。")

    doc.add_page_break()
    add_heading(doc, "8. 研究来源")
    add_text(doc, "在线资料在 2026 年 11 月 3 日核验。优先使用 Apple、项目官方文档与 IETF RFC。来源支持平台约束和系统职责判断；产品定位、阶段顺序、MVP 边界与工期仍属于工程建议。")
    sources = [
        (1, "TN3179: Understanding local network privacy", "Apple Developer", "https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy", "macOS 15 本地网络授权、用途说明键、权限拒绝后的连接行为"),
        (2, "Network framework", "Apple Developer", "https://developer.apple.com/documentation/network", "应用层 TCP/UDP/TLS、Network connections/listeners/browser API 能力边界"),
        (3, "SMAppService", "Apple Developer", "https://developer.apple.com/documentation/servicemanagement/smappservice", "使用系统 API 注册主应用登录项或 helper；替代直接安装 launchd plist"),
        (4, "Using the keychain to manage user secrets", "Apple Developer", "https://developer.apple.com/documentation/security/using-the-keychain-to-manage-user-secrets", "密码与令牌的系统安全存储建议"),
        (5, "Introduction to NetBox", "NetBox Documentation", "https://netbox.readthedocs.io/en/stable/introduction/", "NetBox 的 IPAM/DCIM 职责、非监控定位、desired state / source-of-truth 原则"),
        (6, "REST API Overview", "NetBox Documentation", "https://netbox.readthedocs.io/en/stable/integrations/rest-api/", "token scope、只读令牌、分页、API 权限与变更日志能力"),
        (7, "Auto-Discovery Support", "LibreNMS Documentation", "https://docs.librenms.org/Extensions/Auto-Discovery/", "SNMP 凭据与自动发现机制"),
        (8, "LibreNMS product overview", "LibreNMS", "https://www.librenms.org/", "CDP/FDP/LLDP、OSPF/BGP、SNMP、ARP 发现、告警、API 与分布式轮询能力"),
        (9, "Network discovery", "Zabbix Documentation", "https://www.zabbix.com/documentation/current/en/manual/discovery/network_discovery", "周期 IP 范围和服务/SNMP 发现；文档明确该机制不发现网络拓扑"),
        (10, "SNMP agent", "Zabbix Documentation", "https://www.zabbix.com/documentation/current/en/manual/config/items/itemtypes/snmp", "SNMP v1/v2/v3 配置项及设备/库差异，辅助建立兼容测试矩阵"),
        (11, "RFC 3414: User-based Security Model for SNMPv3", "RFC Editor / IETF", "https://www.rfc-editor.org/rfc/rfc3414.html", "SNMPv3 USM 架构、认证/隐私、engine boots/time 与 timeliness synchronization"),
        (12, "RFC 7860: HMAC-SHA-2 authentication protocol for SNMP USM", "RFC Editor / IETF", "https://www.rfc-editor.org/rfc/rfc7860.html", "SNMPv3 USM SHA-2 认证算法协议依据"),
        (13, "Notarizing macOS software before distribution", "Apple Developer", "https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution", "Developer ID 分发、公证与 Gatekeeper 信任票据；notarization 不等于 App Review"),
        (14, "Installing Wireshark under macOS", "Wireshark User's Guide", "https://www.wireshark.org/docs/wsug_html_chunked/ChBuildInstallOSXInstall.html", "macOS 抓包要求额外安装 ChmodBPF launch daemon 的直接证据"),
    ]
    for source in sources:
        add_source(doc, *source)

    add_heading(doc, "本地核验范围", 2)
    add_text(doc, "本版具体依据仓库当前内容：macos/Package.swift、macos/Resources/Info.plist、macos/Sources/NMApp/main.swift、macos/Sources/NMCore/Settings.swift、macos/Sources/NMCore/Profiles.swift、macos/Scripts/build-app.sh、macos/PORTING_STATUS.md 与 macos/README.md。若这些文件继续演进，路线基线需随之更新。", after=6, size=9)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    doc.save(OUTPUT)
    print(OUTPUT)


if __name__ == "__main__":
    build()
