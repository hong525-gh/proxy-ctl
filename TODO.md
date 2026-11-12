# TODO — VPN / 代理

待办清单。每条按 5W1H 六项写齐，附验收标准与回滚，便于隔一段时间后不用回忆就能接着做。

---

## 待办 6：服务商切换新 IP 段后的迁移（等通知，清单先行）

**状态**：等服务商通知（2026-11-12 通知：207.56/207.57 段国际方向中断，新 IP 段筹备中，切换安排另行发布）
**建立日期**：2026-11-12

### What（要达成什么）

拿到新 IPv4 后，把所有引用旧公网 IP `207.56.18.51` 的地方一次性切过去，并做全量验证。
**tailnet IP（100.118.65.105）不变**，Tailscale 侧零操作（tailscaled 状态文件不受影响，无需重新授权）。

### Why

旧段国际方向被上游中断且可能直接弃用；所有指向旧 IP 的配置在切换瞬间全部失效，漏改一处就是下一次故障。

### Who

- **你**：收服务商切换通知、执行面板操作（若有）、把新 IP 发给我。
- **我**：改配置、验证、更新文档与监视。

### When

服务商发布切换安排后尽快；切换前本机继续跑机场备用（`AUTO_FAILOVER` 已兜底）。

### Where（引用旧 IP 的完整清单，切换时逐项打勾）

| # | 位置 | 改什么 |
|---|------|--------|
| 1 | 本机 `~/.ssh/config`（Host `hong`） | HostName → 新 IP |
| 2 | 本机 `~/.config/xray/config.json` | `proxy` 出站的 `address`（`proxy-ts` 指向 tailnet IP，**不用改**） |
| 3 | 本机 `~/.local/state/vpn/vps-watch.sh` | 探测目标 → 新 IP（或直接停掉该后台任务） |
| 4 | 文档 `10_design/vps-tailscale-exit-node.md` | 全文 IP 引用（§1 清单、§6 手册、§6.8） |
| 5 | VPS 侧（切换后 SSH 验证） | 确认 xray 监听 8443、ufw 仍放行、tailscaled 自动上线、dnsproxy/warp 正常（均不依赖公网 IP 值，预期零改动） |
| 6 | 手机/平板节点配置（若直连 VPS 而非 exit node） | 节点地址同步 |

### How

1. 拿到新 IP 先测可达：`ping -c 4 <新IP>`、`nc -zv -w 5 <新IP> 22`（应通；若不通先找服务商）。
2. 按上表 1→3 改本机；`vpnctl validate && systemctl --user restart xray-client`。
3. 等 `vpn-health.timer` 探到主出口恢复 → `AUTO_FAILOVER` 自动切回 primary（`vpnctl status` 的 `failover` 行应变回 primary，exit IP 变为新 IP）。
4. SSH 上新 IP 做服务端体检（设计文档 §6「服务端快速体检」五条）。
5. 全绿后更新文档与变更记录；`AUTO_FAILOVER` 保留（备用出口长期有效）。

### 验收标准

- `vpnctl status`：`failover: primary`、health ok、exit = 新 IP；`egress`/`backup` 行正常；
- SSH（新 IP）、手机 exit node、Telegram（公网路径）全部可用；
- `vpnctl use backup` / `use primary` 手动往返各一次成功（验证 failover 机制在新 IP 下仍工作）。

### 回滚

配置改动均有 `~/.local/state/vpn/backups/` 时间戳备份；`vpnctl rollback` 一键回退；旧 IP 若恢复，`~/.ssh/config` 与 `proxy` 出站地址改回即可。

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

---

## 待办 4：代理加固清单（2026-11-09 立项，来自 sing-box 配置生成器的设计对照）

排序原则：先补“看不见的故障”，再动“可能影响体感”的策略；每一件都要求离线测试先绿，再上机。
状态标记：`[x]` 已验收 / `[~]` 进行中 / `[ ]` 未开始。

### 4.1 [x] 每个出口各自自检：给 `proxy-ts` 加独立探针

- **内容**：新增只监听 `127.0.0.1:10809` 的 mixed 入站（tag `ts-in`），路由首条 `inboundTag: ts-in → proxy-ts`；`vpnctl check` 增加“经 10809 访问 `api.telegram.org`”的探针，结果写进 `health.json`（`ts_state`/`ts_code`/`ts_ms`）；`vpnctl status` 增加一行显示。
- **依据**：2026-11-05 把 Telegram 挪到 tailnet（`proxy-ts`）是为了绕开公网丢包（实测 27%–52%），但现有 `check` 的 204 探针命中的是 `geosite:google` → `proxy`，测速探针也落 `proxy`，因此 **`proxy-ts` 零覆盖**：tailnet 断掉时 `vpnctl status` 仍报 ok。这与 11-03 的 IPv6 挂起、11-04 的限速属于同一类错误——探针没覆盖用户真正感受到的那条路。
- **实现方法**：客户端配置加入站与首条路由（备份 → `vpnctl validate` → 重启 → 探测）；`policy_ok` 从“恰好一个 mixed 入站”放宽为“主入站 10808 + 额外入站必须绑 127.0.0.1”；`vpnctl` 增加 `probe_ts`/状态字段/`status` 行；离线测试用 mock curl 覆盖“探针 ok / 探针失败 / 无 ts 入站时跳过”。
- **验证**：离线测试全绿（59 项）；实机 `vpnctl status` 出现 `egress : telegram via proxy-ts: ok (http 302, ~1.3 s)`；`ss` 可见 `100.118.65.105:8443` 的 ESTAB 连接；journal 出现 `[ts-in -> proxy-ts]`。
- **实施记录（2026-11-09）**：配置备份 `~/.local/state/vpn/backups/config-20261109-104211.json`；首次探测暴露了“重启后冷启动要 ~7 s”的现象，探针因此加了一次重试（`TS_RETRY_WAIT`，默认 2 s），之后连续三次稳定在 1.27–1.36 s。
- **回滚**：删除 `ts-in` 入站与首条路由（备份文件 `~/.local/state/vpn/backups/config-*.json`）；`vpnctl` 回退备份。

### 4.2 [x] 规则顺序离线真值表（借 `dnswalk` 的思路）

- **内容**：在 `test_vpnctl.sh` 里加一个 jq 规则评估器 + 表驱动用例：给定（网络/端口/目标/标签集合/入站标签），按顺序算出命中的 `outboundTag`，断言与期望一致；用例覆盖内网 IPv6、国内 IP、国外 IPv6 字面量、Telegram 域名、国内域名、DNS 模块查国内/国外 DNS、未知域名。
- **依据**：2026-11-09 的 IPv6 改造把 13 条规则重排过，顺序本身携带语义；现有测试只断言“守卫存在”，无法发现“某类目标被前一条规则抢先命中”。
- **实现方法**：评估器用 jq 写在测试文件内（不新开语言文件），把 `geosite:X`/`geoip:X` 映射为用例标签；另用一份故意颠倒顺序的 fixture 证明评估器有判别力（期望不一致时测试必须失败）。
- **验证**：`bash test_vpnctl.sh` 全绿；把 `::/0` 规则挪到最前面后，三条 IPv6 用例（内网、国内、DNS 模块）必须被判为 `block`，测试通过说明评估器有判别力。
- **实施记录**：T20 共 14 个用例（内网/国内/国外 IPv6 字面量、Telegram/国内/Google/未知域名、DNS 模块查国内与国外 DoH、direct-dns 入站、ts-in 出口、内网与国外 IPv4 字面量），`check` + `flip` 两种模式都通过。
- **回滚**：只改测试文件，`git revert` 即可。

### 4.3 [x] 写清“这套配置不保护什么”

- **内容**：design.md 新增“已知局限”一节：不走系统代理的应用完全不受控；浏览器自带安全 DNS 可绕过分流；未走代理的域名由路由器解析（可能污染）；非代理应用的 IPv6 不受 catch-all 约束；单节点单服务器；无 per-app 分流；`dns` 段当前不在解析路径上。
- **依据**：项目把“不提供什么、为什么”写进 DESIGN.md（如“暂不提供走代理也用 IPv6”），避免使用者误判覆盖面；我们的文档目前只写“做了什么”。
- **实现方法**：逐条对照配置与实测写出，每条给证据（配置字段/命令）；不写未验证的结论。
- **验证**：每条都能指向配置字段或实测；与 4.4 的测量结论一致。
- **实施记录**：写入 `design.md` §11.1，共 9 条（不走系统代理的应用、浏览器 DoH、未走代理的域名解析、非代理应用的 IPv6、国内 IPv6 被全局压掉、单节点、tailnet 单路径、无 per-app 分流、健康检查时延）。
- **回滚**：纯文档。

### 4.4 [x] DNS 是否在路径上：实测与决策（结论：A1）

- **内容**：用临时实例（换端口、access log、临时配置 0600、用完即删）统计 3 个事实：①是否出现 `inboundTag: dns-module` 的连接；②经过代理的连接里有多少落到 final `proxy`；③直连域名由谁解析。据此决定：A1 冻结/删除 `dns` 段并承认“纯域名分流”，或 A2 改 `domainStrategy: IPIfNonMatch` 让 `geoip:cn` 对域名生效、并把 `dns` 段升级成项目那套形状。
- **依据**：`routing.domainStrategy = AsIs` + 无 TUN + 出站全部 IP 字面量 → 按文档推断 `dns` 段没有消费者；但这只是推断，未抓过日志。
- **实现方法**：`jq` 复制线上配置到 `mktemp`（0600），改端口 18081、加 `log.access`，前台跑 60 秒并用 `curl -x` 造样本，读日志后删除临时文件。
- **验证**：日志结论与推断一致或不一致都写进文档；决策必须引用日志行。
- **回滚**：不接触线上服务与配置。
- **结果（2026-11-09）**：临时实例（端口 18081、access log、0600、用完即删）跑 5 条流量：
  `www.baidu.com → direct`、`www.google.com → proxy`、`example.org → proxy（final）`、
  `www.taobao.com → direct`、`223.5.5.5 → direct`；**access log 中 `dns-module` 出现 0 次**，
  且目标一律以**域名**形式记录（说明 xray 没有为路由解析域名，与 `domainStrategy: AsIs` 一致）。
- **决策：A1**——承认“纯域名分流”，不启用 `IPIfNonMatch`。理由：启用会让 DNS 模块变成
  关键路径，而当前 DNS 层没有能力实现项目那套策略（远程解析、AAAA 置空），收益只是
  “不在 geosite:cn 里的国内域名少走一次香港”，代价是每个未命中连接多一次解析、且解析
  故障会直接影响分流判断。**残留未知**：错分流的比例没有长期数据；若要量化，用同一方法
  把浏览器代理指向 18081 采集一天。

### 4.5 [x] `gai.conf` 去留（结论：保留，理由已修正）

- **内容**：评估 `/etc/gai.conf` 的全局 IPv4 优先是否还需要：catch-all 已让代理路径的 IPv6 在 8 ms 内失败，而 gai.conf 同时压掉了国内 IPv6。
- **依据**：项目把 IPv6 策略**限定在会走代理的域名**上；全局压 IPv4 是把策略作用到了不该作用的目标。
- **实现方法**：先测“去掉后国内双栈站点是否走 IPv6、代理站点是否仍快速回落”，再决定保留、删除或收窄；不改变其他设置。
- **验证**：给出保留/删除的证据；若删除，`/etc/gai.conf` 备份到 `/etc/gai.conf.bak-20261109`。
- **回滚**：恢复备份文件。
- **结果（2026-11-09）**：`getent ahosts www.baidu.com` 返回 IPv4 在前（证明 gai.conf 确实在
  影响 glibc 的 `getaddrinfo`）；但 Chromium 用自带解析器、xray 的 freedom 是 Go 写的
  （Go 不读 gai.conf），所以 **gai.conf 只作用于“不走代理的 glibc 程序”**，对经 xray 的流量
  无影响。结论：**保留**。它防的是“非代理应用直连 IPv6 挂起”，这正是 11-03 那 3,105 次
  EOF 的场景；代价（国内双栈站点不走 IPv6）只落在同一批 glibc 程序上，范围比原先估计的小。
  原计划“撤掉它换国内 IPv6”收益不成立，故不执行。

### 4.6 [x] 健康探针必须走它声称测试的那条路（2026-11-09 执行 4.1 时发现）

- **内容**：`vpnctl check` 的 204 探针目标 `https://www.gstatic.com/generate_204` 被 `geosite:cn` 命中，**实际走的是 `direct`**；也就是说隧道挂了、探针照样返回 204（日志实证：`//www.gstatic.com:443 [socks -> direct]`）。修法：新增 `127.0.0.1:10810` 的诊断入站 `probe-in`，路由首条固定 `inboundTag: probe-in → proxy`，204 探针、出口 IP、测速全部改走 10810（配置里没有 `probe-in` 时回退到 10808）。
- **依据**：与 4.1 同一条原则——“让这个出口工作的流量，必须在这个出口上验证”。`geosite.dat` 的分类会变，任何“靠域名分类碰巧走代理”的探针都是不可靠的。
- **实现方法**：配置加入站 + 首条路由；`policy_ok` 允许并按同样规则校验 `probe-in` 与它的路由配对；`vpnctl` 增加 `health_port()`；`status` 显示探针是否已固定；测试覆盖“有 probe-in / 没有 probe-in 回退 / 端口写错被拒”。
- **验证**：journal 出现 `[probe-in -> proxy]`；临时把服务停掉（或 `vpnctl off`）时探针必须失败而不是 204。
- **回滚**：删除 `probe-in` 入站与路由；配置备份见 `~/.local/state/vpn/backups/`。
- **实施记录（2026-11-09）**：配置备份 `config-20261109-105305.json`；实机验证 journal 出现
  `//www.gstatic.com:443 [probe-in -> proxy]`、`//api.ipify.org:443 [probe-in -> proxy]`、
  测速 `[probe-in -> proxy]`；`status` 显示 `probe   : pinned to proxy via 127.0.0.1:10810`。
  测试 T22 覆盖“固定 / 回退 10808 / 端口写错被拒”，总数 59 → 63。

### 4.7 [ ] 可观测性：Xray `api` + `stats`（暂缓）

- **内容**：在 `127.0.0.1` 开 Xray 统计接口，让 `vpnctl` 能回答“多少流量走了 `proxy-ts` / `proxy`”。
- **依据**：项目可选 Clash API 观察连接走向；我们目前只能靠 `ss` 猜。
- **实现方法**：加 `api`/`stats`/`policy` 段，`vpnctl stats` 子命令查询并格式化；需确认 26.3.27 的 stats 字段名。
- **状态**：**暂缓**——4.1 的探针已经能覆盖“这条路通不通”，统计属于“有更好”；等需要长期观测双出口比例时再做。
- **验证 / 回滚**：同上，配置备份 + 删除段落。

---

## 待办 5：`ts.net → 199.247.155.53` 的归属（结论：无法也不需要删除）

**状态**：已关闭（2026-11-09，用 Tailscale API 核实）
**建立日期**：2026-11-09

### 结论

这条记录**不是**用户添加的 Split DNS，而是 **Tailscale 自己下发的**：它是 `ts.net` 域名的公网权威服务器
（DNSimple，IPv4 `199.247.155.53` + IPv6 `2620:111:8007::53` 两条一起出现），随 MagicDNS 一起下发给每台设备，
并且在设备使用 exit node 时由 `ExitNodeFilteredSet`（含 `.ts.net`、`.tailscale.net`）排除，不会把 MagicDNS 名字送进隧道。
所以后台里找不到它、也没有可删的条目。

### 证据（2026-11-09）

| 检查 | 结果 |
|---|---|
| `GET /api/v2/tailnet/-/dns/split-dns` | `{}`（用户没有配置任何受限解析器） |
| `GET /api/v2/tailnet/-/dns/config` | `resolvers: [100.118.65.105]`、`routes: null`、`domains: null`、`proxied: true` |
| `tailscale dns status --json`（Fedora 与 VPS 一致） | `SplitDNSRoutes: {"ts.net.": [199.247.155.53, 2620:111:8007::53]}`、`SearchDomains: ["tail61cf19.ts.net"]`、`ExitNodeFilteredSet: [".ts.net", ".tailscale.net"]` |

API 里 `domains: null` 而客户端有 `SearchDomains: tail61cf19.ts.net`——两者对比说明：**API 反映的是“用户配置”，
客户端拿到的是“用户配置 + MagicDNS 自动条目”**。`ts.net` 的路由和搜索域都属于后者。

### 影响

- 设备名（`*.tail61cf19.ts.net`）由 MagicDNS 在本地解析，`100.100.100.100` 能返回正确地址；这条路由只服务**非设备**的
  `*.ts.net` 名字（跨 tailnet 解析），属正常设计。
- 退出节点场景下它被过滤，不参与解析。

### 如果当初确实在后台加过

那它已经被删掉或从未保存成功；当前 API 显示用户配置为空，后台 `console.tailscale.com/admin/dns` 里也不会有可删的行。
**不需要再做任何操作。**

