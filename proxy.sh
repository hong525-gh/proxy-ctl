#!/usr/bin/env bash
# proxy-ctl / proxy.sh
# 让 Bash 会话的代理环境变量自动跟随 GNOME 系统代理设置。
# 详见同仓库 DESIGN.md。
#
# 用法：在 ~/.bashrc 末尾追加一行
#     [ -f ~/.config/proxy-ctl/proxy.sh ] && . ~/.config/proxy-ctl/proxy.sh
#
# 目标环境：Fedora 44 / GNOME / Bash 5+，GUI 代理工具为 v2rayN（xray）。

# ---------- 要点 0：非交互式 Shell 短路 ----------
# scp / rsync / sftp / git-over-ssh 也会 source ~/.bashrc。
# 向 stdout 输出任何字节都会污染协议流，导致远端连接中断。
# 因此非交互式一律立即返回，且这一行必须在最前面。
[[ $- == *i* ]] || return 0

_pc_clear() {
    # 清除全部代理相关环境变量（大小写两套 + SOCKS + no_proxy）。
    unset http_proxy  HTTP_PROXY \
          https_proxy HTTPS_PROXY \
          all_proxy   ALL_PROXY \
          no_proxy    NO_PROXY
}

_pc_apply() {
    # 参数：$1=host  $2=port
    # xray 10808 是 HTTP+SOCKS 混合入站，故三类协议可指向同一 endpoint。
    local url="http://$1:$2"
    local socks="socks5://$1:$2"
    # 2026-11-06: kimi.com 加入 no_proxy —— dsh 调 Kimi 走本地 xray 跳频繁被 RST
    # （晚高峰约半数请求 3-11 秒内 Connection error），国内端点本就该直连。
    # 同日补显式子域名（api/code/auth/telemetry-logs），兼容不做后缀匹配的
    # no_proxy 实现（部分 Node/Go HTTP 客户端只认全等或前导点）。
    # A/B 实验：若 1-2 天内晚高峰不再出现，则元凶是本地 xray 跳，此改动保留。
    local ignore="localhost,127.0.0.0/8,::1,.local,kimi.com,.kimi.com,api.kimi.com,code.kimi.com,auth.kimi.com,telemetry-logs.kimi.com"
    export http_proxy="$url"    HTTP_PROXY="$url"
    export https_proxy="$url"   HTTPS_PROXY="$url"
    export all_proxy="$socks"   ALL_PROXY="$socks"
    export no_proxy="$ignore"   NO_PROXY="$ignore"
}

_pc_warn() {
    # 报错走 stderr，绝不进 stdout。
    printf '\033[33m[proxy-ctl] %s\033[0m\n' "$*" >&2
}

_pc_sync() {
    # 主流程：读 gsettings → 校验 → 探测端口 → apply / clear。
    local mode host port

    # gsettings 不存在（例如异常环境）→ 直接清并退出
    command -v gsettings >/dev/null 2>&1 || { _pc_clear; return 0; }

    mode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "'")

    # 只识别 manual；none / auto(PAC) 都按未开启处理。
    if [[ "$mode" != "manual" ]]; then
        _pc_clear
        return 0
    fi

    host=$(gsettings get org.gnome.system.proxy.http host 2>/dev/null | tr -d "'")
    port=$(gsettings get org.gnome.system.proxy.http port 2>/dev/null)

    # 输入校验：host 非空、port 是纯数字。
    # 防止 gsettings 返回空串时导出 "http://:10808" 这样的坏值。
    if [[ -z "$host" ]] || [[ ! "$port" =~ ^[0-9]+$ ]] || (( port == 0 )); then
        _pc_clear
        return 0
    fi

    # 端口探测：Bash 内置 /dev/tcp，不 fork nc / timeout。
    # 打开成功即可，随后立刻关闭该 FD。
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
        exec 3<&- 3>&-
        _pc_apply "$host" "$port"
    else
        _pc_clear
        _pc_warn "系统代理已开启，但 ${host}:${port} 不可通（v2rayN 是否在运行？）"
    fi
}

_pc_sync
