# 排障速查 + 已知坑清单

## 命令速查（全部 read-only，先跑这些）

```sh
# 系统
cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION   # 固件版本
uptime; free -h; df -h /overlay                        # 资源
# 接口
ip -br a; ip route; ip rule; ip -6 route               # 地址/路由/策略路由
wg show wg0                                             # WG：latest-handshakes、endpoint、allowed_ips、transfer
# nftables（fw4）
nft list ruleset | head -100                            # 全量规则（大，建议 grep）
nft -j list sets inet fw4 | jq -r '.nftables[].set.name'  # 集合清单
# 服务
/etc/init.d/pbr status; logread | grep -E "pbr|wireguard" | tail -50
# 连通性
ping -c 2 10.0.0.1; ip route get 114.114.114.114; ip route get 8.8.8.8
curl -s --connect-timeout 5 ifconfig.me                 # 出口 IP
nslookup kcn01.dynv6.net 8.8.8.8                        # endpoint 解析（DDNS 是否漂移）
```

## 坑清单（按症状速查）

### WG 掉线 / 握手停滞

| 症状 | 根因 | 解法 |
|---|---|---|
| endpoint = `198.18.0.x` 且握手不动 | OpenClash fake-ip 把 WG endpoint 域名解析成 fake-ip | **优先 reboot**（重启早期 OpenClash 未接管 DNS，WG 直连真实地址可握手）；**不要** ifdown/ifup wg0（握手归零更难恢复） |
| 每晚固定掉线（周期 04:00 附近） | OpenClash 每日 auto-restart 的 DNS 波动 + endpoint 域名被 fake-ip 解析（Home 实测：`kcn01.dynv6.net` → `198.18.0.34`，真实是 240e:...） | **根治**：把 endpoint 域名加进 fake-ip 白名单 `/etc/openclash/custom/openclash_custom_fake_filter.list`（`custom_fakeip_filter_mode 'blacklist'` 下=真实解析），重启 OpenClash；`nslookup <域名> 127.0.0.1` 应返回真实 IP。⚠️ 文件末行可能无换行，`echo >>` 会拼进注释行——先 `tail` 检查，用 `printf '\n<域名>\n'` 独立成行 |
| 对端 ping 不通，报 "Required key not available" | peer `allowed_ips` 缺目标网段（WireGuard 按 allowed_ips 过滤数据面） | `wg set wg0 peer <pub> allowed-ips <ip> <net>` 补网段；UCI 持久化注意：`config wireguard_<if>` 是**匿名 section**，须用 `uci add_list network.@wireguard_<if>[0].allowed_ips=...`（按名字 `network.wireguard_wg0` 会报 Entry not found / Invalid argument） |
| 每晚固定掉线（IPv6 残留场景） | 设备上残留的 IPv6/RA 配置改动（如装过 iStoreAPP 插件后删除未还原） | 对比备份 diff `/etc/config/dhcp`、`network`，还原残留项 |
| 重启后不握手 | OpenClash 启动顺序/缓存；endpoint 用动态域名且 DNS 解析错误 | logread 查时序；试 `nslookup` 手动解析后临时换 IP endpoint |
| 对端（hub）PPPoE 重拨换 IPv6 前缀后，spoke 握手停在重拨时刻不恢复 | **换 PBR 时误删了 wg0-iface-manager cron job**（每 5 分钟检测对端 DDNS 变化，变了就 down/up wg0 重解析；WireGuard endpoint 域名只在接口启动时解析一次，接口不重启永远连旧地址） | 从备份恢复 `/usr/bin/wg0-iface-manager.sh` + cron `*/5 * * * *`（脚本见 `scripts/wg0-iface-manager.sh`，OneDrive `Attachments\backup\{Buero,JM1}` 有原版）；立即 `ifup wg0` 恢复当前断线 |

### PBR 分流异常

| 症状 | 根因 | 解法 |
|---|---|---|
| pbr restart 失败/启动阻塞 | include 脚本执行太早（集合未建） | `uci set pbr.include.enabled='0'`；改 cron 灌入 |
| 国内流量也走代理 | 集合为空（chnroute 没灌进去） | 手动 `/usr/share/pbr/pbr.user.chnroute --force`；查 cron 是否在 |
| 集合名对不上/报 set 不存在 | 集合名带 policy section ID 后缀，硬编码失效 | 动态探测：`nft -j list sets inet fw4 \| jq ... \| grep '^pbr_wan_4_dst_ip_'` |
| `dest_addr` 写文件路径/geo:cn 报错 | pbr 1.2.2 不支持文件路径与 geo:cn 前缀 | 用 `dest_addr='user'` + 脚本灌集合 |
| `uplink_interface` 配了 list 不生效 | uplink_interface 是字符串不是 list | `uci set`（单值）不是 `add_list` |
| 国外 IPv6 漏到本地 wan | policy src_addr 只写 IPv4，无 IPv6 兜底 | 本方案 ipv6_enabled=0，IPv6 全走 wg0 默认路由（含回退） |
| 与 OpenClash/mwan3 冲突 | mwan3 启动自动接管 ip rule；OpenClash TUN 抢标记 | 不共存 mwan3；pbr 用高位 fw_mask（00ff0000）隔离 |
| pbr 启动报 `Default fw4 chain 'mangle_forward' is missing!` | 设备防火墙是 **fw3/iptables 架构**（非 fw4）——pbr 1.2.2 强依赖 fw4 的 nftables mangle 链；**同版本固件的两台设备也可能一个 fw3 一个 fw4**（Buero=fw4、JM1=fw3 实测） | 先切 fw4：切前加 Allow-SSH 保命规则 → `apk del firewall && apk add firewall4` → `/etc/init.d/firewall restart`（可能 >60s，SSH 侧超时保护）→ 验证 `nft list tables` 出现 `inet fw4`。详见"其他"表 |
| 验证分流方向用不带 mark 的 `ip route get`，国内目标也显示走 wg0 | 不带 fwmark 的查询只走普通规则（默认全隧道 = 预期行为），无法反映 mangle 打标后的剥离 | 验证国内剥离用 `ip route get 114.114.114.114 mark 0x10000`（应走 pbr_wan 表/dev wan）；国外用 `ip route get 8.8.8.8`（不打标 → wg0） |

### IPv6

| 症状 | 根因 | 解法 |
|---|---|---|
| 旁路由 wan6 取不到 PD | 光猫（电信天翼网关等）默认只开 SLAAC /64，不开 DHCPv6-PD | 上光猫开 PD；路由器侧 odhcp6c 参数应为 `-P0`（reqprefix auto） |
| iStoreOS 切 IPv6 模式后前缀变/重拨 | systools.sh 会 network reload，PPPoE 下重拨换前缀 | 切换前记录旧前缀；half 模式 DDNS/socat 入站仍正常，别误判故障 |
| 旁路由 RA 冲突 | 开了 `ra 'server'` 与主路由/光猫抢 RA | 旁路由关 RA（不做 DHCPv6 server） |

### 其他

| 症状 | 根因 | 解法 |
|---|---|---|
| allowed_ips 已补但对端网段仍不通 | `wg set` 只改运行时 allowed_ips，**不触发 netifd 重建对端路由**（route_allowed_ips 的路由只在接口重配时生成） | 改完 UCI 后必须 `ifup wg0`（或 `/etc/init.d/network restart`），验证 `ip route \| grep <网段>` 出现 dev wg0 |
| fw4 报 `Section @nat[x] specifies unknown option 'dest'` | fw4 的 nat 规则**没有 dest 字段**（dest 是 zone forwarding 的概念）；LuCI 重配 firewall 时容易把 nat 规则丢掉 | nat 规则只需 `src` + `target 'MASQUERADE'`；确认生效：`nft list ruleset \| grep -i masquerade` 有对应 comment 且有 counter 命中 |
| dnsmasq 启动失败 | `addnmount` 是 **list-only** 选项，写成 option 会崩；且 uci show 无法区分单元素 list 与 option | 用 `uci add_list` 或直接改文件写 `list addnmount` |
| HTTPS 下载失败 | 装了 `wget-nossl`（包名即无 SSL 支持） | 用内置 `uclient-fetch`（脚本默认）或装带 SSL 的 wget/curl |
| 脚本里中文乱码 | 路由器终端编码（busybox sh 无 UTF-8 环境） | 设备端脚本一律纯英文注释 |
| SSH 长复合命令卡住 | 个别旁路由设备交互环境限制 | 拆成简单命令逐条执行 |
| 防火墙服务"active with no instances"且 iptables/nft 全空（**裸奔**） | 装了 fw3 包但 **fw3 二进制缺失**（`/usr/sbin/fw3: No such file or directory`），服务从未加载规则 | 识别：`nft list tables` 无 `inet fw4`/`ip` 系列表 + `iptables -t nat -L` 空；网络"稳定"仅靠 wg 隧道自持。切 fw4 根治（见 PBR 表对应行） |
| 切 fw3→fw4 后 SSH 连不上 | fw4 默认 wan input REJECT，而裸奔时代是 ACCEPT | **切换前先加 Allow-SSH 规则**（src wan / proto tcp / dest_port 22 / target ACCEPT）；或从 wg/lan zone 进 |
| firewall restart 挂起 >60s | `flowoffload='1'` 但内核**无 nf_flow_table_ipv4 模块** | 先 `ls /sys/module \| grep flow` 确认；无模块设备保持 `flowoffload='0'`（勿照抄 Buero 的 flow_offloading=1） |
| busybox 无 base64/od/timeout（精简版如 JM1） | 精简 busybox applet | 脚本部署用 ssh stdin 直传 `cat > 文件`（勿用 base64 中转）+ `sed -i 's/\r$//'` 去 CRLF；远程命令用 SSH 侧超时保护代替设备端 timeout |
| `logread` 的 cron.err 每分钟刷 `USER root pid X cmd ...`（如 pbr.user.chnroute） | busybox crond 把**每次任务执行**记入 syslog cron.err，该记录**不受 cronloglevel 过滤**（`-l 7`/`-l 8` 实测都记录；busybox 语义 0=最详细、8=默认最简，调档无效） | 改 `/etc/init.d/cron` 的 `procd_set_param command` 行尾加 `-L /tmp/crond.log`（日志转文件，logread 干净；文件在 /tmp 重启自清），再 `/etc/init.d/cron restart`。验证：`logread \| grep cron` 无新增 + `/tmp/crond.log` 有内容。Buero/JM1 已按此法收敛（2026-10-30） |
| `ssh-keyscan` 对 dropbear 设备报 `choose_kex: unsupported KEX method sntrup761x25519-sha512@openssh.com` 且拿不到 host key | Windows/新版 OpenSSH 的 keyscan 优先 post-quantum KEX（sntrup761），dropbear 不支持且 keyscan **不降级协商**（普通 ssh 客户端会完整协商所以连接正常） | 登录设备用 `dropbearkey -y -f /etc/dropbear/dropbear_<ed25519\|rsa\|ecdsa>_host_key` 导出公钥（dropbear 不自动生成 .pub），按 `<host> <type> <key>` 写入 known_hosts；OpenSSH 类服务器（如 56.1/56.252/13.2）用 `ssh-keyscan -t ed25519,rsa,ecdsa` 正常。验证 `ssh-keygen -F <host>` 逐条比对 |

## 万能恢复手段

1. 改错配置 → `sysupgrade -r /tmp/backup-XXX.tar.gz`（一键还原，需有备份）
2. 远程失联 → 备用通道（ttyd 绑 0.0.0.0 / WG 内网 / 现场）
3. fake-ip 类玄学 → 直接 reboot（多次验证最有效）
