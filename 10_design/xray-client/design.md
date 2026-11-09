# 方案 A：xray-core + 本地配置文件 + systemd user service 设计

- 版本：1.1.2（实现完成，待实机验收 T4～T16）
- 日期：2026-10-24
- 范围：Fedora 44 / GNOME / 单节点（自建香港服务器，VLESS + REALITY + Vision）
- 关联文档：[VPN/AGENTS.md](../../AGENTS.md)、[proxy-ctl/DESIGN.md](../../../proxy-ctl/DESIGN.md)

设计与实现均已落地，实现文件在本目录；T4～T16 的实机验收尚未执行，结果记入第 13 节。

---

## 1. 目标与非目标

### 目标

1. 不再依赖 v2rayN 图形界面：开机后由 systemd user service 直接运行 xray 内核，配置来自本地 JSON 文件。
2. 保持现有生态不变：监听 `127.0.0.1:10808`，GNOME 系统代理仍为 `manual`；`proxy-ctl` 的判断逻辑无需改动（只需更新提示文案）。
3. 把“配置文件由谁负责”这件事工程化：任何配置改动都必须先通过校验、可回滚、失败有明确提示。
4. 对第 5 节的每一条风险都有一个可执行、可验证的控制点，而不是只写在文档里。
5. 更新安全优先：只接受官方来源、满冷却期、哈希核对、证据落盘的稳定版；禁止追最新。

### 非目标

- 不做 TUN / 透明代理（本机运行 Tailscale 与 Docker，改路由的风险高于收益）。
- 不做多节点、订阅、自动测速、故障切换；只保留自建节点。
- 不替代 `proxy-ctl`，也不接管它的环境变量逻辑。
- 不支持 macOS / Windows；本设计只针对当前这台 Fedora。
- 不做流量统计、连接数面板、Web UI。
- 不做自动更新，也不做联网版本检查（用户明确不需要 `upgrade --check`）。

---

## 2. 现状与约束（已实测）

| 项 | 实测值 |
|----|--------|
| 发行版 | Fedora Linux 44 (Workstation) |
| 现有 GUI | v2rayN `7.24.1` rpm，`/opt/v2rayN/v2rayN`，经 `~/.config/autostart/v2rayN.desktop` 自启 |
| 内核 | Xray `26.10.10`，`~/.local/share/v2rayN/bin/xray/xray`（静态链接，无动态依赖） |
| 现用配置 | `~/.local/share/v2rayN/binConfigs/config.json`（v2rayN 生成，直接可用） |
| 入站 | mixed（HTTP + SOCKS），当前 `0.0.0.0:10808`，`udp: true` |
| 出站 | 单条 VLESS + REALITY，`flow: xtls-rprx-vision` |
| 分流 | DNS 模块 + `geosite:telegram/google/cn/private`、`geoip:cn` 等规则，依赖 `geoip.dat` / `geosite.dat` |
| 系统代理 | GNOME `mode=manual`，http/https/socks 四个槽位均为 `127.0.0.1:10808` |
| `proxy-ctl` | 每个交互式 shell 读 gsettings，端口通则导出代理变量，不通则清空并告警 |
| 工具链 | systemd 259 / jq 1.8.1 / curl / Bash 5.3（均已具备；shellcheck 未安装） |
| systemd | `Linger=yes`（用户级服务可随开机启动） |
| SELinux | `Disabled` |
| 已装但未用 | `v2raya`（disabled）、`/usr/local/bin/clash 1.18.0`（旧版 Clash，不支持 VLESS，不可用） |
| 已验证 | 现配置 `xray run -test` 通过；改 `listen` 为 `127.0.0.1` 后在 18080 端口实跑，出口 IP 为服务器 IP |

关键结论：v2rayN 生成的 JSON 本身就是完整的 xray 客户端配置，迁移不需要重写协议参数，只需要接管生命周期、绑定地址和资产路径。

---

## 3. 总体设计

### 3.1 架构

```
                    ┌──────────────────────────────┐
                    │  GNOME 系统代理 (dconf)       │
                    │  mode=manual                  │
                    │  http/https/socks → :10808    │
                    └──────────────┬───────────────┘
                                   │ 只读
                    ┌──────────────▼───────────────┐
                    │  proxy-ctl (~/.bashrc)        │
                    │  端口通 → 导出环境变量        │
                    │  端口不通 → 清空 + 告警       │
                    └──────────────────────────────┘

  ┌────────────────────┐        ┌─────────────────────────────┐
  │ vpnctl (bash)      │        │ systemd --user               │
  │ on/off/status/edit │───────▶│ xray-client.service          │
  │ 改 gsettings       │        │  ExecStart: xray run -c <c>  │
  └─────────┬──────────┘        │  Restart=always              │
            │                   └──────────────┬──────────────┘
            │                                  │ 127.0.0.1:10808
            │                   ┌──────────────▼──────────────┐
            │                   │  应用（浏览器等，走系统代理）│
            │                   └─────────────────────────────┘
            │
  ┌─────────▼──────────┐        ┌─────────────────────────────┐
  │ ~/.config/xray/    │        │ vpn-health.timer (3 min)     │
  │ config.json (600)  │        │  → vpnctl check --quiet      │
  └────────────────────┘        │  → ~/.local/state/vpn/       │
                                └─────────────────────────────┘
```

### 3.2 职责边界

| 组件 | 负责 | 不负责 |
|------|------|--------|
| `xray-client.service` | 运行内核、失败自动重启 | 不改系统代理、不做健康判断 |
| `vpnctl` | 安装、校验、开关、状态、编辑、回滚、升级 | 不实现协议、不解析流量 |
| `vpn-health.timer` | 定期真实探测、记录状态、状态翻转时通知 | 不自动改代理（除非显式开启 `AUTO_OFF`） |
| GNOME 系统代理 | 给“遵守系统代理”的应用提供出口 | 不覆盖自带代理设置的应用 |
| `proxy-ctl` | 终端环境变量跟随 gsettings | 不管理系统代理开关 |

### 3.3 设计决策与理由

| 编号 | 决策 | 理由 | 被否方案 |
|------|------|------|----------|
| D1 | 继续用 xray 内核，沿用 v2rayN 生成的配置，只改 `listen` | 协议参数已验证可用，迁移面最小 | 换 mihomo/sing-box 需重写配置并重新验证 REALITY 参数 |
| D2 | user service，不用 root | 端口 >1024、无需 TUN；降低权限面 | system service 需要 root，且与桌面用户配置耦合 |
| D3 | 固定端口 10808 | 与现有 gsettings、`proxy-ctl` 完全兼容 | 换端口需要同步多处，收益为零 |
| D4 | 代理开关继续用 gsettings | 浏览器和 GNOME 应用只认系统代理；`proxy-ctl` 已对接 | 自建环境变量注入只覆盖终端 |
| D5 | 不做 TUN | 本机 Tailscale + Docker 路由复杂，TUN 的故障面远大于收益 | TUN 透明代理 |
| D6 | 健康检查用外部 timer | Xray 不支持 `sd_notify`，systemd `WatchdogSec` 无法感知隧道是否可用 | `WatchdogSec`（只能发现进程卡死） |
| D7 | 默认不自动关代理，只通知 | 自动关代理 = 静默回落直连，与“代理应当显式可控”冲突；可用性优先者可通过 `AUTO_OFF=1` 显式选择 | 失败即自动 `off` |
| D8 | 内核与资产版本化，不自动联网下载 | 避免升级/供应链把可用配置弄坏；更新必须是一次显式动作 | 启动时自动拉取 geo 文件 |
| D9 | 单节点，不做 failover | 用户明确只保留自建节点；失败时快速 `off` 比复杂切换更可靠 | 多节点策略组 |
| D10 | 仓库只放模板，真实配置只在本机 | 凭据零落盘到仓库（AGENTS 硬性要求） | 配置文件入库 |
| D11 | 更新只选“最近的稳定版”，并做供应链核查 | 代理是网络入口；追新和第三方转存是投毒/回归的主要入口。用 60 天冷却 + 官方来源 + SHA256 + 证据文件约束 | 追 `latest` / 自动更新 |

---

## 4. 文件布局

### 4.1 仓库（本目录）

```
VPN/10_design/xray-client/
├── design.md                  # 本文档
├── config.example.json        # 占位模板，不含任何真实凭据
├── xray-client.service        # 单元文件（与第 6.8 节逐字一致）
├── vpn-health.service         # 健康探测单元
├── vpn-health.timer           # 3 分钟定时器
├── vpnctl.sh                  # 唯一入口脚本（含 install 子命令）
├── geo-manifest.py            # 读 geosite.dat/geoip.dat 的代码清单（无依赖）
├── test_vpnctl.sh             # 离线验收测试（mock systemd/gsettings/curl）
├── test_live.sh               # 实机 T9/T7/T8（会短暂断网，失败自动恢复）
└── README.md                  # 安装、日常命令、更新与故障处理
```

按全局 AGENTS 第十一节，shell 代码集中在 `vpnctl.sh` 一个文件，不按功能拆多个脚本；单元文件是配置而非代码，按 systemd 要求分文件。

### 4.2 运行期（不进仓库）

| 路径 | 权限 | 用途 |
|------|------|------|
| `~/.config/xray/config.json` | 0600 | 唯一事实源（含 UUID / publicKey / shortId） |
| `~/.config/xray/` | 0700 | 目录 |
| `~/.local/share/xray/geoip.dat` | 0644 | 分流资产 |
| `~/.local/share/xray/geosite.dat` | 0644 | 分流资产 |
| `~/.local/lib/xray/<version>/xray` | 0755 | 版本化内核 |
| `~/.local/lib/xray/current` | 符号链接 | 指向当前版本 |
| `~/.local/bin/xray` | 符号链接 | 指向 `current` |
| `~/.local/bin/vpnctl` | 0755 | 入口脚本副本 |
| `~/.config/systemd/user/xray-client.service` | 0644 | 内核单元 |
| `~/.config/systemd/user/vpn-health.service` | 0644 | 探测单元 |
| `~/.config/systemd/user/vpn-health.timer` | 0644 | 定时器 |
| `~/.local/state/vpn/health.json` | 0600 | 最近一次探测结果 |
| `~/.local/state/vpn/assets.json` | 0600 | geo 资产的日期与哈希 |
| `~/.local/state/vpn/upgrades/` | 0700 | 每次升级/基线核验的证据文件 |
| `~/.local/state/vpn/autostart-disabled` | 0600 | 记录被改名的 v2rayN 自启路径 |
| `~/.local/state/vpn/staging/` | 0700 | 安装暂存（校验通过后清理） |
| `~/.local/state/vpn/backups/` | 0700 | 配置与资产的时间戳备份 |
| `~/.config/vpn/vpn.conf` | 0644 | 可选开关（`AUTO_OFF` 等） |

---

## 5. 风险控制矩阵

| 编号 | 风险 | 控制点 | 验证方式 |
|------|------|--------|----------|
| R1 | 入站暴露到 LAN / Tailscale | 配置策略强制 `listen == 127.0.0.1`；`validate` 拒绝 `0.0.0.0`；`on` 后 `ss` 复核 | 负向测试：`0.0.0.0` 配置必须被拒 |
| R2 | 进程活着但隧道已死 | 3 分钟 `vpn-health.timer` 做真实 HTTPS 204 探测（同轮 5 秒重试一次）；首轮失败即通知；`status` 显示最近结果 | 停掉服务后 3 分钟内状态变 fail 且收到通知 |
| R3 | 代理开着但内核挂了，全系统断网 | `on` 顺序：先起服务→端口→真实探测→通过才开代理；`off` 顺序：先关代理→再停服务；失败恢复原代理状态；`status` 检测不一致 | 模拟启动失败，代理状态必须保持原样 |
| R4 | 缺 `geoip.dat/geosite.dat` 导致启动失败 | 资产复制到固定目录；单元内设 `XRAY_LOCATION_ASSET`；`validate` 检查文件存在且非空 | 移走资产后 `validate` 必须失败（已复现 xray 报错） |
| R5 | 迁移期 v2rayN 抢占 10808 / 退出时重置代理 | `install` 检查 v2rayN 进程并提示；可选改名自启动；`on` 前检查端口占用者；`on` 后重设 gsettings；`status` 报告 v2rayN 进程 | 同时启动两者，第二个必须给出明确报错 |
| R6 | 手改配置写错，服务起不来 | `edit` 流程：临时文件 → JSON 语法 → `xray -test` → 策略断言 → 备份 → 安装 → 重启 → 健康检查 → 失败自动回滚 | 注入坏 JSON / 坏端口，必须原样恢复 |
| R7 | geo 数据过期，CN 直连规则漂移 | `status` 显示资产日期与哈希；超过 90 天告警；`update-geo` 显式更新并做重启前后校验 | 用旧资产运行 `status`，必须出现告警 |
| R8 | 内核升级把配置弄坏 / 升到不稳定版本 | 只选官方稳定版 + 60 天冷却；版本目录 + `current`；新二进制 `-test`；升级后真实探测；失败切回 | 预发布/过新版本被拒；坏二进制回滚 |
| R9 | 凭据落盘 / 泄露 | 配置 0600、目录 0700；仓库只有占位模板；`status` 只显示 SHA256 前缀；`install` 从本机生成配置读取，不打印内容 | `test_vpnctl.sh` 扫描 `10_design/xray-client/` 与 `20_assets/`，不得出现 UUID 形态字符串 |
| R10 | 用户以为“全都走代理了” | 文档明确非目标；`status` 显示“系统代理模式”；故障卡说明哪些应用不受控 | 验收测试覆盖“代理开启但服务停止”的场景 |
| R11 | 没有 GUI，状态不可见 | `status` / `check` / `ip` / `logs` 四个子命令；`status` 不联网、秒级返回 | 断网时 `status` 仍必须可用 |
| R12 | 注销后服务停止 / 开机未启动 | 已有 `Linger=yes`；`enable` 单元；验收包含重启 | 重启后 `is-active` 为 active |
| R13 | 卸载 v2rayN 带走内核与资产 | `install` 复制到独立目录，不引用 `/opt/v2rayN` | 移走 `/opt/v2rayN` 后服务仍可重启 |
| R14 | 故障后没有日志 | 默认 `warning` 级别写 journald；`logs` 子命令；本机 `/var/log/journal` 已存在，日志落盘、重启后仍可查 | `journalctl --user -u xray-client` 有记录 |
| R15 | 上游投毒 / 供应链攻击 | 只从官方 Releases 下载；禁止 `latest`、预发布、第三方转存；发布满 60 天；SHA256 强制核对；证据文件落盘；首次基线用官方同版本产物并记录哈希 | `upgrade` 缺参数/哈希不符/版本过新必须拒绝；证据文件存在 |

---

## 6. 控制点详细设计

### 6.1 安装（`vpnctl install`）

```
vpnctl install [--dry-run] --xray <path> --xray-sha256 <hex>
               [--xray-source <url>]
               [--from-config <config.json>] [--from-assets <dir>]
               [--disable-v2rayn-autostart]
```

前置检查（环境类失败退出码 5；参数缺失退出码 2）：

1. 基线内核必须显式提供：`--xray <官方二进制>` + `--xray-sha256 <hex>`；任一缺失退出 2，并提示去官方 Releases 下载、自行核对。**不再默认使用 v2rayN 自带内核**。`--dry-run` 只打印计划，不要求文件已存在。
2. 源配置存在（默认 `~/.local/share/v2rayN/binConfigs/config.json`，可用 `--from-config` 覆盖），并且必须通过 6.2 的 VLESS+REALITY 策略；若 v2rayN 当前活动的是订阅里的 Trojan 节点，先在 GUI 中选中自建 `HK-REALITY`，等配置重新生成。资产目录存在且两份文件 > 1 MB（默认 `~/.local/share/v2rayN/bin`，可用 `--from-assets` 覆盖）。
3. 目标目录可写；磁盘剩余空间 > 100 MB。
4. 若检测到 v2rayN 进程，打印“迁移期间请先退出 v2rayN”，但不自动杀进程。
5. 若 10808 已被占用，打印占用者 PID/命令；安装阶段只警告，不中止（此时服务尚未启动）。
6. 命令依赖 `jq`、`curl`、`ss`、`systemctl`、`gsettings` 必须存在；任一缺失退出 5（本机已全部具备）。

动作（幂等，`--dry-run` 只打印不执行）：

1. 创建目录并设权限（`~/.config/xray` 0700，state 与 `upgrades/` 0700）。
2. 核对 `--xray-sha256`；复制内核到 `~/.local/lib/xray/<version>/xray`，重建 `current` 与 `~/.local/bin/xray` 符号链接；写基线证据 `~/.local/state/vpn/upgrades/baseline-<版本>.md`（版本、SHA256、来源 URL（`--xray-source`，可选）、两份资产的 SHA256、日期）。
3. 从 `--from-assets` 复制 `geoip.dat`、`geosite.dat` 到 `~/.local/share/xray/`。
4. 读源配置，用 jq 把 mixed 入站的 `listen` 改为 `127.0.0.1`，写临时文件；用刚安装的新二进制跑完整校验（6.2）；通过后备份旧配置（若存在），以 0600 安装到 `~/.config/xray/config.json`。
5. 安装 `vpnctl` 到 `~/.local/bin/vpnctl`（0755）。
6. 写三个单元文件，`systemctl --user daemon-reload`，`enable xray-client.service vpn-health.timer`（**不启动**，避免与 v2rayN 抢端口）。
7. 可选 `--disable-v2rayn-autostart`：把 `~/.config/autostart/v2rayN.desktop` 改名为 `.disabled`，并在 state 目录记录，供 `uninstall` 恢复。
8. 输出下一步：退出 v2rayN → `vpnctl on` → 验证。

安装原子性：新内核、配置、资产先在 `~/.local/state/vpn/staging/` 准备并完成校验；全部通过后才切换 `current`、安装配置与资产、`daemon-reload`、`enable`。中途失败恢复旧链接与旧配置，不启动服务。

### 6.2 配置校验（`vpnctl validate [file]`）

三段式，全部通过才算通过：

1. JSON 语法：`jq empty "$cfg"`。
2. xray 自检：`XRAY_LOCATION_ASSET=~/.local/share/xray xray run -test -c "$cfg"`。
3. 安全与兼容策略（jq 断言，逐字如下）：

```bash
jq -e '
  (.inbounds | length) > 0
  and ([.inbounds[] | select(.protocol == "mixed" and (.port|tostring) == "10808")] | length) == 1
  and ([.inbounds[] | select((.port|tostring) == "10808")][0].listen) == "127.0.0.1"
  and ([.inbounds[] | select(.listen == "0.0.0.0")] | length) == 0
  and ([.inbounds[] | select(.tag != "ts-in" and .listen != "127.0.0.1")] | length) == 0
  and ([.inbounds[] | select(.tag == "ts-in" and (.protocol != "mixed" or (.port|tostring) != "10809" or .listen != "127.0.0.1"))] | length) == 0
  and ([.routing.rules[]? | select((.inboundTag // []) | index("ts-in"))] | length)
      == ([.inbounds[] | select(.tag == "ts-in")] | length)
  and ([.outbounds[] | select(.protocol == "vless")] | length) >= 1
  and ([.outbounds[]
        | select(.protocol == "vless")
        | select(((.streamSettings.realitySettings.publicKey // "") | length) == 0
                 or ((.streamSettings.realitySettings.shortId // "") | length) == 0
                 or .settings.vnext[0].users[0].flow != "xtls-rprx-vision")]
       | length) == 0
' "$cfg"
```

`>= 1` 而不是 `== 1`（2026-11-09 起）：2026-11-05 加入了第二个 VLESS 出站
（`proxy-ts`，走 tailnet），旧断言要求“恰好一个”，于是从那天起 `validate` 一直拒绝
真实配置 —— 连带 `restart`、`edit`、`install` 全部不可用，而没人发现。现在要求
至少一个，并且每一个都必须是 REALITY + Vision、公钥与 shortId 非空。

另加文件检查：`geoip.dat`、`geosite.dat` 存在且大于 1 MB。

**诊断入站 `ts-in`（2026-11-09）**：`127.0.0.1:10809`，mixed 协议，唯一用途是让
`vpnctl check` 有一条**只走 `proxy-ts`** 的路径。路由首条是
`inboundTag: ["ts-in"] → proxy-ts`，因此它不受 Telegram 域名规则变化的影响。
策略断言要求：额外入站必须绑 `127.0.0.1`、`ts-in` 必须是 mixed 且端口 10809、
`ts-in` 入站与引用它的路由规则必须同时存在或同时不存在。
`check` 经 10809 请求 `https://api.telegram.org/`（2xx/3xx 记为 ok），
把 `ts_state`/`ts_ms`/`ts_code` 写进 `health.json`；`status` 的 `egress` 行显示结果。
**这条探针失败不会把整体健康判为 fail**（否则 `AUTO_OFF` 会因为 Telegram 一条路断了
而关掉全部代理），只在 `status` 里给出 warn。

**geo 代码清单（2026-11-09）**：`geo-manifest.py` 用最小 protobuf 读取器列出
`geosite.dat` / `geoip.dat` 里真实存在的代码，结果写在
`~/.local/state/vpn/geo-codes/{geosite,geoip}.txt`；`install`、`update-geo`、
`vpnctl geo-manifest` 会重建它。`validate` 在 xray `-test` 失败后用它把出错代码
点出来（`unknown geosite/geoip code(s): geosite:office`），而不是只回一句
"xray config test failed"。清单只用于解释失败，不会单独否决一个 xray 已接受的配置
—— 解析不到的构建最多标错原因，不会挡住能用的配置。

输出只打印结论与哈希前缀（例如 `config sha256:ab12cd34`），**不打印配置内容**。退出码：0 通过，2 不通过。

### 6.3 开关（`vpnctl on` / `off`）

`on`：

1. 前置：若 10808 已被非 `xray-client` 进程占用 → 中止（退出码 5），打印占用者并提示退出 v2rayN。
2. 记录当前 `org.gnome.system.proxy mode`，供失败恢复。
3. `systemctl --user reset-failed xray-client`（忽略错误）→ `start`。
4. 等端口就绪（50 × 100 ms）；超时则恢复原代理模式并退出 3。
5. 真实探测（6.4 的 204 检查）；失败则恢复原代理模式、退出 4。
6. 探测通过后才写 gsettings：http / https / socks / ftp 四个槽位 host/port → `mode=manual`。
7. 打印 `status` 摘要。

`off`：

1. 先 `gsettings set org.gnome.system.proxy mode 'none'`（先关代理，避免“代理指向死端口”的窗口）。
2. `systemctl --user stop xray-client`。
3. 打印结果；`off` 不停止 timer（timer 检测到代理已关会跳过）。

两个命令都幂等：重复执行不报错。

### 6.4 健康检查与状态

**判据**：服务 active + 端口可连 + 经代理请求 `https://www.gstatic.com/generate_204` 返回 204。三项全过才算 ok。该 URL 已实测经当前代理返回 204（耗时约 0.33 s）。

探测命令必须显式绕开 shell 里的代理环境变量（本机常年有 `http_proxy` / `all_proxy`，否则 curl 会二次代理）：

```bash
env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -s -o /dev/null -w '%{http_code}' \
    --noproxy '' -x http://127.0.0.1:10808 \
    -m 8 https://www.gstatic.com/generate_204
```

期望输出 `204`。出口 IP 用同一模式请求 `https://api.ipify.org`，仅在成功时写入 `health.json`。

**定时器**：`vpn-health.timer` 每 3 分钟触发一次 `vpnctl check --quiet`。选 3 分钟是因为：足够快发现断线，又不会把探测流量做成负担。每轮探测失败后在同轮内 5 秒重试一次，所以从故障发生到通知的最大延迟约 3 分钟 + 5 秒；这个窗口在文档中明确写出。

`check` 行为：

- 若 `mode != manual` 且服务未运行 → 记录 `skipped`，静默退出 0。
- 若 `gsettings` 读不到（无 D-Bus / 非 GNOME 会话）→ 记录 `skipped`，静默退出 0，不产生告警。
- 服务 inactive 或端口不通：直接判本轮失败，不再做网络重试。
- 服务 active 且端口通：发 204 探测；失败则 5 秒后重试一次；两次都失败才判本轮失败。
- 本轮成功：写入 `health.json`（时间、HTTP 码、出口 IP），连续失败数归零；若上次是 fail，通知“恢复”。
- 本轮失败：连续失败数 +1；首次失败（0 → 1）立即通知，后续失败不重复通知，避免刷屏。
- `AUTO_OFF=1` 且连续失败达到 2 轮（约 6 分钟）时执行 `off`，并在 `health.json` 记录原因。
- `--quiet` 模式**始终退出 0**，避免 systemd 把探测失败当成单元失败而限流。

`health.json` 示例（0600）：

```json
{
  "ts": "2026-10-24T11:20:00+08:00",
  "result": "ok",
  "fails": 0,
  "service": "active",
  "port": true,
  "proxy_mode": "manual",
  "http_code": 204,
  "exit_ip": "<SERVER_IP>",
  "last_notify": "2026-10-24T09:00:00+08:00"
}
```

`status`（不联网、秒级）输出：

```
service : active (running) since 2026-10-24 10:55:12 CST
port    : 127.0.0.1:10808 listening (pid 12345)
proxy   : manual -> 127.0.0.1:10808
health  : ok, 2 min ago, http 204, exit <SERVER_IP>
config  : /home/<user>/.config/xray/config.json 600 sha256:ab12cd34 2026-10-24 11:02
xray    : 26.10.10 (current)
geo     : geoip.dat 2026-10-11 sha256:ef56ab78 / geosite.dat 2026-10-11 sha256:9a0b1c2d
v2rayN  : not running
warn    : none
```

若 `proxy=manual` 但端口不通，最后一行必须显式告警；若检测到 v2rayN 进程，也必须列出。

### 6.5 配置编辑与回滚（`vpnctl edit` / `rollback`）

`edit`：

1. `mktemp` 建 0600 临时文件，复制当前配置，用 `${EDITOR:-vi}` 打开。
2. 内容无变化 → 退出 0。
3. 对临时文件跑 6.2 全量校验；不通过 → 退出 2，正式配置一个字节都不动。
4. 备份当前配置到 `~/.local/state/vpn/backups/config-<时间戳>.json`（0600）。
5. 安装新配置（0600）→ `restart` → 等端口 → 一次真实探测（失败 5 秒重试）。
6. 全部通过 → 退出 0；任一失败 → 自动恢复备份 → `restart` → 再探测 → 通知 → 退出 4。

`rollback`：取最新备份 → 校验 → 安装 → `restart` → 端口与探测；失败则保留当前配置并报告，不再二次回滚，退出 4。备份保留最近 10 份，超出按时间删除。

### 6.6 版本与资产（`upgrade` / `update-geo`）

`upgrade <path> --sha256 <hex> --released YYYY-MM-DD --source <url> [--security-fix --reason <说明>] [--allow-downgrade]`：

1. 运行 `<新二进制> version` 得到版本号；按 6.9.3 校验参数与版本；不通过退出 2，不改动任何文件。
2. 写证据文件 `~/.local/state/vpn/upgrades/<版本>-<发布日期>.md`（0600）。
3. 安装到 `~/.local/lib/xray/<version>/xray`。
4. 用新二进制对当前配置跑 `run -test`；失败则删除新目录并退出 2。
5. 原子切换 `current`。服务运行中：`restart` → 等端口 → 探测；服务未运行：不自动启动，新版本在下次启动时生效。
6. 失败（仅服务运行中）：切回上一版本 → `restart` → 探测 → 通知 → 退出 4。
7. 成功：保留最近 3 个版本，其余删除；`status` 显示当前版本与证据文件路径。

`update-geo --from <目录> --source <url>`：

1. 检查来源目录里 `geoip.dat`、`geosite.dat` 存在且 > 1 MB；否则退出 2。
2. 算两份文件的 SHA256，备份旧文件到 state 目录。
3. 复制后先用 `xray run -test` 验证新资产；服务运行中再 `restart` → 探测，失败恢复旧文件并重启；服务未运行则只更新文件，不自动启动。
4. 把来源 URL、日期、SHA256 写入 `assets.json`。

设计上不提供联网自动下载：geo 数据是路由正确性的输入，自动更新等于把外部仓库的变更直接接进你的分流规则；需要更新时由用户显式提供文件（来源与校验方式写进 README）。

首次安装的基线内核不再取自 v2rayN，而是由你从官方 Releases 下载后显式提供 `--xray` + `--xray-sha256`。`26.10.10` 不是官方 tag，无法从官方下载；按 6.9.1 的规则选 stable、非 prerelease、发布满 60 天的版本。2026-10-24 的实测选择是 `v26.3.27`：最新 stable `v26.10.21` 仅发布 3 天，其余 26.4～26.9 均标记为 prerelease，而 `v26.3.27` 已满 60 天并通过真实配置的 `-test`。基线也优先满足 60 天；只有找不到兼容的合规版本时才使用 bootstrap 例外，并在证据里写明理由。`install` 不校验版本年龄，但会拒绝预发布并强制 SHA256。

### 6.7 密钥与权限

- 真实配置只存在于 `~/.config/xray/config.json`（0600，目录 0700）。
- 仓库内 `config.example.json` 只含 `<UUID>`、`<PUBLIC_KEY>`、`<SHORT_ID>`、`<SERVER_IP>`、`<SNI>` 占位符。
- `install` 从本机 v2rayN 生成配置读取真实值，不经过仓库、不回显。
- `status` / `validate` 只输出 SHA256 前缀与字段长度，不输出字段值。
- 备份同为 0600。
- 迁移完成后建议把 `~/.config/xray/config.json` 加密备份一份到密码管理器；服务器端可用 `xray x25519 -i <私钥>` 与 `/usr/local/etc/xray/config.json` 重建客户端参数。
- 文档脱敏：`VPN/clash-verge-rev-guide.zh-CN.html` 目前含真实 UUID、shortId、IP、SNI；在 `git init` 之前必须替换为占位符，否则一次误推即泄露。

### 6.8 单元文件（逐字）

`xray-client.service`：

```ini
[Unit]
Description=Xray client (VLESS + REALITY), local-only inbound
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=%h/.local/share/xray
ExecStart=%h/.local/bin/xray run -c %h/.config/xray/config.json
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
UMask=0077

[Install]
WantedBy=default.target
```

说明：

- `Restart=always` + `StartLimitBurst=5`：配置错误时最多重试 5 次后进入 failed，不会被无限重启掩盖。
- 显式关闭代理后再 `stop` 不会触发重启（systemd 区分显式停止与异常退出）。
- v1 只启用 `NoNewPrivileges` / `PrivateTmp` / `UMask` 这三个无副作用项。`ProtectSystem` / `ProtectHome` 会引入“配置读不到 → 服务起不来”的新故障面，列为 P1：先在临时实例上验证，再决定是否加入。
- 不加 `After=network-online.target`：user manager 看不到 system target；xray 只在有请求时出站，开机时网络未就绪不影响监听。
- 该单元已用 `systemd-analyze verify` 校验：除“`~/.local/bin/xray` 尚未安装”这一预期告警外无语义错误。

`vpn-health.service`：

```ini
[Unit]
Description=Probe the local VPN proxy and record health state

[Service]
Type=oneshot
ExecStart=%h/.local/bin/vpnctl check --quiet
```

`vpn-health.timer`：

```ini
[Unit]
Description=Run the VPN health probe every 3 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

### 6.9 更新策略：稳定优先、来源可核查

总原则：**不追最新、不自动更新、不信任第三方转存**。更新是安全动作，不是功能动作；没有明确理由（安全公告、兼容性、必要特性）就不更新。每次更新都必须同时满足：官方来源、满冷却期、哈希核对、证据落盘。

#### 6.9.1 版本选择：不选最新，选“最近的稳定版”

“最近的稳定版”定义为：**满足稳定性门槛的版本里最新的那一个**，不是发布页上最新的那一个。

候选版本必须同时满足：

1. 官方 stable release，版本字符串不含 `pre` / `rc` / `beta` / `alpha` / `nightly`。
2. 距发布日 ≥ `UPGRADE_MIN_AGE_DAYS` 天（默认 60）。
3. 没有已知的、影响本配置（VLESS + REALITY + Vision）的严重回归或未修复安全问题。
4. 优先同 minor 的最新 patch（例如当前 26.10.x，先看 26.10 的最新 patch）；跨 minor 需要额外理由。

因此：**最新版发布不足 60 天时，停在上一稳定版**，哪怕它带新功能。唯一例外是安全修复：当前版本存在被在野利用的高危漏洞、候选版本修复了它，可用 `--security-fix --reason <说明>` 缩短冷却期；哈希、来源、证据仍然一个都不能少，例外必须写进证据文件。

禁止：追 `latest` tag、每日构建、预发布版、第三方打包（网盘、论坛附件、聊天群文件、非官方镜像、发行版第三方源）。v2rayN 自带的内核也不作为升级来源——它的来源无法脱离 v2rayN 独立核对；首次安装只把它当“既有基线”并记录哈希。

#### 6.9.2 升级前的供应链核查清单

逐项做完再执行升级：

1. **来源**：只从 `https://github.com/XTLS/Xray-core/releases` 下载；确认 release 属于官方仓库，tag 指向官方 commit；不用任何转存链接。
2. **资产**：只取 `Xray-linux-64.zip`；核对发布页提供的摘要（若有）与本地 `sha256sum`；文件大小与历史版本同量级；解压后 `xray version` 与 tag 一致。
3. **版本状态**：非预发布；发布满 60 天；没有被官方撤回（tag 与资产仍可访问，release notes 没有撤回声明）。
4. **情报**：读 release notes 与该版本的 issue / 讨论，搜 `CVE`、`regression`、`crash`、`reality`；确认没有影响本配置的已知问题。
5. **可验证性**：官方提供校验文件时必须核对；没有校验文件时，至少保证 HTTPS 来源 + tag 一致 + 本地 SHA256 记录。注意：自己算的 SHA256 只能证明文件完整，不能证明来源可信；来源可信靠官方仓库 + tag 一致性 + HTTPS。要求更高保证时，用官方 tag 从源码构建（需要 Go 工具链），把构建命令与结果写进证据。
6. **证据**：把版本、发布日期、来源 URL、SHA256、release notes 摘要、已知问题、决定理由写进 `~/.local/state/vpn/upgrades/<版本>-<发布日期>.md`（0600）。
7. **观察**：切换后连续 3 次 `check` 通过，再观察 24 小时；旧版本目录保留；不要在升级的同一时间改配置。

#### 6.9.3 工具能强制什么、不能强制什么

命令签名：

```
vpnctl upgrade <path> --sha256 <hex> --released YYYY-MM-DD --source <url> \
                [--security-fix --reason <说明>] [--allow-downgrade]
```

强制项（任一不满足即退出 2，不改动任何文件）：

- 缺 `--sha256`、`--released`、`--source` 任一。
- 版本字符串含预发布标记。
- `--released` 是未来日期。
- 距发布日不足 60 天，且没有同时给出 `--security-fix` 与 `--reason`。
- SHA256 与文件不符。
- 版本号低于当前版本，且没有 `--allow-downgrade`（回滚请用 `vpnctl rollback`；只有明确要回到更旧的稳定版时才用 `--allow-downgrade`，且同样要做完整核查）。
- 版本号等于当前版本 → 拒绝（没有升级意义）。

通过后：写证据 → 安装到版本目录 → 新二进制 `run -test` → 切换 `current`；服务运行中才重启并探测，失败切回；服务未运行则不自动启动。

**工具不能强制的**：你是否真的读过 release notes、是否真的比对过社区反馈。这些只能靠证据文件约束。脚本也**不做联网检查**（用户明确不需要 `--check`），所以它不知道“哪个是最新”；“不追最新”由 60 天冷却门槛 + 人工核查共同保证。这是有意的取舍：不把更新判断交给网络。

#### 6.9.4 GeoFiles

只维护 `geoip.dat` 与 `geosite.dat`。配置引用 `geoip:cn/private/telegram` 与 `geosite:cn/google/private/telegram`；已确认没有引用 `Country.mmdb`、`geoip.metadb`、`geoip-only-cn-private.dat`（前两份是 mihomo/Clash 资产，第三份是本配置未引用的精简 geoip 文件），三份都不需要更新。

- 命令：`vpnctl update-geo --from <目录> --source <url>`。检查两份文件存在且 > 1 MB，算 SHA256，备份旧文件，替换、重启、探测；失败恢复旧文件。来源 URL、日期、SHA256 写入 `assets.json`。
- 选择：只用稳定发布产物，不追每日构建、不在发布当天跟进。geo 没有版本号，冷却期无法用版本判断，用“人工选择 + 记录来源/日期/哈希”代替。
- 风险性质：geo 是数据不是代码，投毒的后果是分流被改（该走代理的走直连，或反之），不是代码执行；来源与哈希 + 人工看 changelog 是主要控制。
- `status` 显示日期与哈希；超过 90 天 warn，只告警不更新。

#### 6.9.5 mihomo、sing-box 与 v2rayN

- mihomo / sing-box 不在方案 A 的运行路径上（服务只执行 `~/.local/bin/xray`），不设更新流程；v2rayN 目录里的副本只在打开 v2rayN 时用，卸载时消失或残留都无所谓（T12）。将来切方案 B，再按同一套“官方来源 + 冷却期 + 哈希 + 证据”补升级命令。
- v2rayN 只作应急 GUI，rpm 正常更新；它更新自带内核不会改 `~/.config/xray/config.json`。不要与服务同时跑（抢 10808）。

### 6.10 失败提示契约

| 失败类型 | 谁发现 | 发现延迟 | 用户看到什么 |
|----------|--------|----------|--------------|
| 进程崩溃 / 配置错 | systemd 重启；连续失败 5 次后 failed | 3 秒起重启；failed 后下一轮探测 | 桌面通知 + `status` 告警 |
| 隧道不可用（服务器被封、握手失败） | 健康 timer 的真实 204 | ≤ 3 分钟 + 5 秒重试 | 桌面通知（首次）+ journal |
| 端口被别的进程占用 | `status` / `on` 前置检查 | 即时（手动） | 终端错误，指出占用者 |
| 开机服务未启动 | timer（`OnBootSec=2min`） | ≤ 2 分钟 + 探测 | 桌面通知 |
| 单个网站连不上 | 应用自身 / xray 日志 | 即时 | 只有应用报错；无全局通知 |
| 手动 `vpnctl on` 失败 | `on` 自己 | 即时 | 终端错误，不打开代理 |

通知通道（按可靠性排序）：

1. `~/.local/state/vpn/health.json`：始终写，重启后仍在，`status` 读取。
2. journal：`logger -t vpn-health`，无图形会话也能查。
3. 桌面通知 `notify-send`：有图形会话时弹出；失败只记 journal，不算错误。
4. 终端：`proxy-ctl` 在新 shell 里发现端口不通时清空变量并在 stderr 告警。

通知内容：标题“VPN 隧道异常”或“VPN 隧道已恢复”，正文含失败类别（服务未运行 / 端口不通 / HTTP 超时）、最后成功时间、建议命令（`vpnctl status`、`vpnctl off`）。不含 UUID、公钥、shortId。

去重：只在状态翻转时发一次；同一状态 30 分钟内不重复。不会每 3 分钟刷屏。默认不自动关代理（D7）；`AUTO_OFF=1` 时连续 2 轮失败（约 6 分钟）自动 `off`，并额外通知“已切回直连”。

---

## 7. `vpnctl` 接口

| 子命令 | 阶段 | 作用 | 退出码 |
|--------|------|------|--------|
| `install [--dry-run] --xray P --xray-sha256 H [--xray-source URL] [--from-config P] [--from-assets DIR] [--disable-v2rayn-autostart]` | P0 | 安装文件、校验、enable（不启动） | 0/2/5 |
| `validate [file]` | P0 | 三段式校验 | 0/2 |
| `on` | P0 | 起服务 → 探测 → 开系统代理 | 0/3/4/5 |
| `off` | P0 | 关系统代理 → 停服务 | 0 |
| `restart` | P0 | 校验 → 重启 → 探测 | 0/2/3/4 |
| `status` | P0 | 本地状态摘要（不联网） | 0 |
| `check [--quiet]` | P0 | 真实探测并记录 | 0/4 |
| `ip` | P0 | 经代理查询出口 IP | 0/4 |
| `edit` | P0 | 编辑 → 校验 → 备份 → 重启 → 失败回滚 | 0/2/4 |
| `rollback` | P0 | 恢复最近备份 | 0/2/4 |
| `logs [-f]` | P0 | `journalctl --user -u xray-client` | 0 |
| `upgrade <path> --sha256 H --released D --source URL [--security-fix --reason S] [--allow-downgrade]` | P1 | 门槛校验 + 证据落盘 + 版本化升级 + 失败回滚 | 0/2/4 |
| `update-geo --from <dir> --source URL` | P1 | 资产更新 + 哈希记录 + 失败恢复 | 0/2/4 |
| `uninstall [--purge] [--yes]` | P1 | 停服务、恢复自启动、保留配置；`--purge` 需确认 | 0 |
| `help` | P0 | 用法 | 0 |

全局约定：

- `set -euo pipefail`，所有路径用绝对路径，`PORT=10808`、`PROXY_HOST=127.0.0.1` 为常量。
- 所有写操作先写临时文件再原子替换；失败不留半成品。
- 除 `install` 外，任何子命令不修改单元文件。
- 不使用 `sudo`；需要 root 的动作一律不做。

---

## 8. 故障处置卡

| 症状 | 判定 | 处置 |
|------|------|------|
| `status` 显示 service failed | 配置 / 资产 / 端口问题 | `vpnctl logs` 看最后 100 行；`vpnctl validate`；修复后 `vpnctl restart` |
| service active，端口在听，`check` 失败 | 服务器被封 / 服务器故障 / 密钥轮换 | `vpnctl off` 先恢复直连；SSH 上服务器看 xray 状态与日志；必要时重建参数并 `vpnctl edit` |
| service active，端口不在听 | 端口被占 / 进程崩溃循环 | `ss -tlnp 'sport = :10808'` 看占用者；退出 v2rayN 或改端口（改端口需同步脚本常量） |
| 浏览器打不开，但 `check` 正常 | 该应用不读系统代理 | 预期行为（非目标）；在应用内单独配置代理 |
| 系统代理 manual，但端口不通 | 内核未启动 | `vpnctl on`；若仍失败按第 1 行处理 |
| 开机后服务未启动 | 单元未 enable / linger 失效 | `systemctl --user is-enabled xray-client`；`loginctl show-user "$USER" --property=Linger` |
| 通知发出但用户没看到 | 无图形会话 | 以 `health.json` 与 journal 为准；`status` 不依赖通知 |

---

## 9. 验收测试

| 编号 | 场景 | 操作 | 期望 |
|------|------|------|------|
| T1 | 策略校验正向 | 对安装后的配置跑 `vpnctl validate` | 退出 0，输出含 SHA256 前缀 |
| T2 | 暴露拒绝 | 复制配置并改 `listen=0.0.0.0`，跑 `validate` | 退出 2，明确指出 listen 不合规 |
| T3 | 资产缺失 | 临时移走 `geosite.dat`，跑 `validate` | 退出 2；放回后恢复 0 |
| T4 | 开代理 | `vpnctl off` 后 `vpnctl on` | 服务 active、`127.0.0.1:10808`、gsettings manual、`check` ok |
| T5 | 关代理 | `vpnctl off` | gsettings none、服务 inactive、直连可访问外网 |
| T6 | 崩溃自愈 | `kill -9 $(systemctl --user show -p MainPID --value xray-client)` | 3 秒内新 PID，`check` 恢复 ok |
| T7 | 坏配置 | `vpnctl edit` 写入非法 JSON | 退出 2，正式配置哈希不变 |
| T8 | 坏节点 | 把出站端口改成 1 后保存 | 自动回滚，服务恢复 ok，旧配置哈希不变 |
| T9 | 断线感知 | 服务运行中 `systemctl --user stop xray-client` | 下一轮探测（≤3 分钟）`health.json` 变 fail，只收到一次通知；`vpnctl on` 恢复后再收到一次“恢复”通知 |
| T10 | 重启 | `reboot` 后登录 | 服务 active、代理 manual、`check` ok |
| T11 | 试运行 | `install --dry-run` | 文件哈希快照不变 |
| T12 | 脱管 | 移走 `/opt/v2rayN` 后 `restart` | 服务正常，`status` 不报依赖缺失 |
| T13 | 升级门槛 | 依次用缺 `--sha256`、发布不足 60 天、`pre` 版本、哈希不符的包跑 `upgrade`（P1） | 四次都退出 2，服务与现有文件不变 |
| T14 | 坏资产 | `update-geo --from` 指向缺文件的目录（P1） | 退出 2，服务与现有资产不受影响 |
| T15 | 通知去重 | 连续手动跑 3 次 `vpnctl check`（服务保持停止） | 只产生 1 条失败通知；恢复后 1 条恢复通知 |
| T16 | 升级失败回滚 | 用通过门槛但连不上的二进制升级（P1） | 探测失败切回旧版本，服务恢复 ok，证据文件保留 |

### 实机验收记录（2026-10-24）

| 编号 | 结果 | 证据 |
|------|------|------|
| T4 | 通过 | `vpnctl on` 后服务 active、端口在听、gsettings manual、`check` 204、出口 IP 为服务器 IP |
| T7 | 通过 | `edit` 写入非法 JSON → 退出 2，正式配置哈希不变 |
| T8 | 通过（修复后重跑） | 首次实测暴露 `edit` 临时文件无 `.json` 后缀的 bug（rc=2）；修复后死节点配置 → 退出 4、配置自动回滚、服务恢复 |
| T9 | 通过 | 停止服务后下一轮 timer 把 `health.json` 标为 fail（reason=service inactive，fails=1），journal 有异常记录；`vpnctl on` 后恢复 |

尚未实机执行：T5（off）、T6（kill -9 自愈）、T10（重启自启）、T12（移走 /opt/v2rayN）、T14（坏 geo）、T15（通知去重）。T1～T3、T11、T13、T16 仅在离线 mock 环境通过。

补充：`bash -n vpnctl.sh` 必须通过；`shellcheck vpnctl.sh` 无 error（本机尚未安装 shellcheck，实施前先 `sudo dnf install shellcheck`，或把该检查降级为 P1）；`test_vpnctl.sh` 覆盖 T1～T3、T7、T11、T13、T16～T19（以及 install/status/check/on/off/restart/ip/rollback/update-geo 的 mock 路径），不访问网络；2026-11-09 起共 51 项。

---

## 10. 实施阶段与回滚

> 实施状态（2026-10-24）：P0 与 P1 的全部命令已实现，`test_vpnctl.sh` 42 项通过（2026-11-09 更新为 51 项）；实机 T4～T16 尚未执行；P2 未做。

### P0（必须先做）

1. 写 `vpnctl.sh`（install/validate/on/off/restart/status/check/ip/edit/rollback/logs/help）。
2. 写三个单元文件与占位模板。
3. `install --dry-run` 走查；确认无误后实装。
4. 退出 v2rayN → 禁用自启动 → `vpnctl on`。
5. 跑 T1～T12（T10 最后做）。
6. `status` 输出资产日期/哈希，并在超过 90 天时告警（只读功能，不依赖 P1 的 `update-geo`）。
7. 迁移完成、v2rayN 不再作为主代理后，再更新 `proxy-ctl` 的告警文案与 README（把“v2rayN 是否在运行？”改为“`vpnctl status` 查看”）；迁移前保持原样，避免提示与实际不符。

### P1

- `upgrade`、`update-geo`、`uninstall`。在 P1 落地前，如果必须升级，按 6.9 的清单手动替换并写证据文件，不跳过核查。
- 验证单元硬化（`ProtectSystem=strict`、`ProtectHome=read-only`），通过后再加入 v1 单元。
- 文档脱敏与 secret 扫描脚本。

### P2

- `AUTO_OFF` 的可视化提示（通知里给出“已自动切回直连”）。
- macOS 对照实现（若需要）。
- TUN 只做可行性研究，不实施。

### 回滚方案

1. `vpnctl off`（恢复直连）。
2. `systemctl --user disable --now xray-client vpn-health.timer`。
3. 恢复 `~/.config/autostart/v2rayN.desktop`（若被改名）。
4. 启动 v2rayN，确认节点仍可用（其 DB 未改动）。
5. 保留 `~/.config/xray/` 与备份，不删除。

整个迁移期间 v2rayN 不卸载，因此回滚成本是分钟级。

---

## 11. 残余风险（明确接受）

- 单节点：服务器被封时，只能 `off` 后直连，没有自动切换。
- 无 kill switch：走系统代理的应用在隧道故障时是“失败”而不是“泄露”；但本就不走代理的应用一直直连。
- 健康检查盲区约 3 分钟（含同轮 5 秒重试），不是实时检测；正在进行的连接失败由应用自己报错。
- 本地代理无认证：本机任意进程都能使用；这是代理模型的固有属性。
- 不做 TUN：不读系统代理的应用不受控。
- 内核与 geo 更新由人触发，不自动。
- 配置是 v2rayN 的快照，后续 v2rayN 升级不会同步；这是有意的解耦。
- 更新安全最终依赖人工核查：工具能强制“官方来源、60 天门槛、SHA256、证据”，但无法证明“没有投毒”；证据文件是流程约束，不是技术保证。

### 11.1 这套配置不保护什么（2026-11-09）

来自对 [sing-box 配置生成器](https://github.com/riverscn/singbox-confgen) DESIGN.md
“已知局限”的对照：那份文档明确写出自己覆盖不到的地方，避免使用者误判。以下每条都能
在配置或实测里找到依据，改配置前请先读这一节。

| 不保护的情况 | 依据 | 后果 |
|---|---|---|
| **不走系统代理的应用** | 无 TUN，GNOME `mode=manual` 只影响遵守系统代理的程序 | 这类程序完全不经 xray，分流、IPv6 守卫、域名规则都管不到 |
| **浏览器自带安全 DNS（DoH）** | 与 xray 无关，浏览器自己解析 | 绕过 DNS 分流：拿到的地址可能被污染，或与路由判断不一致。本机 Chrome 未手动设置 secure DNS（默认自动），当前未触发；一旦开启或路由器被识别为已知 DoH 解析器即生效 |
| **未走代理的域名解析** | `routing.domainStrategy = "AsIs"`，客户端解析由 systemd-resolved → `192.168.0.1` 完成；2026-11-09 实测（临时实例 + access log，5 条流量）目标一律以**域名**记录、`dns-module` 出现 **0 次** | 这些域名可能拿到污染答案；`dns` 段（远程 DoH、AAAA 置空）对这一层**不生效**，它是“写了但不在路径上”的策略。决策见 TODO 4.4：保持 A1（不做 `IPIfNonMatch`） |
| **非代理应用的 IPv6** | catch-all 规则只在 xray 的路由里 | 这类应用直连 IPv6，成败取决于线路，不受 `::/0 → block` 约束 |
| **国内 IPv6 被全局压掉** | `/etc/gai.conf` 让 glibc 程序优先 IPv4（`getent ahosts` 已验证顺序）；Chromium 自带解析器、Go 不读 gai.conf，所以**只影响不走代理的 glibc 程序** | 这批程序无法用国内 IPv6；换来的是“非代理应用不会先撞被墙的 IPv6 再挂起”。2026-11-09 评估：保留，见 TODO 4.5 |
| **单节点、单服务器** | 只有 `proxy` 一个自建节点 | 服务器被封只能 `off` 后直连，没有自动切换 |
| **tailnet 单路径** | Telegram 经 `proxy-ts`（Tailscale） | Tailscale/DERP 中断时 Telegram 断，其余流量正常；`vpnctl status` 的 `egress` 行会显示 `fail`（2026-11-09 起） |
| **per-app 分流** | Linux 桌面端 Tailscale 无官方 per-app 分流，本方案也未做 | 只能整机分流，不能按程序 |
| **健康检查的时延** | `vpn-health.timer` 每 3 分钟一轮 | 故障最长约 3 分钟才被发现，期间的连接由应用自己报错 |

---

## 12. 已确认事项与待确认问题

### 已确认（2026-10-24）

- 健康检查失败默认只通知、不自动关代理；`AUTO_OFF` 保持默认 0。
- 探测间隔 3 分钟、地址 `https://www.gstatic.com/generate_204` 接受。
- geo 90 天告警 + 手动更新接受。
- 不做 `upgrade --check`；更新完全手动。
- 更新禁止追最新；只选官方来源、满 60 天冷却期的稳定版，并做供应链核查。
- 冷却期定为 60 天。
- 首次安装使用官方 release 的 xray（显式 `--xray` + `--xray-sha256`），不再使用 v2rayN 自带内核；建议基线为“同版本换来源”，不套 60 天冷却（bootstrap 例外）。
- 安装时使用 `--disable-v2rayn-autostart` 关闭 v2rayN 自启（保留安装，可手动启动）。
- v2rayN 至少保留两周，T4～T16 全过后再卸载。

### 待确认

无。

---

## 13. 变更记录

- 2026-11-09：加固（依据 TODO 4.1–4.3）。改动：① IPv6 拦截由五个手写前缀改为一条 `ip: ["::/0"] → block`，位置在直连规则之后、代理与 Telegram 规则之前（实测 IPv6 字面量由挂起变为 8 ms 失败）；② `policy_ok` 支持多个 VLESS 出站（并要求每个都是 REALITY + Vision），修掉 2026-11-05 以来 `validate` 一直拒绝真实配置的缺陷；③ 新增诊断入站 `127.0.0.1:10809`（tag `ts-in`）与首条路由，`vpnctl check` 增加 tailnet 出口探针，`status` 增加 `egress` 行；④ 新增 `geo-manifest.py` 与 `vpnctl geo-manifest`，`validate` 会点名不存在的 `geosite:`/`geoip:` 代码；⑤ `test_vpnctl.sh` 增加 T17–T21（geo 清单、IPv6 守卫、多 VLESS、路由真值表、tailnet 探针），42 → 59 项；⑥ 新增 §11.1“不保护什么”；⑦ 用临时实例 + access log 实测 DNS 路径（`dns-module` 0 次、目标以域名记录），决策 A1：不启用 `IPIfNonMatch`；⑧ 评估 `gai.conf`：只影响不走代理的 glibc 程序，保留。原因：对照 sing-box 配置生成器的设计，补齐“每个出口各自自检”“规则顺序离线可验证”“显式写出不保护什么”三件事。验证：`test_vpnctl.sh` 59 项全过；实机 `vpnctl validate`/`check` 通过，见 TODO 4.1 验收。
- 2026-10-24：创建设计稿（v0.1）。原因：用户决定从 v2rayN GUI 迁移到本地配置文件方案，要求先出设计并逐条处理已识别的风险。
- 2026-10-24：升级到 v0.2。原因：用户要求“安全第一、禁止追最新、只选最近稳定版并做投毒核查”。改动：更新策略改为“满 30 天冷却的最近稳定版”；新增供应链核查清单、`--sha256/--released/--source` 强制参数与证据文件；移除从 v2rayN 内核升级的路径（只保留为基线）；geo 告警 180→90 天；失败通知改为同轮 5 秒重试、首轮失败即通知；确认默认不自动关代理、不做联网版本检查。
- 2026-10-24：升级到 v0.3。原因：用户确认冷却期改为 60 天、首次安装改用官方 release 内核。改动：`UPGRADE_MIN_AGE_DAYS` 默认 30→60；`install` 不再默认复制 v2rayN 内核，改为强制 `--xray` + `--xray-sha256`；新增基线证据文件与“同版本换来源”的 60 天例外；待确认项收敛为 v2rayN 自启动与卸载时间。
- 2026-10-24：升级到 v1.1.2。原因：实机 T8 发现 `vpnctl edit` 的临时文件没有 `.json` 后缀，xray 26.3.27 拒绝推断格式，导致 `edit` 在校验阶段退出 2；离线 fake xray 不校验扩展名，没覆盖到。改动：`edit` 改为在临时目录内使用 `config.json`；所有 `xray -test` 显式加 `-format=json`；`test_live.sh` 增加 `--only-t8`。已用真实 xray + mock systemd 复现并验证：死节点配置会退出 4 且配置回滚。
- 2026-10-24：升级到 v1.1。原因：核对官方 Releases 后发现 `26.10.10` 不是官方 tag；最新 stable `v26.10.21` 仅发布 3 天，26.4～26.9 均为 prerelease；实机还发现 `install` 复制 geo 资产时用 `install(1)` 重设了 mtime，导致 `status` 误报资产日期。改动：首次基线按规则改为 `v26.3.27`（非 prerelease、满 60 天、真实配置 `-test` 通过），并在 README/设计记录 zip 与 binary 的 SHA256；资产复制改用 `install -p`（含 `update-geo` 与回滚路径）；新增离线 T8 回滚测试与 `test_live.sh`（实机 T9/T7/T8，带备份与自动恢复）；离线测试 42 项通过。
- 2026-10-24：升级到 v1.0（实现完成）。改动：新增 `vpnctl.sh`、三个单元文件、`config.example.json`、`README.md`、`test_vpnctl.sh`；`install` 增加 `--from-assets` 与安装暂存/回滚；`upgrade` 增加同版本拒绝、安装前置检查；状态显示 geo 90 天告警；离线测试 40 项通过（含仓库 UUID 形态扫描）；`validate` 用真实 xray 验证“0.0.0.0 拒绝、127.0.0.1 通过”。实机 T4～T16 待执行。
