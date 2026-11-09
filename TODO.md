# TODO — VPN / 代理

待办清单。每条按 5W1H 六项写齐，附验收标准与回滚，便于隔一段时间后不用回忆就能接着做。

---

## 待办 1：向服务商咨询/申请这台 VPS 的 IPv6，并在拿到后完成配置与收尾

**状态**：待你跟进（面板/工单需要你的账号；不阻塞当前使用，临时方案已生效）
**建立日期**：2026-11-03

### What（要达成什么）

拿到 LightLayer 为实例 `207.56.18.51`（HK-VP02-A，tailnet 名 `vm-z4ziutm3`）分配的 IPv6 地址/前缀与网关，配到 VPS 的 netplan 上并验证连通，然后把客户端的两个临时措施撤掉：

1. 删除本机 xray 路由里的 IPv6 catch-all 规则（2026-11-09 起是 `ip: ["::/0"] → block`，
   取代了原先手写的五个前缀）；
2. 删除本机 `/etc/gai.conf`（当前强制 IPv4 优先）；
3. `vpnctl check` 应显示 `ipv6 : ok`，`vpnctl status` 的 `guard` 行不再提示拦截、`warn` 为空。

### Why（为什么值得做）

- 本机有公网 IPv6、应用优先连 IPv6，而 VPS 没有任何 IPv6 路由，导致 Telegram/Google 的 IPv6 连接必然挂起（2026-11-03 实测：24 小时内 3,105 次 `unexpected EOF`，单次挂起约 12 秒）。
- 现有绕过方案（优先 IPv4 + 拦截 Telegram/Google 的 IPv6 前缀）只是把故障藏起来：IPv6 仍然不可用，且一旦新增需要走代理的域名，同类问题会复现。
- 服务商宣称套餐支持双栈，且其名下确有 IPv6 资源（`2407:21c0::/32`），值得确认是"未下发"还是"需自助开启"。

### Who（谁来做）

- **你**：登录面板看网络/IP 列表，或向客服开工单（账号与授权只有你有）。
- **我**：拿到地址/前缀/网关后，改 netplan、验证连通、撤掉客户端临时措施、更新文档。

### When（什么时候）

你安排即可，**不紧急**：当前临时方案已生效（14:20 起 tg_jlpt_bot 网络报错 0 条）。建议在下次给 VPS 做维护时一并处理。

### Where（涉及位置）

| 位置 | 说明 |
|---|---|
| LightLayer 面板 / 工单 | 查看或申请 IPv6；产品页 `https://lightlayer.net/` |
| VPS `vm-z4ziutm3`（`207.56.18.51`，`100.118.65.105`） | 配置文件 `/etc/netplan/00-installer-config.yaml`（当前只有 IPv4 段） |
| 本机 | `~/.config/xray/config.json`（拦截规则）、`/etc/gai.conf`、`~/.local/bin/vpnctl`（IPv6 探针） |
| 文档 | `10_design/vps-tailscale-exit-node.md` 的「2026-11-03 IPv6 复测结论」 |

### How（怎么判断、怎么做）

**第 0 步：先确认现状（1 分钟，只读）**

```bash
ssh hong 'ip -6 addr show eth0; ip -6 route show default'
```

期望：有 `inet6 <全局地址>` 与一条 `default via ...`。若仍只有 `fe80::`，说明尚未下发，回到第 1 步。

**第 1 步：面板确认**

面板 → 该实例 → 网络 / IP 列表，找形如 `2407:21c0:xxxx::/64` 或 `/128` 的 IPv6 地址及其网关。

**第 2 步：若面板没有 → 开工单**（可直接复制）

> Hello, this instance (IPv4 207.56.18.51, HK-VP02-A) has no IPv6: `ip -6 addr` shows only link-local, no RA is received with `accept_ra=2`, and a DHCPv6 solicit gets no reply. Your plans are advertised as supporting dual-stack IPv6 — could you please assign an IPv6 address/prefix and gateway to this instance, or tell me where to enable it in the panel?

**第 3 步：拿到地址后配置（我执行）**

- 备份 `/etc/netplan/00-installer-config.yaml`；
- 增加 IPv6 段（静态地址/前缀 + `gateway6` 或默认路由），`netplan apply`；
- 注意：VPS 为 exit node 已开 `net.ipv6.conf.all.forwarding=1`，静态配置不依赖 RA，无需改 `accept_ra`；若坚持用 SLAAC 才需要 `accept_ra=2`。

**第 4 步：验证（必须全过才收尾）**

```bash
# VPS 自身
ping6 -c 2 2606:4700:4700::1111
curl -6 -s -o /dev/null -w '%{http_code}\n' https://ipv6.google.com
# 经代理的 IPv6 路径（探针自带真实目标，别用猜的地址）
vpnctl check && vpnctl status
```

**第 5 步：撤掉客户端临时措施**

```bash
# 2026-11-09 起拦截规则是一条 catch-all（不再是五段前缀）；先备份再改
cp -a ~/.config/xray/config.json ~/.config/xray/config.json.bak-$(date +%Y%m%d)
jq '.routing.rules |= map(select(((.ip // []) | index("::/0")) == null))' \
   ~/.config/xray/config.json > /tmp/cfg.json && \
   install -m 600 /tmp/cfg.json ~/.config/xray/config.json
vpnctl validate && vpnctl restart      # 校验不过会拒绝，不会带着坏配置重启
sudo rm /etc/gai.conf
vpnctl check    # 期望 ipv6 : ok；status 的 guard 行应显示 absent
```

### 验收标准

- VPS 有全局 IPv6 与默认路由，`ping6` / `curl -6` 通；
- 经代理访问 IPv6 目标返回 HTTP 响应（不再是 curl exit 35 / 超时）；
- `vpnctl check` 输出 `ipv6 : ok`（不是 `blocked`），`vpnctl status` 无 `warn`；
- 连续 24 小时 xray 日志中 `[2001:…] unexpected EOF` 归零。

### 回滚

- 配置失败：`cp /etc/netplan/00-installer-config.yaml.bak-<日期> /etc/netplan/ && netplan apply`；
- 客户端：恢复 `config.json.bak-20261103` 并重启 xray；`/etc/gai.conf` 用 `sudo tee` 重新写入 `precedence ::ffff:0:0/96  100`。

### 已有证据（2026-11-03 实测，避免重复劳动）

- `207.56.18.51` → AS18186 Nebula Global LLC（香港），品牌 LightLayer；第三方评测页把型号 **HK-VP02-A** 列为该品牌套餐，并写明"support dual-stack IPv6"（[ittellyou 评测](https://www.ittellyou.com/en/230671.html)，2026-06-09，非官方文档）。
- whois：`2407:21c0::/32` 登记在 HONG KONG LIGHTLAYER TECHNOLOGY CO., LIMITED 名下；上游 AS18186 公告 24 条 IPv6 前缀。
- VPS 侧：eth0 仅有 `fe80::`；netplan 无 IPv6；`accept_ra=2` 观察 18 秒零 RA；`dhclient -6 -1` 主动 Solicit 25 秒无 Advertise。
- 结论：**不是系统没配，是面板/网络侧没下发**；测试痕迹已清理（`accept_ra` 复原 0、dhclient 租约文件已删）。

---

## 待办 2：把“模式切换”做成配置档，而不是每次手改 JSON

**状态**：未开始（2026-11-09 评估后暂缓，理由见 How）
**建立日期**：2026-11-09
**来源**：sing-box 配置生成器把 Direct / GFWList / Non-CN / Global 四种模式装进同一份配置，客户端运行时用 `clash_mode` 切换；本机只有一种行为，换行为 = 改 JSON + 重启，而这正是 2026-11-04 宕机的那条路径。

### What

让 `vpnctl profile list|apply <name>` 管几份预先校验过的配置档（至少：`normal`、`direct-only`、`global`），切换是原子动作：校验 → 备份 → 安装 → 重启 → 真实探测 → 失败自动回滚 —— 复用 `edit` 已有的那套机制。

### Why

- Xray 没有 `clash_mode`：“所有流量直连”“所有流量走代理”今天只能手改路由再重启，属于高风险手工操作。
- `vpnctl off` 只关系统代理，覆盖不了“应用自己无视系统代理”的场景；`global` 档是缺的。

### When

不急。等下次真需要“临时全直连/全代理”时再做，或与下次配置大改一起做。

### Where

`~/.local/bin/vpnctl`（源码 `10_design/xray-client/vpnctl.sh`）、`~/.config/xray/profiles/`、`10_design/xray-client/design.md`。

### How

1. 先确认需求：`direct-only` 是否等价于 `vpnctl off`？若等价，这份档就不必做，只需要 `global`。
2. 设计：profile = 一个 JSON patch（对基础配置做 jq 变换），而不是存整份配置 —— 避免节点/密钥出现第二份副本。
3. 实现后加离线测试（mock systemctl/curl），并在 `test_vpnctl.sh` 里覆盖“apply 失败自动回滚”。
4. 验收：`vpnctl profile apply global` 后所有流量走代理且 `check` 通过；`apply normal` 回到当前行为。

### 回滚

不改变现有默认行为；失败自动回滚到上一份配置。删除 `profiles/` 与子命令即可完全撤掉。

---

## 待办 3：用 debug 日志确认 xray 的 `dns` 模块到底有没有在客户端解析路径上

**状态**：待验证（结论目前是推断）
**建立日期**：2026-11-09
**来源**：对比 sing-box 生成器时发现：本机 `routing.domainStrategy = "AsIs"`、无 TUN，客户端由 systemd-resolved（192.168.0.1）解析，freedom 出站按域名拨号 —— 照文档推断 `dns` 模块对客户端查询不起作用。若属实，那份七条的 `dns.servers` 配置是“策略写在了不生效的地方”。

### What

用一次带 access log 的临时实例（换端口、不动线上服务、临时配置 0600 用完即删）确认：有没有 `inboundTag: dns-module` 的连接；直连域名由系统解析还是 dns 模块解析。

### Why

决定两件事：(a) `dns` 段要不要继续维护/扩写；(b) 是否值得投入做一层 DNS 应答（sing-box TUN 或本地解析器），因为只有那一层才能实现“被墙域名不被污染”和“走代理只给 A 记录”。

### How

1. 复制线上配置到 0600 临时文件，改端口 18081、加 `"log": {"loglevel": "debug", "access": "/tmp/xray-access.log"}`。
2. 前台跑 30 秒，用 `curl -x` 访问一个直连域名和一个代理域名。
3. 看 access log：目标是域名还是 IP、有没有 dns-module 记录。
4. 结论写进 `10_design/vps-tailscale-exit-node.md` §7；临时文件删除。

### 回滚

不接触线上服务与配置；临时文件用完即删。
