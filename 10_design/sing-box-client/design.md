# 方案 B：sing-box + Tailscale 智能分流客户端设计

- 版本：0.1（文档基线）
- 日期：2026-11-19
- 状态：设计已确认，尚未实施
- 关联文档：[xray-client 方案 A](../xray-client/design.md)、[VPS Tailscale Exit Node 与远程访问架构](../vps-tailscale-exit-node.md)、[proxy-ctl 设计](../../../proxy-ctl/DESIGN.md)

## 1. 结论与边界

当前设备可以配合现有 VPS 使用 **sing-box + Tailscale**。推荐迁移方式不是同时替换客户端和服务端，而是：

```text
Fedora 应用
    ↓
本机 sing-box mixed inbound
    ↓
sing-box 分流
    ├── 内网与国内目标 → direct
    ├── 主出口 → 现有 VPS 公网路径（VLESS + REALITY + Vision）
    └── 备用出口 → 现有 VPS tailnet 路径（VLESS + REALITY + Vision）
                ↑
             Tailscale 隧道
```

核心边界：

1. **VPS 服务端继续运行现有 xray**，本阶段不替换服务端实现。
2. **Fedora 本地客户端由 xray 迁移到 sing-box**，现有 xray 配置和二进制保留为回滚路径。
3. **Tailscale 不是全局出口节点**：Fedora 不启用 Tailscale exit node，只把 tailnet IP 当作到 VPS 的备用网络路径。
4. **不使用 TUN**：继续使用 GNOME 系统代理和终端环境变量；不接管不读代理配置的应用。
5. **先并行测试，再接管生产端口**：staging 使用 18080～18083，验证期间现有 xray 的 10808～10811 不受影响。
6. **真实凭据不进入仓库，也不写入持久化的 sing-box 配置**：v1 从现有 xray 配置只读提取连接参数，在用户级 tmpfs 生成运行时配置。

## 2. 5W1H

What: 构建一个可验证、可回滚的 sing-box 客户端，替代 Fedora 本地 xray 客户端。  
Why: 在保留现有 VPS 与 Tailscale 架构的前提下评估 sing-box，并为后续分析错误留下完整证据。  
Who: 用户确认方向，助手设计、实施、验证并记录。  
When: 先完成设计基线，再实施 staging；生产切换必须等 staging 验收通过。  
Where: Fedora 客户端；VPS 服务端和 Tailscale 网络拓扑保持现状。  
How: 官方二进制与规则集、供应链哈希、运行时配置生成、旁路端口验收、失败回滚。

## 3. 现状依据

### 3.1 已核实的服务端与网络

- VPS 上现有代理服务为 VLESS + XTLS Vision + REALITY，监听在既定代理端口。
- 同一 VPS 同时运行 Tailscale，并有一个 tailnet 地址。
- 当前 xray 客户端存在公网与 tailnet 两类到同一代理服务的出站。
- Fedora 当前运行 Tailscale，但没有把任何设备设为出口节点，也没有向内网通告子网路由。
- Fedora 的系统代理由 `proxy-ctl` 跟随 GNOME 设置；应用只关心本机端口，不关心后端内核。

### 3.2 协议兼容性依据

sing-box 官方配置文档当前明确支持：

- `mixed` inbound：同时提供 HTTP 与 SOCKS 代理；
- `vless` outbound：支持 `flow = "xtls-rprx-vision"`；
- TLS outbound 的 `reality` 配置：支持 `public_key` 与 `short_id`；
- `utls` 指纹值包括 `chrome`。

因此，VPS 服务端无需因客户端迁移而同步更换。

### 3.3 方案 A 留下的迁移点

`xray-client/design.md` 已把 sing-box 明确列为当前运行路径之外的候选方案。当前迁移不是推翻方案 A，而是在它的风险框架下新增方案 B：

- 本地入站继续只监听 `127.0.0.1`；
- 配置文件修改必须先校验、可回滚；
- 每个出口有独立探针；
- 不做 TUN；
- 官方来源、稳定版本、冷却期、哈希和证据文件优先于新功能。

## 4. 目标与非目标

### 4.1 目标

1. 用 sing-box 提供与现有 xray 等价的本地 HTTP/SOCKS 代理。
2. 保留公网主出口、tailnet 备用出口和 Tailscale 诊断出口。
3. 保留国内/内网直连、代理路径 IPv4-only、QUIC UDP 443 快速失败等现有行为。
4. staging 阶段不中断现有 xray 代理。
5. 每个出口的探测结果、配置哈希、二进制哈希、规则集哈希和切换原因都能追溯。
6. 生产切换失败时能在分钟级回到现有 xray。

### 4.2 非目标

- 不替换 VPS 上的 xray 服务端。
- 不让 Fedora 全局使用 Tailscale exit node。
- 不启用 TUN、透明代理或系统级路由接管。
- 不做多节点负载均衡；延续严格主备思路。
- 不自动更新 sing-box 或规则集。
- 不把 sing-box 当作 Tailscale 的功能插件；Tailscale 只提供网络路径。
- 不在 v1 淘汰现有 xray 配置；它同时是回滚路径和临时的连接参数来源。
- 不改变 `proxy-ctl` 的系统代理跟随逻辑；OpenCode 等 `no_proxy` 直连例外保持有效。

## 5. 端口与角色设计

staging 与生产使用同一套角色、两组端口。staging 只用于验证，避免与现有 xray 冲突。

| 角色 | staging | 生产 | 路由目标 | 用途 |
|------|---------:|-----:|----------|------|
| `socks` | 18080 | 10808 | 当前默认出口 | 普通 HTTP/SOCKS 代理 |
| `ts-in` | 18081 | 10809 | `proxy-ts` | Tailscale 路径诊断 |
| `probe-in` | 18082 | 10810 | `proxy` | 主出口健康探针 |
| `bk-in` | 18083 | 10811 | `proxy-backup` | 备用出口健康探针 |

所有入站必须满足：

- `type = "mixed"`；
- `listen = "127.0.0.1"`；
- 不允许 `0.0.0.0` 或 Tailscale IP 监听；
- 无认证仅允许用于本机回环地址；
- 入站 tag 与固定路由规则必须同时存在或同时不存在。

## 6. 出站与默认模式

保留与 xray 相同的出站 tag，便于对比和回滚：

| tag | 类型 | 路径 | 说明 |
|-----|------|------|------|
| `proxy` | VLESS + REALITY + Vision | VPS 公网路径 | 主出口 |
| `proxy-backup` | VLESS + REALITY + Vision | VPS tailnet 路径 | 严格备用出口 |
| `proxy-ts` | VLESS + REALITY + Vision | VPS tailnet 路径 | Tailscale 诊断/特定流量出口 |
| `direct` | direct | 本机直连 | 内网与国内目标 |
| `block` | block | 无 | 快速失败 |

默认出口由当前 xray 配置的出站顺序派生：迁移工具读取当前 xray 配置，确认第一个代理出站是 `proxy` 还是 `proxy-backup`，并让 sing-box 的 `route.final` 使用相同 tag。**迁移不得静默改变当前主备模式。**

`proxy-backup` 与 `proxy-ts` 当前可能指向同一个 tailnet 地址。v1 保留这个冗余，因为现有探针和运维命令已经围绕三个 tag 建立；是否在后续版本合并，单独评估。

## 7. 分流规则

目标不是逐字段复制 xray JSON，而是复制已经验证过的有效行为：

1. 诊断入站固定路由：
   - `ts-in → proxy-ts`；
   - `probe-in → proxy`；
   - `bk-in → proxy-backup`。
2. UDP 443（QUIC）快速失败，避免应用在被 QoS 的 UDP 路径上挂起。
3. 私网 IP 与私网域名直连。**显式包含 CGNAT `100.64.0.0/10`（Tailscale tailnet 段）**：sing-box 的 `ip_is_private` 只覆盖 RFC1918，不含 CGNAT；xray 旧配置靠显式 CIDR 规则直连 tailnet。漏掉这一条会让访问本机/peer 的 tailnet 服务绕 VPS 发夹（2026-11-19 实测：访问本机 tailnet 地址的 quiz 服务经 `proxy-backup` 绕行，耗时从直连级升到 3.5s+，并出现 5 分钟级长连接挂代理）。MagicDNS 域名（`.ts.net` 后缀）同样直连。
4. 国内 IP 与国内域名直连。
5. 代理路径只允许 IPv4：国内和内网 IPv6 仍直连，其余 IPv6 在规则阶段快速失败。
6. 未匹配流量走当前默认出口（`proxy` 或 `proxy-backup`）。
7. 不恢复已删除的 Telegram/Google 固定 pin；它们跟随默认出口，避免 backup 模式下被钉在失效出口上。

### 7.1 规则集来源

xray 的 `geoip.dat` / `geosite.dat` 不直接作为 sing-box 的运行时输入。实施时必须使用 sing-box 当前官方支持的 rule-set 格式，并满足：

- 只从 sing-box 官方组织或其明确指向的规则集来源获取；
- 下载 URL、获取日期、SHA256 写入证据文件；
- 文件保存到用户目录，禁止运行时自动更新；
- 更新是显式动作，失败保留旧文件；
- 离线测试验证国内/内网规则确实命中 `direct`。

2026-11-19 已按官方文档核定（证据：`~/.local/state/sing-box-client/upgrades/2026-11-19-source-baseline.md`）：

- 格式：`binary`（`.srs`），配置用 `type: "local"`，不用 remote 自动更新；
- `geoip-cn.srs`：`https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs`；
- `geosite-cn.srs`：`https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs`；
- `geosite-private.srs`：`https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-private.srs`（承载"私网域名直连"）；
- 「UDP 443 快速失败」与「IPv6 代理路径快速失败」均用 route rule 的 `"action": "reject"`（默认 method：TCP 回 RST、UDP 回 ICMP port unreachable），不引入 `block` 出站；xray 侧的 `block` tag 只在源配置读取阶段保留，不进入 sing-box 配置。

若官方格式或来源发生变化，先修订本文档，再实施。

## 8. DNS 策略

v1 复制当前 xray 配置的**有效行为**，而不是复制没有被流量使用的配置表面：

- 系统应用继续通过本机解析器解析域名；
- 经 mixed 入站提交的域名优先用于域名规则判断；
- 未匹配域名交给 VPS 远端解析；
- 国内域名通过规则集直连；
- 不添加国内 UDP 53 兜底解析器；
- 不把境外 DoH 强制改为直连；
- 不启用 Tailscale exit node 的全局 DNS。

理由：xray 方案中已经实测，国内 UDP 兜底可能给境外域名注入污染答案并触发错误的 geoip 直连；境外 DoH 直连也可能本身不可达。v1 不重复引入这两个已否决方案。

如果 sing-box 的 DNS/路由行为与上述目标不一致，先记录差异并修订本节，不得用未验证的 DNS 配置直接进入生产。

实现机制（2026-11-19 依据官方 Rule Action 文档核定）：sing-box 的目标地址只有被显式 `resolve` 动作解析成 IP 之后，IP 类规则才能匹配域名请求；v1 的路由规则**不使用 `resolve` 动作**，因此：

- 域名请求只可能被域名类规则（geosite）命中；未匹配的域名原样交给 `route.final` 的 VLESS 出站，由 VPS 远端解析——等价于 xray `domainStrategy: AsIs`，不会为路由判断在本地解析境外域名，规避已否决的污染注入路径；
- 字面 IP 请求直接命中 `ip_is_private` / `geoip-cn` 规则；
- `direct` 出站拨打国内域名时使用系统解析器（DNS 模块只配 `type: "local"` 服务器），与 xray freedom 出站的有效行为一致。

## 9. 凭据与运行时配置

### 9.1 v1 的单一事实源

现有 `~/.config/xray/config.json` 继续作为 VLESS UUID、REALITY public key、short ID、服务器地址和端口的唯一持久化事实源。迁移工具只读它，不把其中的值打印到终端、日志、仓库或聊天输出。

### 9.2 运行时生成

sing-box 的实际运行配置由本地生成器生成：

- 输入：现有 xray 配置（0600）+ 仓库内无凭据模板；
- 输出：`$XDG_RUNTIME_DIR/sing-box-client/config-<profile>.json`；
- 权限：目录 0700，文件 0600；
- 位置：用户级 tmpfs，重启后消失；
- 每次服务启动前重新生成；
- 生成器只输出哈希、字段存在性和校验结果，不输出敏感值；
- journal 中不得出现 UUID、完整服务器地址、REALITY key 或 short ID；
- 实现机制：sing-box 在出站拨号失败时会把服务器地址写进错误日志，因此 `run` 的 stdout/stderr 经 scrub 过滤器，把每个服务器地址替换为其 SHA256 前 12 位（`srv-<hash12>`）后再进 journal；过滤器在每次启动时从当次运行时配置重建，不持久化地址。

这样做的原因：sing-box 需要完整 JSON 文件才能启动，但 v1 不应再创建第二份持久化凭据副本。xray 配置同时保留为回滚路径，因此它是迁移期最合适的事实源。

### 9.3 长期问题

如果未来彻底移除 xray 配置，必须单独决定 sing-box 凭据的持久化位置，并遵循设备级的秘密单源规则。该决定不属于 v1，不能为了完成迁移而把凭据随意复制到 `~/.config/sing-box/config.json`。

## 10. 文件布局

### 10.1 仓库内（无真实凭据）

```text
10_design/sing-box-client/
├── design.md                         # 本文档
├── README.md                         # 实施后的操作文档
├── config.template.json              # 无凭据配置模板
├── singboxctl.sh                     # 安装、生成、校验、开关、状态、主备切换
├── sing-box-client-test.service      # staging user service
├── sing-box-client.service           # 生产 user service（2026-11-19 切换时加入）
├── sing-box-health.service           # 健康探测单元（验收后加入）
├── sing-box-health.timer             # 健康探测定时器（验收后加入）
└── test_singboxctl.sh                # 离线验收测试
```

实施时可以合并 systemd 单元或调整文件数量，但必须先更新本文档与变更记录。真实凭据仍不得入库。

### 10.2 运行期路径（不进仓库）

| 路径 | 权限 | 用途 |
|------|------|------|
| `~/.local/lib/sing-box/<version>/sing-box` | 0755 | 版本化官方二进制 |
| `~/.local/lib/sing-box/current` | symlink | 当前版本 |
| `~/.local/bin/sing-box` | symlink | 当前二进制入口 |
| `~/.local/bin/singboxctl` | 0755 | 运维入口 |
| `~/.local/share/sing-box/rule-sets/` | 0700 | 本地规则集缓存 |
| `$XDG_RUNTIME_DIR/sing-box-client/` | 0700 | 运行时配置 |
| `~/.local/state/sing-box-client/` | 0700 | 状态、证据、备份 |
| `~/.config/systemd/user/sing-box-client*.service` | 0644 | user units |
| `~/.config/sing-box-client/client.conf` | 0600 | 非秘密开关，例如默认 profile |

## 11. 安装与更新策略

### 11.1 sing-box 二进制

沿用方案 A 的供应链纪律：

1. 只从 sing-box 官方 Releases 获取；
2. 只选 stable release，不选 pre/rc/beta/alpha/nightly；
3. 发布必须满 60 天；不足 60 天则选择更早的稳定版；
4. 记录版本、发布日期、下载 URL、压缩包与二进制的 SHA256；
5. 安装到版本目录后先执行 `sing-box version` 与 `sing-box check`；
6. staging 验收通过前不创建生产服务；
7. 不自动检查更新，不追最新。

如果官方最新版本发布未满 60 天，就在实施当日重新查询 Releases 并选择符合规则的最近稳定版；选择结果与证据写入 `~/.local/state/sing-box-client/upgrades/`。

2026-11-19 核定结果：当时最新稳定版 1.14.4（2026-10-11）、1.14.3（2026-10-03）、1.14.2（2026-09-22）均未满 60 天，1.15.0 系列全为 alpha；选定 **1.14.1**（2026-09-15 发布，已满 65 天，stable）。完整证据（下载 URL、SHA256、核定过程）见 `~/.local/state/sing-box-client/upgrades/2026-11-19-source-baseline.md`。

### 11.2 规则集

- 与二进制分开记录哈希；
- 更新必须显式执行；
- 更新后先跑离线规则测试，再重启 staging；
- staging 验证通过前不影响 xray。

## 12. 健康检查与主备切换

### 12.1 staging 健康检查

staging 阶段只做显式 `singboxctl check`，不启用自动 failover，不修改 GNOME 系统代理：

- 主探针：经 `probe-in` 请求 204 目标，必须走 `proxy`；
- 备用探针：经 `bk-in` 请求同一目标，必须走 `proxy-backup`；
- Tailscale 探针：经 `ts-in` 请求既定目标，必须走 `proxy-ts`；
- 普通入口：经 `socks` 请求一个**不在 geosite-cn 内**的目标，必须走当前默认出口（2026-11-19 实测 `www.gstatic.com` 命中 geosite-cn 会直连，与 xray 时代 vpnctl 记录过的陷阱相同，故默认出口探针用 `api.telegram.org`）；
- 国内直连目标必须返回成功，且路由证据显示没有走 VPS；
- 记录 HTTP 码、耗时、配置哈希、二进制版本与规则集哈希。

速度不作为硬门槛。当前 MiFi 上游本身波动很大，验收以功能、路由和稳定性为准；速度样本只记录，用于后续分析。

### 12.2 生产切换条件

只有同时满足以下条件，才允许把 sing-box 移到生产端口：

1. 离线配置校验与策略校验全部通过；
2. staging 三类代理出口和直连出口全部通过；
3. Tailscale 路径探针通过；
4. 主备切换往返测试通过，失败能自动回滚；
5. 日志与 journal 中未发现敏感值；
6. xray 当前配置与二进制未改变，回滚路径可用；
7. staging 至少完成一轮有记录的观察；观察时长在验收记录中写明。

> 偏差记录（2026-11-19）：staging 首轮实测完成当天，用户明确指示「直接切换」，
> 第 7 条的观察期条件由用户决策覆盖；staging 实测记录即第 0 轮观察
> （时长约 1.5 小时，见 §15.2 证据文件）。其余 6 条全部满足后执行切换。

### 12.3 生产健康检查

生产服务验收后再启用 3 分钟定时器。初期不启用自动 failover；只有 sing-box 版主备切换经过足够观察后，才考虑恢复 `AUTO_FAILOVER`。

健康检查必须显式使用对应诊断入站，不能复用普通入口后假装测到了指定出口。

## 13. 切换与回滚

### 13.1 staging 回滚

staging 不影响现有系统代理。回滚动作：

1. 停止并禁用 staging 单元；
2. 删除 `$XDG_RUNTIME_DIR/sing-box-client/` 中的运行时配置；
3. 保留二进制、证据和日志；
4. 现有 xray 不需要任何恢复动作。

### 13.2 生产切换预案

只有 staging 验收完成后才执行：

1. `vpnctl off`：先关闭系统代理，再停止 xray；
2. 生成 sing-box 生产运行时配置；
3. 启动 sing-box 生产单元；
4. 等待 10808～10811 仅监听 `127.0.0.1`；
5. 逐项执行生产健康检查；
6. 全部通过后恢复 GNOME `manual`；
7. 记录切换时间、配置哈希和验收结果。

### 13.3 生产回滚

任一步失败：

1. 先关闭 GNOME 系统代理；
2. 停止 sing-box；
3. 执行 `vpnctl on` 恢复现有 xray；
4. 确认 xray 探针恢复；
5. 保留 sing-box 日志和配置哈希，用于离线分析；
6. 未查明根因前不得再次切换。

## 14. 风险控制矩阵

| 编号 | 风险 | 控制 |
|------|------|------|
| SB-R1 | sing-box 与 xray 的 REALITY/Vision 行为差异 | staging 用真实 VPS 验证握手、204、出口和连续请求 |
| SB-R2 | 端口冲突 | staging 使用 18080～18083；生产切换前先停 xray |
| SB-R3 | 规则集格式或来源变化 | 实施时以官方文档为准；哈希与来源落盘；先改文档再改实现 |
| SB-R4 | 国内/内网误走代理 | 离线规则测试 + staging 直连目标验证 + 路由证据 |
| SB-R5 | 敏感值进入仓库或日志 | 模板无凭据；运行时配置放 tmpfs；日志扫描 UUID/key 形态 |
| SB-R6 | 迁移改变当前主备模式 | 从 xray 出站顺序派生 `route.final`；切换前后记录模式 |
| SB-R7 | Tailscale/代理循环依赖 | tailnet IP 走 direct；Tailscale 自身继续绕过系统代理；staging 不测 TUN |
| SB-R8 | IPv6 经代理挂起 | 保留 IPv6 快速失败规则并做负向测试 |
| SB-R9 | MiFi 上游波动导致误判 | 不做速度硬门槛；记录时间序列；网络问题与配置问题分开定性 |
| SB-R10 | 自动 failover 过早引入新故障面 | staging 不自动切换；生产先手动，观察后再启用 |
| SB-R11 | 回滚时 xray 配置已变 | 切换前记录 xray 配置哈希；staging 期间修改 xray 配置需重新生成并复测 |
| SB-R12 | sing-box 供应链问题 | 官方 stable、60 天冷却、SHA256、证据文件、不自动更新 |

## 15. 验收清单

### 15.1 文档基线

- [ ] 本文档不包含真实 UUID、public key、short ID、服务器地址或端口凭据。
- [ ] 文档中的 staging/生产端口一致。
- [ ] 方案 A 文档能链接到本文档。
- [ ] 仓库测试不引入失败。
- [ ] 变更记录包含 What/Why/Who/When/Where/How 与回滚方式。

### 15.2 staging 实施验收

2026-11-19 首轮实测，证据：`~/.local/state/sing-box-client/staging/2026-11-19-first-run.md`。

- [x] sing-box 版本符合 stable、非预发布、满 60 天要求（1.14.1，2026-09-15 发布）。
- [x] 二进制 SHA256 与证据文件一致。
- [x] 规则集来源与 SHA256 已记录。
- [x] 运行时配置只出现在 `$XDG_RUNTIME_DIR`，权限为 0600（目录 0700）。
- [x] `sing-box check` 通过（每次 `run` 前强制执行）。
- [x] 策略校验拒绝非 `127.0.0.1` 入站（离线测试断言四个入站均为 127.0.0.1 且无 `0.0.0.0`）。
- [x] 10808～10811 未被 staging 占用（`ss -ltn` 实测：staging 只占 18080～18083）。
- [x] 主、备、Tailscale、direct 四类路径全部按 tag 出队（journal 路由证据齐全；主出口 `proxy` dial 超时为上游条件，同时段 xray 10810 基线同样失败，出队选择本身正确）。
- [x] 主备模式与切换前 xray 当前模式一致（`route.final=proxy-backup`，与 xray 出站顺序派生一致）。
- [x] 国内目标直连成功（baidu 200 ×3，journal 显示 `outbound/direct[direct]`）。
- [x] IPv6 代理路径快速失败（IPv6 字面量经 socks 0.011s 被 SOCKS 拒绝）。
- [x] 日志扫描未发现敏感值（scrub 过滤器上线后 12 个敏感值全部未命中；上线前的泄漏事件见证据文件）。
- [x] staging 回滚后 xray 状态完全不变（2026-11-19 回滚演练实测：停止测试单元后 xray 服务状态、10808～10811 监听、源配置 SHA256 与停止前逐项一致，staging 端口全部释放；恢复启动后探针 204）。

### 15.3 生产验收

2026-11-19 切换实测，证据：`~/.local/state/sing-box-client/cutover/2026-11-19-production-cutover.md`。

- [x] `vpnctl off` 后 sing-box 独占 10808～10811。
- [x] 所有入站只监听 `127.0.0.1`。
- [x] GNOME 恢复 `manual` 前，生产健康检查全绿（主出口 `proxy` dial 失败为上游条件，见证据 §3）。
- [x] `proxy-ctl` 在新 shell 中正常导出代理变量（`http_proxy=127.0.0.1:10808`，`no_proxy` 例外齐全）。
- [x] OpenCode 等 `no_proxy` 例外仍直连（api.opencode.ai 直连 200）。
- [x] 浏览器和终端各完成一次真实请求验证（终端已完成；浏览器随用户日常使用确认）。
- [x] 模拟 sing-box 失败后，`vpnctl on` 能恢复 xray（实测：xray active、备份探针 204、GNOME 恢复；随后已切回 sing-box 并复验）。
- [x] 切换、验收、回滚证据写入变更记录（证据文件 + 本节 + §17）。

## 16. 实施阶段

### P0：设计与验证基线

1. 新增本文档。
2. 从 xray 方案 A 链接到方案 B。
3. 记录设计变更并通过仓库现有测试。
4. 合并文档基线，作为后续代码的审查起点。

### P1：staging 实现

1. 核定 sing-box stable 版本、来源和 SHA256。
2. 编写无凭据模板与运行时生成器。
3. 安装 staging 服务（18080～18083）。
4. 编写离线测试和敏感值扫描。
5. staging 真实路径验收。
6. 记录结果；不修改系统代理，不停 xray。

### P2：生产切换准备（2026-11-19 完成）

1. 加入生产 unit、健康检查和主备切换命令。✅（生产 unit + profile；主备切换沿用"改 xray 出站顺序 → 重启生成"的既有机制，自动 failover 按 §12.3 暂缓）
2. 完成 staging 观察与验收记录。✅（观察期条件由用户决策覆盖，见 §12.2 偏差记录）
3. 明确切换窗口和回滚命令。✅
4. 执行生产切换，并保留 xray 回滚路径。✅（切换记录见 §15.3 证据文件）

### P3：后续评估

1. 观察 sing-box 的 REALITY/Vision 长连接表现。
2. 评估是否恢复自动 failover。
3. 评估是否合并 `proxy-backup` 与 `proxy-ts`。
4. 评估 xray 客户端是否退役；凭据长期存放方式必须先按秘密单源规则重新设计。
5. 只有在客户端方案 B 稳定后，才讨论 VPS 服务端是否也迁移到 sing-box。

## 17. 变更记录

- 2026-11-19 — What: 修复 tailnet 流量误入代理——模板在 `ip_is_private` 后显式新增 `ip_cidr 100.64.0.0/10 → direct` 与 `domain_suffix .ts.net → direct` 两条 route rule；§7 第 3 条改写为显式要求；`test_singboxctl.sh` 结构断言新增 tailnet/ts.net direct 一项。 | Why: 生产实测 `http://100.105.202.118:8080/quiz` 变慢（3.19s+），journal 显示请求经 `proxy-backup` 绕 VPS 发夹回本机；根因是 `ip_is_private` 不含 CGNAT `100.64.0.0/10`，SB-R7 实现遗漏。 | Who: user report -> assistant executed. | When: 2026-11-19 22:14. | Where: `10_design/sing-box-client/{config.template.json,test_singboxctl.sh,design.md}`；证据 `~/.local/state/sing-box-client/cutover/2026-11-19-tailnet-direct-fix.md`。 | How: 文档先行（§7 先改）再改模板与测试；16/16 测试 + production validate 全绿后重启 `sing-box-client.service`；实测 quiz 0.189s 且 journal 显示 `outbound/direct[direct]`；blast radius 限 sing-box 路由表 (rollback: revert 本次提交并重启服务，或 `vpnctl on` 整体回退 xray)。

- 2026-11-19 — What: 创建方案 B 设计基线，明确 Fedora 客户端迁移到 sing-box、VPS xray 不变、Tailscale 仅作备用网络路径、staging 与生产端口分离、运行时凭据放用户级 tmpfs。 | Why: 用户确认“sing-box + Tailscale”方向并要求先构建方案文档、全程留痕。 | Who: user instruction -> assistant executed. | When: 2026-11-19. | Where: `10_design/sing-box-client/design.md`。 | How: 依据项目现有 xray/VPS/Tailscale 文档与 sing-box 官方 mixed/VLESS/REALITY 文档手工编写；blast radius 仅限仓库文档，不改变运行中代理 (rollback: revert the `sing-box-client-design` merge commit)。

- 2026-11-19 — What: 在 §7.1 补入已核定的规则集确切 URL/格式（SagerNet 官方 `rule-set` 分支 `.srs` 二进制，`type: "local"`）与「快速失败 = route rule `reject` 动作」的写法；在 §11.1 补入版本核定结果（选定 sing-box 1.14.1）。 | Why: 按 §7.1/§11.1 自己的约定，实施时必须以当日官方 Releases 与官方文档实测核定来源，不凭记忆；1.14.2～1.14.4 发布未满 60 天，1.15.0 系列全为 alpha。 | Who: user instruction（“按思路做，留痕”） -> assistant executed. | When: 2026-11-19. | Where: `10_design/sing-box-client/design.md` §7.1、§11.1、§17；证据文件 `~/.local/state/sing-box-client/upgrades/2026-11-19-source-baseline.md`。 | How: GitHub Releases API（逐 tag 查询）+ releases.atom + 官方文档站核定，HEAD 验证后下载 .srs 并计算 SHA256；blast radius 仅限文档，不改运行中 xray (rollback: revert 本次提交)。

- 2026-11-19 — What: 新增 staging 实施文件 `config.template.json`、`singboxctl.sh`（install/generate/validate/run/status/check）、`sing-box-client-test.service`、`test_singboxctl.sh`、`README.md`；§7.1 增列 `geosite-private.srs`；§8 补「无 `resolve` 动作 = IP 规则不匹配域名」的实现机制。 | Why: 方案 B 进入 P1 staging 实施；私网域名直连需要 geosite-private；DNS 机制需与实现一致（§1 文档先行）。 | Who: user instruction -> assistant executed. | When: 2026-11-19. | Where: `10_design/sing-box-client/` 新增上述文件；`design.md` §7.1、§8、§17；规则集证据更新于 `~/.local/state/sing-box-client/upgrades/2026-11-19-source-baseline.md`。 | How: 生成器用 python3 内嵌实现，凭据只从 `~/.config/xray/config.json` 只读进入 `$XDG_RUNTIME_DIR`（0600）；真实配置实测 `validate` 全绿（final=proxy-backup 与当前 xray 模式一致），mock 离线测试 12/12；staging 不触碰 xray 与 10808～10811 (rollback: revert 本次提交并删除新增文件；运行态仅 tmpfs 配置，重启即消失)。

- 2026-11-19 — What: staging 首轮实测并修复三个实测发现的问题：`run` 增加 journal scrub 过滤器（服务器地址→`srv-<hash12>`）、scrub 改行缓冲、`check` 默认出口探针从 gstatic 改为 `api.telegram.org`；§9.2 补 scrub 机制、§12.1 补 gstatic 直连陷阱注、§15.2 勾选首轮验收结果；新增离线测试 2 项（scrub 替换、慢生产者冲刷）。 | Why: 实测发现 sing-box 拨号失败会把服务器地址写进 journal（违反 §9.2）、块缓冲导致 journal 看不到运行日志、gstatic 命中 geosite-cn 导致默认出口探针失真；按 §6 要求修复并把检查固化进测试。 | Who: user instruction（“做吧，留痕”） -> assistant executed. | When: 2026-11-19. | Where: `10_design/sing-box-client/{singboxctl.sh,test_singboxctl.sh,design.md}`；证据 `~/.local/state/sing-box-client/staging/2026-11-19-first-run.md`。 | How: 本机实测（xray 全程未动，10808～10811 未触碰）；14/14 离线测试 + 真实配置 validate 全绿；blast radius 限 staging 端口与 tmpfs 配置；修复前 journal 旧条目含 proxy 服务器地址，保留并记录（rollback: revert 本次提交；staging 回滚 = `systemctl --user stop sing-box-client-test.service`）。

- 2026-11-19 — What: §15.2 末项验收依据由推断升级为实测（回滚演练结果一句话）。 | Why: 验收项应有实测证据而非推断；演练结果已写入 `~/.local/state/sing-box-client/staging/2026-11-19-first-run.md` §5。 | Who: assistant executed. | When: 2026-11-19. | Where: `design.md` §15.2、§17。 | How: 停止/重启 staging 单元并做快照 diff；blast radius 仅文档 (rollback: revert 本次提交)。

- 2026-11-19 — What: 执行生产切换——新增 `sing-box-client.service` 与 `SINGBOXCTL_PROFILE=staging|production`（生产映射 10808～10811），§10.1/§12.2/§15.3/§16 同步，README 增生产与回滚命令；切换后 sing-box active+enabled 独占 10808～10811，xray disabled 转为回滚路径。 | Why: 用户明确指示「直接切换」，覆盖 §12.2 观察期条件（已记偏差）；其余 6 项切换条件均满足。 | Who: user instruction -> assistant executed. | When: 2026-11-19 21:32–21:45. | Where: 本机 systemd user 服务与 GNOME 代理；证据 `~/.local/state/sing-box-client/cutover/2026-11-19-production-cutover.md` 与 `pre-cutover-snapshot.txt`。 | How: 按 §13.2 七步执行并做生产回滚演练（vpnctl on 恢复 xray 实测通过后切回）；16/16 + 11/11 + 79/79 测试全绿；主出口上游不可达为既有条件，默认出口 backup 正常（rollback: `systemctl --user stop sing-box-client.service && vpnctl on`）。
