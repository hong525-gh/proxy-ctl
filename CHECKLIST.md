# Check List

每类错误一条可执行检查项，进验收/自查阶段；新错误按"症状/根因/修复/本应拦住它的检查"追加。

- [ ] **网络拓扑变更类**（2026-11-18，metric 700→500 当日回退）：调整默认路由优先级 / 切换主备物理线路**之前**，先在目标拓扑下验证依赖链数据面，而非只 ping 网关——最小检查集：① `tailscale netcheck` 在该线路上 UDP 是否可用（本例蜂窝有线 UDP 被阻断）；② MagicDNS 上游路径（`dig @100.100.100.100`）在该线路上是否可达；③ tailscaled DERP/控制面的出口路径（GNOME 系统代理 → xray → 出站）是否与被切换线路构成循环依赖；④ `vpnctl status` 的当前出站是 primary 还是 backup（backup=tailnet 时，tailnet 死 = 代理死）。
  - 症状：metric 改 500 后，用户断开 WiFi 仅用有线，国内外网站一律打不开（其他设备走 M245 WiFi 正常）。
  - 根因：循环依赖死锁——蜂窝线路 UDP 阻断 → tailnet 仅剩 DERP；DERP/控制面经 GNOME 代理 → xray → 默认出站 = proxy-backup（tailnet，因主出口 8443 从本机不通而卡在 backup）→ 死锁；系统 DNS（MagicDNS→VPS）与 xray 非 cn DoH 同死。
  - 修复：当日回退 metric 700；根因与教训记入 `10_design/vps-tailscale-exit-node.md` 2026-11-18 修订段。
  - 本应拦住它的检查：上述①–④（只做了 ICMP 预检，未验证 UDP/DNS/代理依赖链）。
