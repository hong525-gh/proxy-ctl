# VPS Tailscale Exit Node 与远程访问架构（2026-10-28 建立，10-29 修订）

2026-10-28 完成部署与体检；2026-10-29 处理"代理断连 + VPS tailnet 掉线"事件并修订。
本文档不含任何密钥/UUID/token；密钥位置见文末「安全说明」。

## 1. 设备与地址清单

| 设备 | tailnet 名称 | Tailscale IP | 备注 |
|------|-------------|--------------|------|
| 本机 Fedora | `fedora` | `100.105.202.118` | dsh Web UI 宿主机 |
| 境外 VPS（香港，1C/1G/50G/10M 不限流量，HK-VP02-A） | `vm-z4ziutm3` | `100.118.65.105` | exit node + xray 代理同机 |
| 手机 OnePlus | `hong-oneplus-2v` | `100.81.67.71` | 经 exit node 上 Google |
| 平板 OPPO | `oppo-pad-mini` | `100.119.198.113` | — |

- VPS SSH 从本机连接，别名：`hong`（配置在 `~/.ssh/config`，公网 IP `156.238.127.216`
  （2026-11-13 由 `207.56.18.51` 迁移而来，旧段 207.56/207.57 被服务商退役，过渡期内
  旧 IP 仍挂在 eth0 上），端口 22，用户 `hong525`，仅密钥登录）。
- VPS 系统：Ubuntu 22.04.1 LTS，x86_64。
- **VPS 有 ufw 防火墙（10-29 才发现）**：INPUT 默认 DROP，只放行 22 和代理端口。
  代理换端口时必须同步 `sudo ufw allow <端口>/tcp`，否则换完即死。

## 2. VPS 上的 Tailscale（exit node）

- 安装：官方脚本 `curl -fsSL https://tailscale.com/install.sh | sh`，版本 **1.104.4**
  （commit 9382131983ca16de1357091618fd903e35db3c4e），systemd `tailscaled` 常驻。
- IP 转发持久化在 `/etc/sysctl.d/99-tailscale.conf`：

  ```
  net.ipv4.ip_forward = 1
  net.ipv6.conf.all.forwarding = 1
  ```

- 入网与声明 exit node（2026-10-28 执行过一次，浏览器交互授权完成）：

  ```bash
  sudo tailscale up --advertise-exit-node --accept-dns=false
  ```

- **admin 后台批准（每次重装/重置后必须重做）**：
  [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
  → `vm-z4ziutm3` → Edit route settings → 勾选 Use as exit node。
- **DNS 解耦（重要坑，2026-10-28 已修）**：`tailscale up` 默认用 MagicDNS 接管
  `resolv.conf`（写入 `nameserver 100.100.100.100`），会让 VPS 上 xray 的 freedom
  出站解析依赖 tailscaled 进程。已用 `--accept-dns=false` 修复。**以后在 VPS 上
  重跑 `tailscale up` 时必须带 `--accept-dns=false`，否则坑会回来。**
- **系统 DNS 现状（2026-10-29 起）**：`resolv.conf` 为 `223.5.5.5` + `114.114.114.114`。
  原因：这台三网优化机器到 8.8.8.8 / 1.1.1.1 的 **UDP 53 被掐死**（实测超时），
  原配置（10-11 遗留）只有 8.8.8.8 一个且无备用，等于全机失解析。
  备份在 `/etc/resolv.conf.bak-20261029`。**注意**：中国公共 DNS 对 Google 等被封域名
  会返回污染答案（实测 www.google.com 解析到 Facebook 段 IP），所以 xray 服务端
  不能依赖系统 DNS——已在 xray 配置内置 DoH 解决（见第 5 节）。
  `resolv.conf` 是普通文件，重启后可能被 cloud-init/DHCP 覆盖复原；若复发需改
  netplan/systemd-resolved 做永久固化。
- **tailnet 全局 DNS（2026-10-29 部署）**：VPS 上运行 dnsproxy（v0.86.0，
  `/usr/local/bin/dnsproxy`，systemd `dnsproxy.service`），仅监听
  `100.118.65.105:53`，上游为 DoH（`https://1.1.1.1/dns-query`、
  `https://8.8.8.8/dns-query`），带缓存与乐观缓存，`--ipv6-disabled`（本机无
  IPv6 路由，强制 A 记录避免客户端空等）。用途：tailnet 全局 nameserver 指向它后，
  各设备 DNS 查询全程在 WireGuard 隧道内到 VPS，再经 DoH 出境——UDP 53 不暴露在
  易被掐的路径上，也不经中国 DNS（无污染）。admin 后台 DNS 页将 nameserver 设为
  `100.118.65.105` 并开 Override local DNS 后生效。
  来源与哈希：GitHub AdguardTeam/dnsproxy v0.86.0（2026-10-01），
  `dnsproxy-linux-amd64-v0.86.0.tar.gz` sha256
  `17ac43f76ebfcedf547c663f6f31aa70e68b8eb6fc41d2fc37d3bfe21a2ced66`（下载时校验通过）。

### 客户端使用

- 手机：Tailscale app → Use exit node → 选 `vm-z4ziutm3`。
  注意 Android 端 "App split tunneling" 里勾选的应用是**绕过** Tailscale（语义是反的），
  浏览器不要勾选，否则既出不了境也访问不了 tailnet。
- Fedora 临时接管全部流量（一般不用，见第 4 节决策）：

  ```bash
  sudo tailscale up --exit-node=vm-z4ziutm3 --exit-node-allow-lan-access
  # 切回：
  sudo tailscale up --exit-node=
  ```

## 3. 手机访问 Fedora 的 dsh Web UI

dsh 版本 0.2.1-rc.2。配置在 `~/.dsh/profiles/web/cordis.patch.yml`（2026-10-28 追加，
原有 llm-deepseek 等条目保留）：

```yaml
- id: webserver
  config:
    host: '100.105.202.118'
    port: 3080
```

原理与坑（均已在源码中核实）：

- webserver 加载器在**载入时**拒绝通配地址（`0.0.0.0`），不是只有 CLI 拒绝
  （`dsh-host-webserver/lib/index.js:255`）。绑 tailscale0 的具体 IP 既过校验，
  又只暴露给 tailnet，比 `0.0.0.0` 更安全。
- 监听 IP 自动通过 /api 信任栅栏，**不需要** `trustedHosts`（该键属于 `connection`
  加载器，写在 `webserver` 下无效）。
- Tailscale IP 若变化需同步改此文件（`tailscale ip -4` 查新值）。
- 防火墙无需配置：`tailscale0` 落入 firewalld 默认 zone `FedoraWorkstation`，
  该 zone 已放行 `1025-65535/tcp`。

使用方式：Fedora 上 `dsh web --no-open` 启动后，**必须用终端打印的带
`?token=...` 的完整 URL 访问**（token 每次启动重新生成、只存在内存里，
直接访问根路径会 401）。手机打开一次后种下 cookie，之后裸地址即可。

注意：本机 shell 有全局代理（`http_proxy=127.0.0.1:10808`），本机自测 dsh 要加
`curl --noproxy '*'`，否则结果是代理伪造的假象。

## 4. 架构决策：手机走 exit node，Fedora 保留智能分流代理

2026-10-28 讨论定调。依据：

- **同机同管**：xray 代理和 Tailscale exit node 都在这台 VPS 上，共享同一个
  10M 端口和同一个 IP——带宽、单点故障两者等价，不构成选择依据。
- **分水岭是分流粒度**：Fedora 现有 xray 客户端是 GFW-list 智能分流（国内直连满速）；
  Tailscale exit node 是全有或全无，国内 CDN 流量（dnf/docker/aria2/B站）会被拖进
  10M 香港管子。Linux 桌面端没有官方 per-app 分流（该功能 Android 独占，
  官方文档：tailscale.com/docs/features/client/android-app-split-tunneling；
  Windows 同类需求 github.com/tailscale/tailscale/issues/15489 仍 open）。
- **指纹**：xray 的 TLS 伪装 vs WireGuard 可识别的 UDP 握手——跨境 UDP 晚高峰
  被 QoS 是常态（当晚实测有丢包）。
- 手机受 Android 单 VPN 槽限制，代理 app 与 Tailscale 不能共存，exit node 是唯一解。

实测数据（2026-10-28 晚高峰 ~20:20）：Fedora↔VPS 初为 DERP 香港中继（282ms），
NAT 打洞后转 UDP 直连（214ms，4 包丢 1）；tailnet 隧道吞吐下行 9.6 Mbps /
上行 8 Mbps（跑满 10M 端口）。

## 5. VPS 代理配置（2026-10-29 重大变更：端口 443→8443 + 内置 DoH）

服务端 xray（`/usr/local/etc/xray/config.json`，systemd `xray.service`）：

- VLESS + XTLS Vision（`xtls-rprx-vision`）+ **Reality**，decoy `www.nvidia.com`
  （实测 TLS 1.3 + HTTP/2 健康）。xray 26.3.27；内核 BBR + fq 已开；sniffing 已开；
  BT 出站已封；日志 loglevel warning（走 journald，`/var/log/xray/*.log` 为空属正常）。
- **端口 8443**（2026-10-29 自 443 改来，原因见第 6 节事件记录）。ufw 已放行
  8443/tcp；443/tcp 的 ufw 规则保留未删，便于回滚。
  **注意 xray 官方警告**：Reality 监听非 443 端口本身是一个弱特征
  （"Listening on non-443 ports may get your IP blocked by the GFW"）——
  若 8443 再次被干扰，考虑换回 443 或换 IP，不要无限换端口。
- **内置 DoH（2026-10-29 新增）**：顶层 `"dns"` 模块，servers 为
  `https://1.1.1.1/dns-query`、`https://8.8.8.8/dns-query`、`localhost`（兜底）；
  freedom 出站 `domainStrategy: "UseIPv4"`（强制 IPv4，本机无 IPv6 路由）。
  原因：系统 DNS（中国公共 DNS）对 Google 等域名返回污染答案，
  而干净 DNS 的 UDP 53 在此机被掐、DoH（TCP 443）畅通。xray 出站解析自此
  不依赖系统 DNS。
- Fedora 客户端（`~/.config/xray/config.json`）：`fingerprint: chrome`、
  `mux.enabled: false`、服务器端口已同步为 8443。备份 `config.json.bak-20261029`。
- **手机端若也直连此节点（非 exit node 方式），节点配置里的端口要同步改成 8443。**
- SSH 加固：`PermitRootLogin no`、仅密钥登录；2026-10-28 清理了 sshd_config
  第 124 行的死配置 `PasswordAuthentication yes`（生效的一直是第 58 行的 no）。

## 6. 故障排查手册 + 2026-10-29 事件记录

「断联」定位三步法（断联发生当下在 Fedora 执行）：

```bash
ping -c 4 207.56.18.51                            # IP 层是否被墙
curl -v telnet://207.56.18.51:8443 --max-time 5   # 代理端口可达性
```

- ping 通 + 端口通 + 代理仍断 → 进服务端查 DNS（见下）
- ping 通但端口不通 → 端口被定向封锁
- ping 不通 → IP 被临时封锁或 VPS 商网络问题

服务端快速体检（SSH `hong` 后执行，均无需 sudo）：

```bash
systemctl status xray --no-pager | head -12   # 运行时长/重启
uptime; free -h                                # 负载/内存
tailscale status                               # tailnet 连通
grep -v "^#" /etc/resolv.conf                  # 系统 DNS 是否被覆盖
dig +time=3 +tries=1 www.google.com A +short   # DNS 污染检查：答 142.2*/172.2* 等才正常；
                                               # 答 31.13.*（Facebook 段）或 2001::1 即被污染
```

### 2026-10-29 事件：代理断连 + VPS tailnet 掉线（三个叠加根因）

1. **系统 DNS 死亡**：resolv.conf 唯一的 8.8.8.8 的 UDP 53 被掐（1.1.1.1 同样死，
   中国 DNS 畅通）→ 全机失解析 → xray 出站解析失败（代理断）、tailscaled 无法
   重连控制面（节点掉线）。修复：换 223.5.5.5 + 114.114.114.114。
2. **DNS 污染（修复 1 后暴露）**：中国公共 DNS 对 www.google.com 返回 Facebook 段
   假 IP → 代理链路通但 Google 仍打不开。修复：xray 内置 DoH + UseIPv4。
3. **控制面 TLS 路径延迟**：VPS→controlplane.tailscale.com（美国）TCP 秒连但
   TLS 握手被延迟 ~5.5s（GitHub 仅 0.18s，目的地特异性；ICMP/MTU 均正常），
   超过 tailscaled 登录超时（约 5s，无环境变量可调）→ tailscaled 反复登录失败。
   **无服务端解法，等路径自愈；tailscaled 永久重试，状态文件完好，恢复后自动上线，
   无需重新浏览器授权。**
   教训：tailscaled"半掉线"（控制面断、数据面活）时**不要轻易重启 tailscaled**——
   重启后数据面也断，且重登依赖当时不可用的控制面。

**复盘修正（2026-10-29 晚，回答"是否与 exit node 有关"时补记）**：

- 当天上午曾把代理故障归因为"GFW 对 IP:443 定向干扰"，**复盘后认为该诊断证据不足**：
  openssl 直连 443 秒通（链路层健康）；失败均表现为连接建立后挂起
  （符合服务端 DNS 重试风暴特征，openssl 测试不经过服务端 DNS）；换端口后
  并未先用未污染域名（gstatic）单独验证 443 是否恢复，无法排除"换端口并非必要"。
- 当日夜间实测 8.8.8.8 / 1.1.1.1 的 UDP 53 **已自行恢复**（返回正确 Google IP）——
  说明 UDP 53 死亡是数小时的瞬时路径/服务商问题，不是定向封锁。
- 结论：本次代理故障主因是 **DNS 连锁故障**（UDP53 瞬时死亡 → 换中国 DNS →
  撞上污染 → 内置 DoH 根治），与手机走 exit node **大概率无直接因果**。
  旁证：整个故障期间 UDP 41641（tailnet）始终畅通（74ms pong），IP 未被整体拉黑。
  但因无 GFW 侧数据，无法 100% 排除 exit node 流量画像的间接影响。
- tailscaled 于当日傍晚自动重连上线（如预判，无需重新授权），exit node 恢复可用。

### 2026-11-03 IPv6 复测结论

- VPS 无任何全局 IPv6：netplan 只有 IPv4 段；`accept_ra` 置 2 观察 18 秒仍**收不到任何 RA**，说明该线路没有 IPv6 分配（不是被 forwarding 抑制）。
- 因此「给 VPS 开 IPv6」这条路堵死，除非向服务商申请 /64；客户端侧改为：优先 IPv4（gai.conf）+ 对 Telegram/Google 的 IPv6 前缀做快速拦截。
- 若日后服务商分配了 IPv6：先删掉 xray 的首条 block 规则、再删 `/etc/gai.conf`，然后 `vpnctl check` 应显示 `ipv6 ok`。
- **跟进项**：向服务商咨询/申请 IPv6 这件事已整理成待办，见 `../TODO.md` 待办 1（含工单措辞、配置步骤、验收标准与回滚）。

## 6.5 WARP 出口分流（2026-11-04）

**问题**：2026-11-04 早晨用户报「代理又开始卡」。实测（全部在 VPS 上直接跑，不经隧道）：

| 目标 | 路径 RTT | 单连接吞吐 |
|---|---|---|
| Cloudflare（speed.cloudflare.com / cdnjs） | 5.3ms | **37–46 KB/s** |
| OVH（proof.ovh.net，绕远 176ms） | 176ms | **319 KB/s** |

低延迟 + 低吞吐，且 4 并发时每条仍约 36 KB/s（合计 145 KB/s），判断为**到 Cloudflare/Fastly 方向的单流限速**，不是丢包、不是距离、不是隧道问题（本机↔VPS 0% 丢包、RTT 215ms、4 并发隧道合计约 750 KB/s）。

**处置**：在 VPS 上装 Cloudflare WARP（免费），以 `proxy` 模式提供本地 SOCKS5（127.0.0.1:40000），再让 VPS 的 xray 把 Cloudflare / Fastly / GitHub 的流量走这个出站。

```json
// /usr/local/etc/xray/config.json（备份 config.json.bak-20261104-warp）
"outbounds": [..., {"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}}],
"routing": {
  "domainStrategy": "IPIfNonMatch",          // 没有它 ip 规则不会对域名生效
  "rules": [
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
    {"type":"field","domain":["github.com","githubusercontent.com","githubassets.com","github.io","githubapp.com","ghcr.io"],"outboundTag":"warp"},
    {"type":"field","ip":["geoip:cloudflare"],"outboundTag":"warp"},
    {"type":"field","ip":["geoip:fastly"],"outboundTag":"warp"}
  ]
}
```

**效果**（同一时段、经隧道实测）：

| 目标 | 改前 | 改后 |
|---|---|---|
| cdnjs（Cloudflare） | 36 KB/s / 18.5s | **304 KB/s / 2.2s** |
| speed.cloudflare.com | 41 KB/s | **233 KB/s** |
| github.com | 54 KB/s / 9.7s | **250 KB/s / 2.1s** |
| OVH（对照组，非 CF/Fastly） | 278 KB/s | 278 KB/s（未受影响） |

**保活**：`/usr/local/bin/warp-keepalive` + `warp-proxy.timer`（每 1 分钟检查 `warp-cli status`，掉线就重连）。已实测：手动 `warp-cli disconnect` 后跑一次 keepalive 即恢复 `Status update: Connected`。

**回滚**：`sudo cp /usr/local/etc/xray/config.json.bak-20261104-warp /usr/local/etc/xray/config.json && sudo systemctl restart xray`；WARP 本身 `sudo systemctl disable --now warp-proxy.timer && sudo warp-cli disconnect`（卸载：`sudo apt remove cloudflare-warp`）。

**注意**：WARP 官方定位是「个人设备客户端」，装在服务器上做出站属灰色用法，且依赖 UDP 2408；若服务商策略变化可能失效。失效时的表现是「Cloudflare/Fastly/GitHub 打不开或很慢（socks 出站不可用）」，其余站点不受影响——此时上面的回滚可立刻恢复原状。

## 6.6 Telegram 分流走 Tailscale（2026-11-05）

**问题**：2026-11-04 傍晚与 2026-11-05 清晨，Fedora → VPS 的公网路径出现成片丢包（60 包采样丢包 27.5% / 52.5% / 46.7%，RTT 稳定 216 ms；`mtr` 显示丢包集中在第 7 跳 `219.158.7.21` 联通国际出口 86.7%，其后 NTT 各跳干净）。后果：每条新连接都要对 VPS 重做一次 TCP + REALITY 握手，`mux` 关闭时 SYN 重传把握手从 0.2 s 拉到 1–3.4 s（10 次采样 8 次 > 1 s）；`tg_jlpt_bot` 的 `sendMessage` 撞 10 s `CONNECT_TIMEOUT`，长轮询卡过 120 s 触发看门狗重启（当日 03:32、03:36、06:17、06:22、06:27）。

**思路**：Tailscale 始终维持一条长连接（WireGuard UDP 或 DERP 中继），应用新建的连接只在隧道内部开流，**不需要在丢包链路上重新握手**，正好避开该故障点。同条件下实测：坏窗口里 3 MB 传输走公网 44.8 s（~67 KB/s），走 Tailscale 5.46 s（~550 KB/s）；链路恢复后两条路基本持平（Telegram 302 / 1.9 s，2 MB 吞吐 625 vs 635 KB/s）——即 Tailscale 不是更快，而是更抗抖动。

**改动**（Fedora 客户端 `~/.config/xray/config.json`，备份 `config.json.bak-20261105`）：

```jsonc
// outbounds 追加：与 proxy 出站逐字段相同，仅 tag 与地址不同
{"tag":"proxy-ts","protocol":"vless",
 "settings":{"vnext":[{"address":"100.118.65.105","port":8443,
   "users":[{"id":"<与 proxy 相同的 UUID>","encryption":"none","flow":"xtls-rprx-vision"}]}]},
 "streamSettings": { /* REALITY 参数与 proxy 完全一致 */ }}

// routing.rules：只改 Telegram 两条规则的目标，其余不动
// rule 2  domain=[geosite:telegram, domain:telegram.org, telegram.me, t.me, telesco.pe] -> proxy-ts
// rule 3  ip=[geoip:telegram] -> proxy-ts
```

`proxy` 仍是 outbounds 第一项（未匹配流量的默认出口），Google/其它域名照旧走 `proxy`。

**验证**：

```bash
XRAY_LOCATION_ASSET=$HOME/.local/share/xray xray run -test -c /tmp/xray-candidate.json   # Configuration OK.
systemctl --user restart xray-client.service
ss -tn | grep 100.118.65.105:8443      # 隧道确实建在 tailnet 地址上
journalctl --user -u xray-client -f | grep accepted   # Telegram -> proxy-ts，Google -> proxy
```

已实测：`//api.telegram.org:443 [socks -> proxy-ts]`，`//www.google.com:443 [socks -> proxy]`，Telegram 10/10 成功，6 条 ESTAB 连接落在 `100.105.202.118 → 100.118.65.105:8443`。

**代价与回滚**：

- Tailscale 目前走 **DERP(hkg) 中继**（`tailscale ping` 显示 `via DERP(hkg)`，非直连 UDP）。若 DERP 或控制面不可用，Telegram 流量会一起断，其余流量不受影响；需要自动回退时可加 Xray `observatory` + `balancer`（`fallbackTag: proxy`），当前未启用。
- 回滚：`cp ~/.config/xray/config.json.bak-20261105 ~/.config/xray/config.json && systemctl --user restart xray-client.service`。

## 6.7 2026-11-09 平板 DNS 失效：客户端版本，不是服务器

**症状**：平板（OPPO Pad Mini，Android 16 / ColorOS 16）连上 Tailscale 后弹出
`dns-forward-failing: DNS unavailable / Tailscale can't reach the configured DNS servers`；
浏览器打不开 Google 与 X（推特），但 Telegram 正常；通过 tailnet 的 `100.105.202.118:3080`
访问 dsh 正常。手机（同一 tailnet、同一 exit node）一切正常。

**排查过程**：

1. 服务器侧先排除：`dnsproxy` 自 2026-10-29 起零重启、监听 `100.118.65.105:53`、UDP/TCP 均可查，
   从 VPS 本机与从 Fedora 经 tailnet 都能毫秒级解析出干净结果；VPS 与 Fedora 的
   `tailscale status --json` 里 `Health` 均为空。
2. exit node 转发规则核对：`net.ipv4.ip_forward=1`；`FORWARD` 首条为 `-j ts-forward`，
   内含 `-i tailscale0 … MARK` + `ACCEPT`；`POSTROUTING` 首条为 `-j ts-postrouting`，
   内含 `MARK … MASQUERADE`；ufw 默认 `deny (routed)` 但 `ts-*` 链先于 `ufw-*` 链执行，
   而且 `INPUT` 首条 `-j ts-input` 让 tailnet 流量（含 53 端口）先被接受。
3. **抓包定性**（VPS 上 `tcpdump -ni tailscale0 "host <平板 tailnet IP>"`）：平板发往
   `1.1.1.1:443` 的 SYN 9 个、SynAck 9 个、带数据包 89 个 —— 数据面经 exit node 完全正常；
   但发往 `100.118.65.105:53` 的 DNS 包 **0 个**。
4. 结论：包没出设备，是**客户端自己的 DNS 转发器**没把查询送进隧道。
   补充（官方文档，2026-11-09 核对）：设备使用 exit node 时，Tailscale **默认让出口节点代答所有域名的 DNS**，
   不受全局/受限解析器配置影响——所以抓包里本就不该出现发往 `100.118.65.105:53` 的查询，出口节点侧才是
   当时的解析路径。旧客户端在这条“出口节点代答”的路径上失效，升级后恢复。

**根因**：平板 Tailscale **1.102.3** 在 **Android 16** 上 DNS 转发器失效（数据面正常、
DNS 面不工作）。升级到应用商店最新版后立刻恢复。

**预防**：

- 移动端 Tailscale 与桌面/VPS 保持同一版本线（当时桌面 1.104.5、VPS 1.104.4、平板 1.102.3）。
- 遇到“IP 能通、域名不通 + `dns-forward-failing`”时，先看客户端版本，再抓包确认 DNS 是否离开设备；
  不要先怀疑服务器 —— 本次服务器完全无辜。
- 抓包是判定“设备侧 / 服务器侧”的最快手段：看发往解析器的 53 端口包存不存在，一眼定性。

**清理**：抓包进程已停止，`/tmp/pad-cap.log` 已删除；VPS 上未留下临时文件。

### 2026-11-12 事件：上游国际方向中断（207.56/207.57 段）+ 机场备用上线

**症状**：约 04:36 起 VPS 全球不可达。`vpn-health.timer` 连续失败（08:10 时 62 轮）；tailnet 显示 `offline`（本机 `tailscale ping` 超时，tx 10920 rx 0）；本机对 `207.56.18.51` 的 ping / TCP 22 / TCP 8443 全部超时。

**排查与证据链**（当日完成，方法可复用）：

1. **机器活着**：check-host.net 全球多点探测，仅雅加达节点可通——ICMP 48ms、**TCP 22 连接 49ms**（sshd 正常应答）；其余节点（港/美/加/英/瑞/荷/伊朗等）全部超时。→ 不是机器死，不是 GFW（无法解释海外节点失败）。
2. **出站选择性黑洞**（VNC 控制台实测，20 包定量）：`8.8.8.8` 0% 丢包 4.3ms 且 mtr 全程干净；`1.1.1.1` 与 `114.114.114.114` 稳定 100% 丢包；`223.5.5.5` 可达但 RTT 劣化到 ~118ms（平时 ~30ms），路径绕上海电信。→ 上游对特定前缀黑洞/清洗，不是整体断网。**教训：4 包 ping 是抛硬币，定性要 20 包。**
3. **Tailscale 掉线的直接原因**：VPS 上 `dig controlplane.tailscale.com` 解析正常（192.200.0.x），但 `curl` 000 超时，`tailscale netcheck` 连 DERP map 都拉不下来。→ 控制面前缀落在被黑洞段里；DERP「自动中转」救不了——中继要求 VPS 自己先出得去（中继只改变会面地点，不消除到达会面地点的要求）。
4. **入站定性（决定性证据）**：VPS 上 `sudo tcpdump -ni any host <家庭IP> -c 20` 抓包期间，本机发出 18 个包（6 ICMP + 6 SYN:22 + 6 SYN:8443），结果 **0 packets captured / 0 received by filter**。→ 入站流量在到达网卡之前就被上游丢弃。

**根因**（服务商当日通知原文要点）：「由于上游供应商出现技术故障，目前涉及 **207.56、207.57 IP 段的国际方向网络已中断**……正在协调新的 IP 地址段，切换安排另行通知。」与排查结论逐点吻合。

**客户端应对（当日已上线，详见 `xray-client/design.md` §6.11）**：

- xray-client v1.2.0：机场 trojan 节点（新加坡中转2）作为 strict 备用出口，`AUTO_FAILOVER=1` 下首轮 check 即自动切换，exit IP 变为机场节点；VPS 恢复后自动切回。
- 两个实机教训：① 新加坡中转1 对 Google 系站点挂起（其他正常），换中转2 全通——备用节点以实测为准；② 路由表里 `geosite:google → proxy`、`telegram → proxy-ts` 这类 pin 在 backup 模式下会把流量钉在死出口上，已删除改为跟随默认路由（诊断探针的 pin 保留）。

**后续**：

- 等服务商的新 IP 段切换通知 → 迁移清单见 `../TODO.md` 待办 6。
- 新 IP 切换后：tailnet IP（100.118.65.105）不变，tailscaled 状态文件不受影响、无需重新授权；需要改的只有公网 IP 出现的地方（SSH 别名、客户端 `proxy` 出站、监视脚本、本文档）。
- 本机 `~/.local/state/vpn/vps-watch.sh` 持续每 10 分钟探测旧 IP；若服务商直接弃用旧段，监视永远不会触发，迁移时一并处理。

**取证方法沉淀**：「tcpdump 抓指定来源 IP + 对端定量发包」是判定"入站丢在上游还是本机"的决定性一步，比任何间接探测都硬；配合 check-host.net 全球多点可区分"GFW 封锁"（仅中国方向死）与"机器/上游故障"（全球都死）。

**解决（2026-11-13）**：服务商发布新旧 IP 对照查询页，本实例 `207.56.18.51` → `156.238.127.216`。当日完成迁移，见 §6.9。

### 2026-11-13 事件：新 IP 迁移完成 + 主出口改走 tailnet + 机场线路封锁插曲

**VPS 侧迁移（按 `../TODO.md` 待办 6 执行）**：

1. `ip addr add 156.238.127.216/24 dev eth0`（临时）→ 本机实测新 IP SSH 通；
2. `ip route replace default via 156.238.127.254` → 出方向全恢复（8.8.8.8 与 1.1.1.1 均 ~4.8ms、controlplane 302、generate_204 204、出口 IP 即新 IP）；
3. netplan 持久化：`addresses: [207.56.18.51/24, 156.238.127.216/24]`、`gateway4: 156.238.127.254`，`netplan apply` 后验证 tailscaled/xray/dnsproxy/warp/ufw 全部正常（tailscaled 自动回到 tailnet，无需重新授权）。
   **遗留**：旧 IP `207.56.18.51/24` 仍挂在 eth0 上过渡，待服务商正式退役旧段后从 netplan 删除。
4. 教训：VPS 出方向 DNS 全死时 `sudo` 会因 hostname 解析卡住 ~10 秒（`sudo: unable to resolve host`），不是 sudo 坏了；配好网关后自愈。

**本机侧（用户决策）：主出口改走 tailnet**。`~/.config/xray/config.json` 的 `proxy` 出站地址由 `207.56.18.51` 改为 `100.118.65.105`（tailnet IP，不受公网换段影响），`proxy-ts` 未动；`vpnctl use primary` 切回后实测：generate_204 204 / 1.4s、google 200 / 0.82s、telegram 302 / 0.94s、出口 IP `156.238.127.216`。
动机：tailnet 路径对"家宽线路封锁单个 IP"免疫（可走 DERP 中转），公网直连没有这层保险。`proxy` 与 `proxy-ts` 目前指向同一地址（冗余但无害，vpnctl 机制全部不变）。（2026-11-13 13:07 修订：备用出口已由机场改为 VPS 公网路径 `156.238.127.216:8443`——机场订阅到期不续，主备同机不同路；细节见 `xray-client/design.md` §6.11。）
`~/.ssh/config` 的 Host `hong` 已改指新 IP；`~/.local/state/vpn/vps-watch.sh` 监视任务已于 11-12 停止（任务已杀，文件保留未改）。

**插曲：当日早晨机场全线疑似被封（后自恢复）**。约 07:48 起备用出口失效，实测：trojan 中继 `143.20.71.8` 全端口死、同段 `143.20.71.42`（香港中转）也死、ss 美西直连 8 节点 TCP 通但不转发、订阅域名 TLS 握手完成后 HTTP 挂起。排查排除了错误方向：DNS 无污染（路由器/阿里/DNSPod/1.1.1.1/两家 DoH 解析一致）；随身 WiFi（M245）设备防火墙/端口过滤均为关闭且规则为空（经设备 CGI 接口核实）；手机移动数据下同节点正常 → 锁定为本机所连联通线路对该 /24 的定向封锁（TTL 逐跳显示包进联通骨干 219.158.8.114 后消失）。12:48 健康检查显示机场备用自行恢复（204）。**教训**：① 判断"通不通"必须先 IP 字面量后域名（本次一度把 DNS 失败误判为断网）；② 不要做端口段扫描式探测（143.20.71.8 的 13003–13014 全扫了两轮），既触发误判也可能触发对端防护。

---

## 7. 变更记录

| 日期 | 改动 | 原因 |
|------|------|------|
| 2026-11-13（二） | §6.9 修订：备用出口由机场改为 VPS 公网路径（`proxy-backup` → `156.238.127.216:8443`，vless+REALITY）；`xray-client/design.md` §6.11 同步重写，`vpnctl` 状态行动态显示备用地址 | 用户决定机场到期不续、公网路径接任备用；实测公网路径更快（204 探针 0.4s vs 机场 2.5s）；`vpnctl use backup`/`use primary` 往返实测通过 |
| 2026-11-13 | 记录 §6.9：新 IP 迁移完成（`207.56.18.51` → `156.238.127.216`，netplan 已持久化，旧 IP 留 eth0 过渡）；§1 SSH 行的公网 IP 同步更新；本机 `proxy` 出站改指 tailnet IP `100.118.65.105`（主出口走 tailnet，用户决策）；`~/.ssh/config` Host `hong` 改指新 IP；记录当日机场被联通线路定向封锁后自恢复的插曲与两条教训（先 IP 字面量后域名、勿做端口段扫描） | 服务商完成换段并发布新旧 IP 对照页；主出口走 tailnet 可免疫"家宽线路封锁单个 IP"（DERP 中转兜底）；旧配置全部有备份（`~/.local/state/vpn/backups/config-20261113-124742.json`、VPS netplan `.bak-20261113`），可回退 |
| 2026-11-12 | 记录 §6.8：上游国际方向中断事件（04:36 起全球不可达；证据链：全球多点仅雅加达通、出站选择性黑洞、controlplane 不可达、tcpdump 入站 0 抓包；服务商确认 207.56/207.57 段国际方向故障、筹备新 IP 段）；新增 `../TODO.md` 待办 6（新 IP 迁移清单）；未改任何服务器配置 | 服务商通知确认根因；排查方法（20 包定量、tcpdump 入站定性、全球多点区分 GFW 与上游故障）沉淀复用；客户端当日已上线机场 strict failover（xray-client v1.2.0）兜底 |
| 2026-11-09 | 记录 §6.7：平板 DNS 失效的排查与根因（Tailscale Android 1.102.3 在 Android 16 上 DNS 转发器失效，升级后恢复）；未改动任何服务器配置 | 平板报 `dns-forward-failing` 且只有浏览器失败。抓包证明 exit node 数据面正常（9 次握手/89 个数据包）、发往解析器的 DNS 包为 0，定位到客户端；升级即修复。顺带留下“先看 53 端口包是否存在”的定性方法 |
| 2026-11-09 | Fedora 客户端 IPv6 拦截由五个手写前缀改为一条策略规则 `ip: ["::/0"] → block`，位置在直连（private / 国内 IP / DNS 服务器 / 国内域名 / DNS 模块直连）之后、代理与 Telegram 规则之前；配置备份 `~/.local/state/vpn/backups/config-20261109-101803.json` | 前缀清单必然漏项：Cloudflare `2606:4700::/32` 不在原五个前缀里，实测其 IPv6 字面量经代理挂起；改为 catch-all 后 8 ms 失败并回落 IPv4，国内/内网 IPv6 仍直连（规则顺序保证）。来源：sing-box 配置生成器把 IPv6 当策略而非黑名单 |
| 2026-11-09 | vpnctl 新增 `geo-manifest`（`geo-manifest.py` 读 `geosite.dat`/`geoip.dat` 的代码清单），`validate` 在 xray `-test` 失败时点名不存在的代码；同时修 policy 断言：VLESS 出站由 `== 1` 改为 `>= 1` 且每个都必须是 REALITY + Vision | ① 11-04 事故（`geosite:office` 不存在 → 服务起不来）：现在失败信息直接点出代码；② 11-05 加入 `proxy-ts` 后配置有两个 VLESS 出站，而断言要求“恰好一个”，从那天起 `validate` 一直拒绝真实配置，连带 `restart`/`edit`/`install` 全部不可用（本次才发现）。离线测试 42 → 51 项 |
| 2026-11-09 | proxy-ctl：`no_proxy` 改为每次开终端读 GNOME `ignore-hosts`，只追加本机例外（`.local` + kimi 域名）；新增 `test_proxy.sh`（10 项，离线）；commit `5503857` 已推送 | `DESIGN.md` 声称“复用 ignore-hosts”，脚本却硬编码了另一份（GNOME 3 项、脚本 8 项）——文档与实现分叉，例外清单散在三处；改为单一来源 |
| 2026-11-05 | 新增 §6.6：Fedora 客户端 xray 增加 `proxy-ts` 出站（vless → `100.118.65.105:8443`，REALITY 参数同 `proxy`），routing 第 2/3 条 Telegram 规则改指向 `proxy-ts`（备份 `config.json.bak-20261105`） | 联通国际出口成片丢包（27.5%–52.5%），新连接每条都要重做 TCP+REALITY 握手导致 `tg_jlpt_bot` 回复超时/看门狗重启；Tailscale 是常驻隧道，新流不需要在丢包路径上重新握手。坏窗口实测 3 MB 传输 44.8 s → 5.46 s |
| 2026-10-28 | VPS 安装 Tailscale 1.104.4，开启 IP 转发，声明并获批 exit node | 手机在 Android 单 VPN 槽限制下同时上 Google 和访问 tailnet |
| 2026-10-28 | VPS `tailscale set --accept-dns=false` | MagicDNS 接管 resolv.conf 使 xray 出站解析依赖 tailscaled |
| 2026-10-28 | VPS sshd_config 删除第 124 行死配置 `PasswordAuthentication yes` | 配置清理，行为不变 |
| 2026-10-28 | `~/.dsh/profiles/web/cordis.patch.yml` 追加 webserver 条目（绑 100.105.202.118:3080） | 手机经 Tailscale 访问 dsh Web UI；通配地址被加载器拒绝故绑具体 IP |
| 2026-10-28 | VPS 代理与 Fedora 客户端全面体检 | 当日多次断联；结论：配置无病，疑线路高峰拥塞 |
| 2026-10-28 | 部署期间临时给 hong525 配 NOPASSWD sudo（`/etc/sudoers.d/99-temp-tailscale-setup`），完事即删并验证失效 | 非交互环境无法输密码；临时授权最小化暴露 |
| 2026-10-29 | VPS `resolv.conf` 改为 223.5.5.5 + 114.114.114.114（备份 `.bak-20261029`） | 8.8.8.8/1.1.1.1 的 UDP 53 被掐死，原配置无备用导致全机失解析 |
| 2026-10-29 | xray 端口 443→8443（ufw 同步放行；VPS 配置备份 `config.json.bak-20261029`；Fedora 客户端同步改端口，备份同名） | 当时判断为 GFW 对 IP:443 定向干扰；当晚复盘认为证据不足（主因实为 DNS 连锁故障），换端口可能非必要但已实施且运行正常，保持现状观察（见第 6 节复盘修正） |
| 2026-10-29 | xray 新增内置 DoH（1.1.1.1/8.8.8.8）+ freedom `UseIPv4` | 中国公共 DNS 对 Google 返回污染答案；UDP 53 干净源被掐但 DoH 畅通 |
| 2026-10-29 | 重启 tailscaled 后遇控制面 TLS 延迟无法重登，转后台自动重试待自愈（当日傍晚已自愈上线） | DNS 修复后尝试恢复控制面；发现路径级 TLS 延迟（见第 6 节事件记录） |
| 2026-10-29 | VPS 部署 dnsproxy v0.86.0（`dnsproxy.service`，监听 100.118.65.105:53，DoH 上游），作为 tailnet 全局 DNS；当晚 admin 后台完成 nameserver 设置并开启 Override DNS servers，已下发验证生效 | 手机走 exit node 时 DNS 查询经 VPS 出境，上午曾撞 UDP 53 死亡；隧道内 DNS + DoH 上游彻底规避路径过滤与 DNS 污染 |
| 2026-11-03 | Fedora 客户端 xray 路由新增首条规则：`ip=[2001:67c:4e8::/48, 2001:b28:f23d::/48, 2a03:2880::/32, 2a00:1450::/32, 2607:f8b0::/32] → block`（配置备份 `config.json.bak-20261103`） | 报障「代理偶发卡死」。实测 IPv4 经代理 20/20 成功，但本机有公网 IPv6、应用优先连 IPv6，而 VPS 无任何全局 IPv6（`ping6` 报 Network is unreachable），IPv6 连接必然挂起/EOF（24h 内 3,105 次 `[2001:…]:80 unexpected EOF`）；健康检查只探 IPv4 所以从不告警。加规则让这些 IPv6 目标立即失败、客户端回落 IPv4（实测由 12s 挂起变 0.009s 失败，Telegram 15/15 恢复） |
| 2026-11-03 | Fedora 建 `/etc/gai.conf`：`precedence ::ffff:0:0/96  100`（优先 IPv4；回滚 `sudo rm /etc/gai.conf`） | 配合客户端 IPv6 拦截，让所有应用解析时把 IPv4 排在前面，避免先撞 IPv6 再回落 |
| 2026-11-03 | `vpnctl check` 增加 IPv6 路径探针：新增 `probe_ipv6_path`/`has_global_ipv6`/`ipv6_block_rule_present`，`health.json` 增加 `ipv6_state`/`ipv6_ms`/`ipv6_local`，`status` 增加 ipv6 行与告警（备份 `~/.local/bin/vpnctl.bak-20261103`） | 原健康检查只探 IPv4，故 24h 内 3,105 次 IPv6 挂起完全不被发现。现在区分 ok / blocked（有拦截规则且快速失败，健康）/ hang（超 3s，故障）/ fail（快速失败但无规则，故障）；实测拔掉规则即报 fail 并返回退出码 4，装回即 ok |
| 2026-11-04 | VPS 安装 Cloudflare WARP（proxy 模式，SOCKS5 127.0.0.1:40000），xray 增加 `warp` 出站与三条规则（GitHub 域名 / geoip:cloudflare / geoip:fastly），`routing.domainStrategy=IPIfNonMatch`；新增 `warp-keepalive` + `warp-proxy.timer` 每分钟保活 | 实测到 Cloudflare/Fastly 方向单流被限到 ~38 KB/s（OVH 对照 319 KB/s，4 并发合计 145 KB/s）；走 WARP 后 cdnjs 36→304 KB/s、GitHub 54→250 KB/s，非 CF 流量不受影响 |
| 2026-11-04 | VPS 新增 `/usr/local/bin/xray-apply`：改配置的唯一入口——JSON 检查 → `xray -test` → 备份 → 落盘 → 重启 → 起后自检（服务 active + 8443 监听），任一步失败自动回滚，线上配置不动 | 同日 07:33 的一次手工改动引用了不存在的 `geosite:office` 且 `-test` 与 `restart` 用了 `;` 串联，导致 xray 启动失败、代理宕机约 1 小时（记录见 `2026-11-04-xray-geosite-office-incident.zh-CN.md`）；把「先验证再重启、失败即回滚」固化成工具 |
| 2026-10-29 | Fedora 执行 `sudo tailscale set --accept-dns=false`，退出 tailnet 统一 DNS | 全局 Override 会使 Fedora 国内站解析绕香港 VPS 的 DoH，CDN 分配非最优节点；改回本地运营商 DNS（隧道与代理不受影响，手机仍走隧道 DNS）。恢复命令：`sudo tailscale set --accept-dns=true` |

## 8. 安全说明

- 本文档不含密钥。真实凭据位置：Fedora 客户端 `~/.config/xray/config.json`（0600，
  含 UUID/Reality 公钥/shortId）；VPS 服务端 `/usr/local/etc/xray/config.json`。
- dsh 的 `?token=` URL 每次启动重新生成，不要写入任何文档。
- VPS 仅允许密钥 SSH（密码登录已禁）；sudo 需要密码。
