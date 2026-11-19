# Check List

每类错误一条可执行检查项，进验收/自查阶段；新错误按"症状/根因/修复/本应拦住它的检查"追加。

- [ ] **网络拓扑变更类**（2026-11-18，metric 700→500 当日回退）：调整默认路由优先级 / 切换主备物理线路**之前**，先在目标拓扑下验证依赖链数据面，而非只 ping 网关——最小检查集：① `tailscale netcheck` 在该线路上 UDP 是否可用（本例蜂窝有线 UDP 被阻断）；② MagicDNS 上游路径（`dig @100.100.100.100`）在该线路上是否可达；③ tailscaled DERP/控制面的出口路径（GNOME 系统代理 → xray → 出站）是否与被切换线路构成循环依赖；④ `vpnctl status` 的当前出站是 primary 还是 backup（backup=tailnet 时，tailnet 死 = 代理死）。
  - 症状：metric 改 500 后，用户断开 WiFi 仅用有线，国内外网站一律打不开（其他设备走 M245 WiFi 正常）。
  - 根因：循环依赖死锁——蜂窝线路 UDP 阻断 → tailnet 仅剩 DERP；DERP/控制面经 GNOME 代理 → xray → 默认出站 = proxy-backup（tailnet，因主出口 8443 从本机不通而卡在 backup）→ 死锁；系统 DNS（MagicDNS→VPS）与 xray 非 cn DoH 同死。
  - 修复：当日回退 metric 700；①号结构修复 = tailscaled systemd drop-in 注入 `no_proxy`（见 vps 文档 2026-11-18 修订段）；根因与教训记入 `10_design/vps-tailscale-exit-node.md`。
  - 本应拦住它的检查：上述①–④（只做了 ICMP 预检，未验证 UDP/DNS/代理依赖链）。
- [ ] **DNS 兜底/解析器改动类**（2026-11-18，方案 B 实害回退）：给 DNS 加兜底解析器或钉解析器路径**之前**，先实测目标解析器的可达性与污染面——① 境外 DoH/IP 直连是否被墙（本例 `1.1.1.1:443` TCP FAIL、DoH 直连无响应）；② UDP:53 兜底对**境外域名**的回答是否会被 GFW 抢答污染，污染答案是否会与 geoip 分流叠加形成"→direct 挂死"（本例 gstatic `[socks -> direct]` 连续复现）。判定：污染注入比解析失败更危险，境外解析保持 fail-closed。
  - 本应拦住它的检查：改动前对目标解析器做直连 DoH/UDP 探测 + 对代表性境外域名做"兜底链解析→geoip 路由"端到端验证。
- [ ] **「某类地址必须直连」实现核对类**（2026-11-19，tailnet 绕 VPS 发夹）：给代理工具写分流模板时，凡设计写了「X 类地址直连」，逐条对照模板规则清单核实实现，**不得假设**上游内置规则已覆盖——sing-box 的 `ip_is_private` 只含 RFC1918，**不含 CGNAT `100.64.0.0/10`（Tailscale 段）**，tailnet IP 落 `route.final` 绕 VPS 发夹回本机（quiz 3.19s+）。修复：模板显式 `ip_cidr 100.64.0.0/10 → direct` + `domain_suffix .ts.net → direct`；固化：`test_singboxctl.sh` 结构断言「tailnet/ts.net direct」。检查方法：设计条目 ↔ 模板规则逐条勾对 + 用该网段真实地址实测一次并看 journal 出队。
- [ ] **流程偏离记录**（2026-11-18）：主出口被封锁期间 `vpnctl edit/rollback/restart` 的健康探针（`probe-in` 钉死主出口）必然失败，edit 会自动回滚——本次实验改用 `vpnctl validate` + 手动备份/安装/重启 + 主端口探测的偏离流程，结束即恢复原配置（与备份逐字节比对一致）。待主出口恢复后，验证 `vpnctl edit` 流程恢复正常。
