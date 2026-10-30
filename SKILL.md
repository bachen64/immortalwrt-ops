---
name: immortalwrt-ops
description: ImmortalWrt / iStoreOS / OpenWrt 路由器运维（策略分流、WireGuard、IPv6、备份恢复与排障）。适用于：官方 pbr 包策略分流部署与修复（chnroute 导入、cron、动态 nft set）、WireGuard 全隧道 + metric 10/20 三重自动回退、WG 掉线/握手停滞排查（fake-ip、allowed_ips、endpoint）、IPv6 模式（PD/旁路由/systools）诊断、sysupgrade 备份与恢复、nftables/fw4 规则排障。触发词：PBR、策略路由、分流、chnroute、WireGuard 掉线、wg0、隧道不通、IPv6 PD、旁路由、ImmortalWrt 运维、路由器配置。
---

# ImmortalWrt 运维（策略分流 / WireGuard / IPv6 / 排障）

面向 ImmortalWrt 25.x / iStoreOS 24.x（fw4 + nftables 架构）的路由器远程运维。所有经验来自多台生产设备的实战部署与故障注入验证。

## 接入方式（控制端约定）

- 通过 SSH 控制远程设备（AI 运行在电脑上，不在设备上）。
- 连接：`ssh -i <key> root@<IP>`；长复合命令会卡住时（个别旁路由设备），拆成简单命令逐条执行。
- **只读优先**：先诊断（read-only），需要改动前向用户说明影响面并等待明确批准。任何"改配置"操作前先做备份。
- 设备端脚本一律用**纯英文注释**（路由器上中文会乱码）；SKILL.md 与 references 用中文无妨（AI 端阅读）。

## 快速诊断（read-only，先跑这些）

```sh
# 固件与包
cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION
# 分流规则与集合
ip rule | grep -E "30000|pbr|fwmark"
nft -j list sets inet fw4 | jq -r '.nftables[].set.name' | grep '^pbr_'
# WG 状态
wg show wg0
# 路由走向判定
ip route get 114.114.114.114    # 国内目标
ip route get 8.8.8.8            # 国外目标
# 出口 IP（curl 仅出口验证用，脚本本体不用它）
curl -s --connect-timeout 5 ifconfig.me
```

## 核心工作流

### 1. 官方 PBR 分流（推荐架构：默认全隧道 + 国内剥离）

- 架构：wg0 `allowed_ips '0.0.0.0/0' + '::/0'` + `route_allowed_ips '1'` 全接管（IPv4+IPv6），pbr 一条 policy 把国内 IPv4 剥离回 wan。
- **依赖**：jq（chnroute 脚本必需）+ uclient-fetch（系统内置，负责下载）；curl 仅出口验证；**勿装 wget-nossl**（无 SSL 支持，下载 HTTPS 会失败）。
- `/etc/config/pbr` 模板、policy `dest_addr='user'`、chnroute 脚本、cron：见 `references/pbr-chnroute.md`。
- **关键坑**：include 必须禁用（启动时序阻塞）；集合名带 policy section ID 后缀（`pbr_wan_4_dst_ip_cfg*`）必须动态探测；cron 每分钟检测 + 每天 --force 更新。
- 部署/修复后验证：`references/pbr-chnroute.md` 的验证清单。

### 2. 三重自动回退（metric 编排）

- wan `metric '20'`、wg0 `metric '10'`：pbr 停→国内走 wg0；wg0 停→国内走 wan；三层全断才断流。
- 架构说明与故障注入实测法：见 `references/failover-architecture.md`（故障注入务必用设备本地后台脚本，防 SSH 断连无法复原）。

### 3. WireGuard 掉线 / 握手停滞

按顺序排查（详见 `references/troubleshooting.md`）：
1. `wg show wg0` → endpoint 若为 `198.18.0.x`（fake-ip）且握手停滞 → OpenClash fake-ip 问题，**优先 reboot**（重启早期 OpenClash 未接管 DNS，WG 直连真实地址反而能握手）；**不要** ifdown/ifup wg0（握手归零更不通）。
2. 对端 ping 不通先查 peer `allowed_ips` 是否覆盖目标网段（WireGuard 按 allowed_ips 过滤数据面；缺网段会报 "Required key not available"）。
3. 本机不在目标子网时，用 hub 节点（如 56.1）做跳板探测，区分"对端离线"与"allowed_ips 缺网段"。

### 4. IPv6

- 旁路由拿不到 PD：先看 `odhcp6c` 参数（`-P0` = reqprefix auto，正常），根因通常是**光猫不开 DHCPv6-PD**（只发 SLAAC /64），非路由器配置问题。
- iStoreOS `systools.sh` 切 IPv6 模式（pd/relay/nat/half/off）会 `network reload`，PPPoE 下会重拨换前缀；half 模式 DDNS/socat 入站仍正常，别误判。
- 旁路由不要开 `ra 'server'`（与主路由/光猫抢 RA 会冲突）。

### 5. 备份与恢复（危险操作前必做）

```sh
sysupgrade -b /tmp/backup-$(date +%Y%m%d).tar.gz   # 配置备份
sysupgrade -r /tmp/backup-XXX.tar.gz               # 恢复
```
- iStoreOS 另有 overlay 全量备份：`/usr/libexec/istore/overlay-backup backup <DIR>`（恢复会自动重启）。
- 从备份提取配置对比当前状态（排查"残留改动"）：用 python tarfile 解包，diff `/etc/config/*`。

## 资源导航

| 文件 | 内容 | 何时读 |
|------|------|--------|
| `references/pbr-chnroute.md` | /etc/config/pbr 完整模板 + chnroute 脚本全文 + cron + 验证清单 | 部署/修复官方 PBR 分流时 |
| `references/failover-architecture.md` | 全隧道 + metric 10/20 架构 + 故障注入实测法 | 验证回退机制或复现断网故障时 |
| `references/troubleshooting.md` | 排障命令速查 + 已知坑清单 | 任何排障场景 |
| `scripts/pbr.user.chnroute` | 设备端 chnroute 灌入脚本（英文注释，支持 --force） | 部署到设备 `/usr/share/pbr/` |
| `scripts/check-route.sh` | 设备端分流健康检查（read-only） | 日常巡检 / 验证 |

> English versions of all references (for non-Chinese readers): `references/pbr-chnroute-en.md`, `references/failover-architecture-en.md`, `references/troubleshooting-en.md`.

## 铁律

- 改动前备份；read-only 能诊断就不先改。
- 异地设备（无现场）升级/改配置前：先开两个 SSH 会话、确认备用通道（ttyd 等）、备好 `sysupgrade -r` 还原、避开业务高峰。
- 不确定设备实际状态时，用"设备本地后台脚本"做故障注入，不要用控制端长阻塞命令。
