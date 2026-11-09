# xray 服务宕机事故记录（2026-11-04）

## 一句话

在 xray 路由规则里引用了 `geosite:office`，但 VPS 上的 `geosite.dat` 没有这个分类，配置校验失败，服务启动即退出，代理整体宕机约 1 小时。

## 时间线（均为北京时间）

| 时间 | 事件 |
|---|---|
| 2026-11-04 07:33:54 | 本人在 VPS 的 `/usr/local/etc/xray/config.json` 新增一条 `"geosite:office" → warp` 的分流规则 |
| 07:33:55 | xray 服务重启，加载配置失败（exit status=23），进程退出，8443 端口无人监听 |
| 07:55 | 发现本机代理不通，开始排查 |
| 08:13 | 确认 VPS 上 xray 服务 failed；`xray -test` 复现报错：`code not found in geosite.dat: OFFICE` |
| 08:19–08:29 | 方案 1（换 geosite.dat）证伪：Xray 官方 release 和 v2fly domain-list-community 的最新 dat 里**都没有** OFFICE 分类 |
| 08:44 | 方案 2 执行：删除该规则，备份原配置为 `config.json.bak-20261104`，重启服务 |
| 08:46 | 验证恢复：8443 监听正常，走代理访问 Google（200）、Telegram（302）均成功 |

## 症状

- 本机走代理访问任何网站全部超时（HTTP / SOCKS5 协议都是）
- VPS 本身存活：ping 通、SSH 22 端口开放，但 8443（vless）端口不通

## 根因

1. **直接原因**：`geosite:office` 这个域名分类在本机安装的 `geosite.dat`（2026-10-11 版）里不存在；xray 加载路由规则时校验失败，进程直接退出。
2. **流程原因**：改完配置后没有先跑 `xray -test` 验证就重启了服务——这是本可以避免的一步。
3. **认知原因**：以为 `geosite:office` 是标准分类。实测（2026-11-04）Xray-core 官方 release 和 v2fly domain-list-community 的最新 dat **都不包含 OFFICE**，不是版本太旧的问题，是这个分类根本不在主流列表里。

## 修复与回滚点

- 改动：从 `routing.rules` 删除那条 `geosite:office → warp` 规则（其余规则不动）
- 备份（回滚用，在 VPS 上）：
  - `/usr/local/etc/xray/config.json.bak-20261104`（含问题规则的原配置）
  - `/etc/resolv.conf.bak-20261104`、`/etc/netplan/00-installer-config.yaml.bak-20261104`（DNS 改动，见下）
- 回滚 = 恢复对应备份 + `systemctl restart xray`

## 防范措施（改 xray 配置的检查清单）

1. **重启前必跑验证**：`xray -test -config /usr/local/etc/xray/config.json`，输出 `Configuration OK.` 才允许 `systemctl restart xray`。
2. **引用 geosite 分类前，先确认当前 dat 里存在**：把最新 dat 下载到 `/tmp/xray-assets/`，用 `XRAY_LOCATION_ASSET=/tmp/xray-assets xray -test -config <配置>` 免替换验证；不要凭记忆引用分类名。
3. **保留回滚备份**：每次改配置前 `cp -n config.json config.json.bak-YYYYMMDD`（本次就是靠这个惯例有了对照）。
4. 可用的一键模式（改完先 test 再 restart，失败不落盘）：

   ```bash
   sudo cp /usr/local/etc/xray/config.json /tmp/config.new.json
   # 编辑 /tmp/config.new.json …
   xray -test -config /tmp/config.new.json && \
     sudo cp /tmp/config.new.json /usr/local/etc/xray/config.json && \
     sudo systemctl restart xray
   ```

## 已固化：`xray-apply`（2026-11-04 09:28 落地）

把上面第 4 条的「先 test 再 restart」做成 VPS 上的强制入口，避免再靠人手记：

```bash
sudo xray-apply /path/to/candidate.json          # 校验 → 备份 → 落盘 → 重启 → 起后自检
sudo xray-apply --check /path/to/candidate.json  # 只校验，不动线上
```

行为：

1. 先做 JSON 结构检查；
2. 用 `XRAY_LOCATION_ASSET=/usr/local/share/xray xray run -test` 校验（**分类名不存在这类错误由 xray 自己报**，脚本不重复造轮子——曾试图用 `strings` 匹配 dat，对 `geosite:microsoft` 误报，已删除该逻辑）；
3. 校验失败：**线上配置一字不动**，退出码 1；
4. 校验通过：`cp -n` 备份成 `config.json.bak-YYYYMMDD-HHMMSS`，落盘，`systemctl restart xray`；
5. 起后 5 秒内自检「服务 active + 8443 在监听」，不达标**自动回滚到备份并重启**；
6. candidate 就是线上文件时直接返回「nothing to apply」，不做无谓重启。

已验证：线上配置 `--check` 通过；`geosite:office` 候选被拒且线上不受影响；坏 JSON 被拒；正常候选可完成「备份→落盘→重启→自检」；同文件调用返回 no-op。

## 顺带发现并修复：VPS DNS 被污染

- 排查中发现这台**香港 VPS** 的系统 DNS 是 `223.5.5.5`（阿里）和 `114.114.114.114`——国内 DNS 对 Google/Twitter 返回**假地址**（`www.google.com` → `174.132.167.252` / `2001::1`，`twitter.com` 同样被投毒）。
- 代理服务器自己解析目标站域名，DNS 被污染等于代理拿着假 IP 去连，影响所有被墙域名的可用性。
- 已修复：`/etc/resolv.conf` 与 netplan 配置改为 `8.8.8.8` + `1.1.1.1`，重启 `systemd-resolved` 后验证 Google/Twitter 解析为真实地址。
- **教训：境外 VPS 不要用国内 DNS。** 这条与代理可用性直接相关，应列入 VPS 初始化检查项。

## 备注

- 同日 OpenRouter 的 `api.openrouter.ai` 域名 DNS 记录被官方删除（权威服务器都返回 NXDOMAIN），属对方事故，与本代理无关，等官方恢复。
- VPS sudo 密码曾在排查中以明文出现在 AI 会话记录里，建议尽快在 VPS 上 `passwd` 更换。
