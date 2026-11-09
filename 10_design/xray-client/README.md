# xray-client — 本地配置文件代理（方案 A）

用 systemd user service 直接运行官方 xray，配置文件在本地；不启动 v2rayN 界面。
设计、风险控制与验收标准见 [design.md](design.md)（v1.1.2）。

## 目录内容

| 文件 | 用途 |
|------|------|
| `vpnctl.sh` | 唯一入口（安装、校验、开关、状态、编辑、升级、geo 更新） |
| `xray-client.service` | xray 内核的 systemd user 单元 |
| `vpn-health.service` / `.timer` | 每 3 分钟做一次真实 204 探测 |
| `config.example.json` | 占位模板，只作参考；`install` 实际使用 v2rayN 生成的真实配置 |
| `test_vpnctl.sh` | 离线验收测试（mock systemd/gsettings/curl，不访问网络） |

## 前置条件

1. Fedora + GNOME，`jq`、`curl`、`ss`、`systemctl`、`gsettings` 已安装。
2. 一份**官方 release** 的 xray 二进制（不是 v2rayN 目录里的副本）。
3. `geoip.dat`、`geosite.dat` 各大于 1 MB（默认从 `~/.local/share/v2rayN/bin` 取）。
4. 现有 v2rayN 生成的配置：`~/.local/share/v2rayN/binConfigs/config.json`。

## 安装

### 1. 下载并核对官方 xray

从官方 Releases 选版本，规则：**stable（非 prerelease）、非最新、发布满 60 天**。

2026-10-24 核对结果：

- 最新 stable 是 `v26.10.21`（2026-10-21，只有 3 天），按“不选最新”不选；
- 其余 26.x 版本（26.4～26.9）在 GitHub 上标记为 prerelease，不选；
- 符合条件的最新非 prerelease 稳定版是 `v26.3.27`（2026-03-27，已满 60 天），并且已经用你的真实配置跑通 `xray -test`。

下载到独立目录（不要把 38 MB 二进制放进仓库）：

```bash
mkdir -p ~/Downloads/xray-26.3.27
cd ~/Downloads/xray-26.3.27
curl -LO https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip
sha256sum Xray-linux-64.zip
# 2026-10-24 核对值：23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
unzip -o Xray-linux-64.zip
sha256sum xray
# 2026-10-24 核对值：8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
./xray version
```

注意：`sha256sum xray` 必须在解压之后执行；当前目录没有 `xray` 时它会报 `No such file or directory`，这不是哈希不匹配。

`v26.3.27` 比较旧（2026-03-27）。这是“不选最新 + 不选 prerelease + 满 60 天”三条规则共同作用的结果；如果你愿意为更新放宽其中一条，需要单独决定并记录理由。默认使用 `~/.local/share/v2rayN/bin` 里的 geo 资产（比 26.3.27 包内更新）；想全用官方包内资产就加 `--from-assets ~/Downloads/xray-26.3.27`。

### 2. 安装

**先看计划（不写任何文件）：**

```bash
./vpnctl.sh install --dry-run \
  --xray ~/Downloads/xray-26.3.27/xray \
  --xray-sha256 8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed \
  --xray-source https://github.com/XTLS/Xray-core/releases/tag/v26.3.27 \
  --disable-v2rayn-autostart
```

`--dry-run` **只打印计划，不安装任何东西**；它不会生成 `~/.local/bin/vpnctl`，也不会写配置或单元。必须去掉 `--dry-run` 再执行一次。

**实装：**

```bash
./vpnctl.sh install \
  --xray ~/Downloads/xray-26.3.27/xray \
  --xray-sha256 8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed \
  --xray-source https://github.com/XTLS/Xray-core/releases/tag/v26.3.27 \
  --disable-v2rayn-autostart
```

安装完成后才可以用 `vpnctl` 命令；如果当前 shell 提示 `command not found`，执行 `hash -r`，或直接用 `~/.local/bin/vpnctl`。

`--disable-v2rayn-autostart` 会把 `~/.config/autostart/v2rayN.desktop` 改名为 `.disabled`，避免登录后 v2rayN 抢占 `10808`。它不卸载 v2rayN，随时可以手动打开。

**源配置要求**：`~/.local/share/v2rayN/binConfigs/config.json` 必须是自建节点的 **VLESS + REALITY + Vision**（`HK-REALITY`）。如果 v2rayN 当前活动的是订阅里的 Trojan 节点，`install` 会在 policy 校验阶段拒绝并打印 `policy summary`（`outbounds: ["trojan", ...]`、`vless: 0`）。先在 v2rayN 里选中 `HK-REALITY`，等内核重启、配置文件更新后再装。

### 3. 退出 v2rayN，启动服务

```bash
# 先在 v2rayN 托盘里退出它
vpnctl on
vpnctl status
vpnctl check
curl --noproxy '' -x http://127.0.0.1:10808 https://api.ipify.org
```

最后一条应返回香港服务器 IP。

## 日常命令

| 命令 | 作用 |
|------|------|
| `vpnctl status` | 本地状态摘要（不联网） |
| `vpnctl check` | 真实 204 探测并写 `health.json` |
| `vpnctl ip` | 查询当前出口 IP |
| `vpnctl off` / `on` | 关/开系统代理 + 服务 |
| `vpnctl restart` | 校验配置 → 重启 → 探测 |
| `vpnctl logs` / `logs -f` | 查看 xray 日志 |
| `vpnctl edit` | 编辑配置：校验 → 备份 → 重启 → 失败自动回滚 |
| `vpnctl rollback` | 恢复最近一次配置备份 |
| `vpnctl validate` | 三段式校验（JSON、xray -test、安全策略）；xray 报错时会点名不存在的 `geosite:`/`geoip:` 代码 |
| `vpnctl geo-manifest` | 从当前 `geosite.dat`/`geoip.dat` 重建代码清单（install / update-geo 会自动做） |

状态文件：`~/.local/state/vpn/health.json`（0600）。配置：`~/.config/xray/config.json`（0600）。
代码清单：`~/.local/state/vpn/geo-codes/{geosite,geoip}.txt`（0600）。

## IPv6 策略（2026-11-09 起）

出口 VPS 没有任何 IPv6 路由，所以**代理路径只走 IPv4**：路由里把
`ip: ["::/0"] → block` 放在直连（国内、内网）规则之后、代理规则之前。
到达代理路径的 IPv6 字面量会在 10 毫秒内失败，应用立刻回落到 IPv4；国内和
内网的 IPv6 照旧直连，不受影响。这条规则替代了原来手写的五个 IPv6 前缀
（Telegram/Google/Meta）—— 清单永远漏掉下一个前缀，而这条规则不会。

`vpnctl status` 的 `guard` 行显示这条规则在不在；`vpnctl check` 的 `ipv6`
状态靠它判断“快速失败”是策略还是故障。

## 双出口与 `egress` 探针（2026-11-09 起）

Telegram 走 `proxy-ts`（经 Tailscale），其余走 `proxy`。为了让第二条路也能被检查，
客户端多了一个**只监听 `127.0.0.1:10809`** 的 mixed 入站（tag `ts-in`），路由首条
直接把它交给 `proxy-ts`：

```jsonc
{"tag": "ts-in", "listen": "127.0.0.1", "port": 10809, "protocol": "mixed",
 "settings": {"auth": "noauth", "udp": false}}
// routing.rules[0]
{"type": "field", "inboundTag": ["ts-in"], "outboundTag": "proxy-ts"}
```

`vpnctl check` 经 10809 请求 `https://api.telegram.org/`，`vpnctl status` 多出一行：

```
egress  : telegram via proxy-ts: ok (http 302, 210 ms)
```

这条探针失败**不会**把整体健康判为 fail（否则 `AUTO_OFF` 会因为 Telegram 一条路断了
关掉全部代理），只在 `status` 的 `warn` 里提示。手工验证某条流量走的是 tailnet：

```bash
curl -s -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:10809 https://api.telegram.org/
ss -tn | grep 100.118.65.105:8443
```

## 更新策略（安全优先）

- **不自动更新，不做联网版本检查。**
- 只选官方 stable release；版本字符串不能含 `pre`/`rc`/`beta`/`alpha`/`nightly`。
- 发布必须满 **60 天**；最新版不满 60 天就停在上一稳定版。
- 必须核对 SHA256，并记录来源、发布日期、证据。
- 唯一例外：当前版本有被在野利用的高危漏洞、新版本修复了它。此时用 `--security-fix --reason`，仍要核对哈希和记录证据。

升级示例：

```bash
vpnctl upgrade ./xray-26.09.01 \
  --sha256 <64位十六进制> \
  --released 2026-08-20 \
  --source https://github.com/XTLS/Xray-core/releases/tag/<tag>
```

升级流程：校验门槛 → 写证据到 `~/.local/state/vpn/upgrades/` → 旁路安装 → 新二进制 `run -test` → 切换 → 重启 → 真实探测 → 失败自动切回。

### GeoFiles

只维护 `geoip.dat` 与 `geosite.dat`。`Country.mmdb`、`geoip.metadb`、`geoip-only-cn-private.dat` 不被 xray 配置引用，不需要更新。

```bash
vpnctl update-geo --from ~/Downloads/geo --source <下载页 URL>
```

脚本检查文件大小、备份旧文件、替换、重启、探测；失败恢复。来源与 SHA256 写入 `~/.local/state/vpn/assets.json`。`status` 在资产超过 90 天时告警。

## 可选配置

`~/.config/vpn/vpn.conf`（不存在则用默认值）：

```bash
AUTO_OFF=0
UPGRADE_MIN_AGE_DAYS=60
HEALTH_URL=https://www.gstatic.com/generate_204
NOTIFY=1
```

- `AUTO_OFF=1`：连续 2 轮探测失败后自动关系统代理并停服务，同时通知“已切回直连”。
- `UPGRADE_MIN_AGE_DAYS`：升级冷却天数，默认 60；改小等于放松安全门槛。
- `HEALTH_URL`：健康探测地址，必须返回 204；改它就是一次信任决定。
- `NOTIFY=0`：关闭桌面通知，journal 与 `health.json` 仍然记录。

## 故障处理

```bash
vpnctl status          # 服务、端口、代理模式、最近健康结果
vpnctl check           # 立刻做一次真实探测
vpnctl logs            # 看 xray 日志
vpnctl off             # 恢复直连（先关代理再停服务）
```

- 服务 failed：先 `vpnctl validate`，再看 `vpnctl logs`，修复后 `vpnctl restart`。
- 服务 active、端口在听、`check` 失败：多半是服务器被封/故障；先 `vpnctl off` 恢复直连，再上服务器排查。
- `status` 提示端口被占：退出 v2rayN，或先 `vpnctl off` 再启动 v2rayN。

## 卸载

```bash
vpnctl uninstall            # 停服务、恢复 v2rayN 自启、保留配置与资产
vpnctl uninstall --purge    # 连配置、资产、内核、state 一起删；会二次确认
```

## 安全说明

- 真实配置含 UUID、REALITY 公钥、shortId，只放在 `~/.config/xray/config.json`（0600）。本仓库只有占位模板。
- 不从未知镜像、网盘、论坛附件、聊天群文件下载内核。
- 升级证据文件在 `~/.local/state/vpn/upgrades/`；工具能强制来源/年龄/哈希/证据，但不能证明“没有投毒”，最终判断仍靠人工核查。

## 测试

离线测试（不访问网络，不改真实系统）：

```bash
bash test_vpnctl.sh
```

实机测试 T9 / T7 / T8（会短暂断网，失败自动恢复）：

```bash
bash test_live.sh                  # 会先确认
bash test_live.sh --yes            # 跳过确认
bash test_live.sh --yes --only-t8  # 只重跑 T8（约 20 秒）
```

`test_live.sh` 会：停服务最多 4 分钟验证健康检查变 fail（T9）；用非法 JSON 验证 `edit` 拒绝（T7）；用指向 `127.0.0.1:1` 的有效配置验证自动回滚（T8）。开始前备份配置，结束时恢复并 `vpnctl on`。

测试使用临时 `HOME` 和 mock 的 `systemctl`/`gsettings`/`curl`，不会改动真实系统，也不访问网络。`T4`～`T16` 需要在本机真实运行时验收（见 design.md 第 9 节）。
