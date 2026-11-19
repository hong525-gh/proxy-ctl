# sing-box-client（方案 B，staging 阶段）

设计文档：[`design.md`](design.md)。VPS 服务端仍是 xray，本目录只做 Fedora
本地客户端迁移。staging 与生产 xray 并存：staging 用 18080～18083，
生产 xray 继续独占 10808～10811，互不影响。

## 文件

- `design.md` — 方案、边界、验收清单、变更记录
- `config.template.json` — 无凭据模板（入站/路由/规则集引用）
- `singboxctl.sh` — 运维入口（install / generate / validate / run / status / check）
- `sing-box-client-test.service` — staging systemd user 单元
- `test_singboxctl.sh` — 离线验收测试（mock xray 配置，无网络）

## 一次性安装（已完成 2026-11-19，重装机时按证据文件重做）

- 二进制：`~/.local/lib/sing-box/1.14.1/sing-box` + `current` 符号链接
  + `~/.local/bin/sing-box`
- 规则集：`~/.local/share/sing-box/rule-sets/{geoip-cn,geosite-cn,geosite-private}.srs`
- 版本、URL、SHA256 与核定过程：
  `~/.local/state/sing-box-client/upgrades/2026-11-19-source-baseline.md`

## 日常操作

```bash
bash singboxctl.sh install    # 核对二进制/规则集哈希
bash singboxctl.sh validate   # 生成运行时配置 + 策略自检 + sing-box check
systemctl --user link $PWD/sing-box-client-test.service
systemctl --user start sing-box-client-test.service
bash singboxctl.sh status     # 服务状态 + 18080-18083 监听
bash singboxctl.sh check      # 经各诊断入站的健康探针（服务须已启动）
```

运行时配置每次启动前重新生成到 `$XDG_RUNTIME_DIR/sing-box-client/`（0700/0600，
tmpfs），凭据只从 `~/.config/xray/config.json` 只读提取，不落地第二份持久副本。
`route.final` 跟随 xray `outbounds` 中第一个代理出站，主备模式自动保持一致。

staging 回滚：`systemctl --user stop sing-box-client-test.service`，
xray 全程未被触碰。

## 测试

```bash
bash test_singboxctl.sh     # 离线 mock 测试
bash test_proxy.sh          # 仓库既有测试（仓库根目录）
bash 10_design/xray-client/test_vpnctl.sh
```
