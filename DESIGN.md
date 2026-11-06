
## 重新梳理需求

### 核心目标
**让命令行工具（Terminal）和浏览器一样，自动跟随系统网络代理的状态。**

### 具体行为

| 系统代理状态 | 命令行行为 |
|-------------|-----------|
| 已开启（有效） | 自动走代理 |
| 已关闭 | 自动直连 |
| 开启但不可用（端口不通） | 直连 + 报错提示 |

### 触发时机
- **每次打开新终端**时自动检测并应用
- **不需要**手动执行任何命令
- **不需要**后台常驻进程
- **不需要**状态查询、节点切换等高级功能

---

## 目标环境（本机现状）

本方案只针对当前这台设备的真实环境设计，其它环境不在范围内。

| 项 | 当前值 |
|----|--------|
| OS | Fedora Linux 44 (Workstation Edition) |
| 桌面 | GNOME on Wayland |
| Shell | Bash 5.3（未安装 zsh） |
| GUI 代理工具 | **v2rayN**（`/opt/v2rayN/v2rayN`），内核为 **xray** |
| xray 监听 | `*:10808`（HTTP + SOCKS 混合入站，单端口复用） |
| GUI 配置目录 | `~/.local/share/v2rayN/guiConfigs/` |
| 内核运行配置 | `~/.local/share/v2rayN/binConfigs/config.json` |
| GNOME 代理模式 | `manual`（四个协议槽位统一指向 `127.0.0.1:10808`） |
| GNOME `ignore-hosts` | `localhost,127.0.0.0/8,::1` |
| 是否暴露 REST API | **否**（v2rayN/xray 默认不开管理 API，与 mihomo 不同） |

**关键推论：**

1. v2rayN 不像 mihomo 那样提供 REST API，因此**不再有"通过 API 查询/切换节点"这条路径**。节点切换只能在 GUI 里做。
2. xray 的 10808 是**HTTP+SOCKS 混合端口**，所以 `http_proxy`、`https_proxy` 和 `ALL_PROXY(socks5)` 都可以指向同一 host:port。
3. 桌面固定为 GNOME，因此 `gsettings` 一定可用，无需考虑 KDE / XFCE / WSL / 无 D-Bus 的 SSH 会话等场景。

---

## 简化后的架构

```
┌─────────────────────────────────────────────────────────┐
│                      用户交互层                          │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │              ~/.bashrc 中 source 一段脚本        │    │
│  │        （文件位置：~/.config/proxy-ctl/proxy.sh） │    │
│  │                                                 │    │
│  │   0. 判定是否交互式 Shell（否则直接返回）        │    │
│  │   1. 读取 GNOME 系统代理模式与地址              │    │
│  │   2. 探测 xray/v2rayN 端口是否可用              │    │
│  │   3. 设置或清除代理相关环境变量                  │    │
│  │   4. 仅在异常时向 stderr 输出提示                │    │
│  └─────────────────────────────────────────────────┘    │
│                          │                              │
│                          ▼                              │
│  ┌─────────────────────────────────────────────────┐    │
│  │              外部依赖                           │    │
│  │                                                 │    │
│  │  • gsettings                                    │    │
│  │      读取 org.gnome.system.proxy.{mode,http,…} │    │
│  │  • Bash 内置 /dev/tcp                           │    │
│  │      测试 xray 的 10808 端口连通性             │    │
│  │  • v2rayN / xray                                │    │
│  │      只读依赖：脚本不管理它的生命周期           │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## 去掉的模块

相对于最初的复杂设计，以下内容**不再需要**：

| 移除项 | 原因 |
|--------|------|
| Python 脚本 | 功能简单，Bash 足以胜任 |
| 独立命令（status/list/switch） | v2rayN 无 REST API，无法程序化切换；用户在 GUI 完成 |
| API 通信模块 | 同上 |
| 配置文件 | 所有输入来自 gsettings，无需用户额外配置 |
| 日志模块 | 不需要记录操作历史 |
| 后台守护进程 | 每次终端启动执行一次即可 |
| 多桌面环境适配（KDE 等） | 本机固定为 GNOME |
| zsh 分支 | 本机未安装 zsh；且 zsh 不支持 `/dev/tcp` |

---

## 最终交付：一个 Bash 片段

放置位置建议：**`~/.config/proxy-ctl/proxy.sh`**，然后在 `~/.bashrc` 末尾加一行：

```bash
[ -f ~/.config/proxy-ctl/proxy.sh ] && . ~/.config/proxy-ctl/proxy.sh
```

这样后续修改脚本无需再改动 `~/.bashrc`。

### 脚本逻辑

```
source proxy.sh
    ↓
是否交互式 Shell？（$- 中是否含 i）
    │
    ├── 否 → 立即 return（避免污染 scp/rsync/git-over-ssh 通道）
    │
    └── 是 → 继续
              ↓
         读取 gsettings：mode / http.host / http.port / ignore-hosts
              ↓
         ┌──────────────────────────────────────────┐
         │ mode == 'manual' 且 host、port 均有效？   │
         └──────────────────────────────────────────┘
              │
              ├── 否 → 清除所有代理环境变量（大小写两套）→ 静默返回
              │
              └── 是 → 用 /dev/tcp 探测 host:port（1s 超时）
                        │
                        ├── 通 → 导出 http_proxy/https_proxy/ALL_PROXY
                        │        + no_proxy（大小写两套）→ 静默
                        │
                        └── 不通 → 清除所有代理环境变量
                                   + 向 stderr 输出一行提示
                                   （不阻塞 Shell 启动）
```

---

### 关键实现要点

**要点 0：非交互式 Shell 短路**

`scp`/`rsync`/`sftp`/`git over ssh` 会以非交互方式 source `.bashrc`。此时若脚本向 stdout 输出任何内容，都会污染协议流，导致远端连接中断。因此**必须**在最前面加：

```bash
[[ $- == *i* ]] || return
```

**要点 1：读取 GNOME 系统代理**

```bash
_pc_mode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "'")
_pc_host=$(gsettings get org.gnome.system.proxy.http host 2>/dev/null | tr -d "'")
_pc_port=$(gsettings get org.gnome.system.proxy.http port 2>/dev/null)
```

- 只识别 `mode == manual`。`none` 与 `auto`（PAC）都视为"未开启"，走直连分支。
- 本机上 http / https / socks 槽位统一填的是 `127.0.0.1:10808`，读 http 一路即可。

**要点 2：输入校验**

`gsettings` 有可能返回空串（例如 mode 是 manual 但 http host 未填）。若不校验就 `export http_proxy="http://:10808"`，会静默污染环境。

```bash
if [[ -z "$_pc_host" || ! "$_pc_port" =~ ^[0-9]+$ ]]; then
    _pc_clear && return
fi
```

**要点 3：端口探测（Bash 内置，无外部进程）**

```bash
# 用文件描述符 3；避免 fork /usr/bin/timeout
if ! (exec 3<>/dev/tcp/"$_pc_host"/"$_pc_port") 2>/dev/null; then
    _pc_clear
    printf '\033[33m[proxy-ctl] 系统代理已开启，但 %s:%s 不可通（v2rayN 是否在运行？）\033[0m\n' \
        "$_pc_host" "$_pc_port" >&2
    return
fi
exec 3<&- 3>&-
```

- 用 Bash 内置 `/dev/tcp`，不 fork `nc` 或 `timeout`。
- 提示走 **stderr**，不进 stdout。

**要点 4：设置/清除环境变量（大小写两套 + SOCKS + no_proxy）**

xray 在 10808 是 HTTP+SOCKS 混合入站，因此三类变量都可以指向同一 endpoint。

```bash
_pc_apply() {
    local url="http://$_pc_host:$_pc_port"
    local socks="socks5://$_pc_host:$_pc_port"
    export http_proxy="$url"  HTTP_PROXY="$url"
    export https_proxy="$url" HTTPS_PROXY="$url"
    export all_proxy="$socks" ALL_PROXY="$socks"
    export no_proxy="localhost,127.0.0.0/8,::1,.local,kimi.com,.kimi.com,api.kimi.com,code.kimi.com,auth.kimi.com,telemetry-logs.kimi.com"
    export NO_PROXY="$no_proxy"
}

_pc_clear() {
    unset http_proxy HTTP_PROXY \
          https_proxy HTTPS_PROXY \
          all_proxy ALL_PROXY \
          no_proxy NO_PROXY
}
```

- **必须同时 unset 大小写两套**。本机当前环境里就残留着 `HTTPS_PROXY=`（空串），是这个坑的现成证据。
- `no_proxy` 复用 GNOME 已配置的 `ignore-hosts` 值，避免本机开发端口被误代理。

---

## 设计的优势

| 特点 | 说明 |
|------|------|
| **极简** | 一个 Bash 片段，`~/.bashrc` 里只加一行 source |
| **零依赖** | 仅使用 Bash 内置 `/dev/tcp` 与系统自带 `gsettings` |
| **即时生效** | 每次打开新交互终端自动执行 |
| **行为一致** | 与浏览器一样，读取 GNOME 系统代理设置 |
| **失败可感知** | 端口不通时明确报错（stderr），且不影响 Shell 启动 |
| **安全降级** | 系统代理关闭 / 端口不通 → 静默直连 + unset，不留残值 |
| **通道安全** | 非交互 Shell 短路，不破坏 scp/rsync/ssh 传输 |
| **可维护** | 脚本在独立文件中，后续升级无需再动 `~/.bashrc` |

---

## 特殊场景处理

**场景 1：v2rayN 已开启系统代理，但 xray 内核未启动**
- gsettings 显示 `manual`，但 `127.0.0.1:10808` 不通
- 脚本 → 清除环境变量 + stderr 报错
- 结果：命令行直连，用户明确看到"v2rayN 是否在运行？"

**场景 2：用户在 v2rayN 里改了监听端口**
- 例如从 10808 改到 20808
- v2rayN 通常会同步修改 GNOME 代理设置 → 脚本读到新端口 → 自动适配

**场景 3：v2rayN 完全退出，且从 GUI 里关掉了系统代理**
- gsettings mode = `none`
- 脚本 → 清除环境变量 → 直连（静默）

**场景 4：非交互式 SSH / scp / rsync**
- 由要点 0 短路，脚本立即 return，不动环境、不产生输出

**场景 5：已打开的终端不会自动感知变化**
- 这是刻意保留的限制：脚本无守护进程，只在启动时读一次
- 用户如需在当前 Shell 内刷新，重新 `source ~/.config/proxy-ctl/proxy.sh` 即可

---

## 明确的非目标

以下场景**不在**本设计的支持范围内，避免范围蔓延：

- KDE / XFCE / i3 / 无 D-Bus 的纯 SSH 会话
- zsh / fish / dash / sh
- GNOME `mode=auto`（PAC）——一律按"未开启"处理
- DNS-over-proxy（`http_proxy` 不代理 DNS 查询，DNS 仍走系统解析）
- 有自己代理配置的工具（`git`、`npm`、`apt`、`docker`、`pip.conf` 等），若它们优先级高于环境变量，本脚本无能为力
- 节点切换、订阅更新、流量统计等 v2rayN GUI 已经提供的功能
