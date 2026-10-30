# 官方 PBR 包策略分流：完整配置（ImmortalWrt 25.x / iStoreOS）

> 实战验证来源：Buero (123.1) 生产部署 + Test (31.1) 攻关。包版本：pbr 1.2.2-r20（fw4/nftables）。
> 架构：**默认全隧道 + 国内剥离**——wg0 全接管 IPv4+IPv6，pbr 一条 policy 把国内 IPv4 剥离回 wan。

## 1. 装包与依赖

```sh
opkg update && opkg install pbr luci-app-pbr jq curl   # ImmortalWrt 25.x 用 apk：apk update && apk add pbr luci-app-pbr jq curl
```

| 组件 | 必需性 | 用途 |
|---|---|---|
| `jq` | **必需** | chnroute 脚本解析 nft JSON（动态探测集合名/元素数） |
| `uclient-fetch` | 内置 | 脚本下载 chnroute 用（轻量、支持 HTTPS、`--no-check-certificate`），**无需装 wget** |
| `curl` | 建议 | 仅出口验证（`ifconfig.me` 需 HTTPS），非脚本依赖 |
| `wget-nossl` | **勿装** | 无 SSL 支持，下载 HTTPS 资源必失败（曾踩坑） |

## 2. /etc/config/pbr（生产实测模板）

```sh
config pbr 'config'
	option enabled '1'
	option fw_mask '00ff0000'
	option ipv6_enabled '0'              # IPv6 全走 wg0 默认路由，pbr 只管 IPv4
	option nft_rule_counter '0'
	option nft_set_auto_merge '1'
	option nft_set_counter '0'
	option nft_set_flags_interval '1'
	option nft_set_flags_timeout '0'
	option nft_set_policy 'performance'
	option nft_user_set_counter '0'
	option procd_boot_trigger_delay '5000'   # 启动延迟，等 wg0 就绪
	option procd_reload_delay '0'
	option resolver_set 'dnsmasq.nftset'
	option strict_enforcement '1'        # 严格熔断：接口 Down 时流量不泄漏
	option uplink_interface 'wan'        # 字符串不是 list！
	option uplink_interface6 'wan6'
	option uplink_ip_rules_priority '30000'
	option uplink_mark '00010000'
	option verbosity '2'
	list ignored_interface 'wg0'         # pbr 不触碰 wg0
	list lan_device 'br-lan'
	list resolver_instance '*'
	option config_compat '27'
	option config_version '1.2.2-r20'
	option rule_create_option 'add'
	option webui_show_ignore_target '0'
	list supported_interface 'wan'

config policy
	option name 'Bypass China'
	option dest_addr 'user'              # 自动创建 pbr_wan_4_dst_ip_cfg* 集合
	option interface 'wan'

config include
	option path '/usr/share/pbr/pbr.user.chnroute'
	option enabled '0'                   # 必须禁用！见坑 1
```

**要点**：
- `uplink_interface` 是**字符串**（不是 list），用 `uci add_list` 会识别失败。
- `dest_addr='user'` 是 chnroute 唯一可靠路径：policy 声明时自动创建 user 集合，脚本往集合灌元素。
- `ignored_interface wg0`：pbr 不管理 wg0，wg0 全隧道默认路由自己兜底。

## 3. chnroute 灌入脚本（/usr/share/pbr/pbr.user.chnroute）

脚本全文见 `../scripts/pbr.user.chnroute`（设备端部署，英文注释防乱码）。核心逻辑：

1. 动态探测集合名：`nft -j list sets inet fw4 | jq ... | grep '^pbr_wan_4_dst_ip_'`
2. 集合不存在 → 退出（不阻塞 pbr）
3. 默认模式 + 集合非空 → 静默退出
4. `--force` 或集合空 → flush set → 下载 `https://ispip.clang.cn/all_cn.txt` → 过滤合法 CIDR → `nft -f -` 原子灌入

依赖：jq、uclient-fetch（自带）；下载源可换 `https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt`。

## 4. cron（替代 include，解决启动时序）

```sh
# 每分钟：set 非空静默退出，为空才灌入（pbr restart 后最多 1 分钟恢复）
* * * * * /usr/share/pbr/pbr.user.chnroute
# 每天 4:30：--force 强制更新 chnroute
30 4 * * * /usr/share/pbr/pbr.user.chnroute --force
```

## 5. 验证清单

```sh
ip rule | grep -E "30000|pbr"                    # 应见 30000: from all fwmark 0x10000 lookup pbr_wan
nft list sets inet fw4 | grep pbr_wan_4_dst_ip_   # 集合存在
NFT_SET=$(nft -j list sets inet fw4 | jq -r '.nftables[].set.name' | grep '^pbr_wan_4_dst_ip_')
nft list set inet fw4 $NFT_SET | grep -c '/'      # 元素数 ≥2900
ip route get 114.114.114.114                      # → dev wan
ip route get 8.8.8.8                              # → dev wg0
curl -s --connect-timeout 5 ifconfig.me           # 国外出口 = 代理 IP
curl -s --connect-timeout 5 https://www.baidu.com -o /dev/null -w '%{http_code}'  # 国内 200
```

## 坑回顾（每个都付过学费）

1. **include 必须禁用**：PBR 启动时集合还没创建，include 灌入会导致启动失败。改 cron 替代。
2. **集合名带 cfg 后缀**：`pbr_wan_4_dst_ip_cfg026ff5` 里的 `cfg026ff5` 是 policy 的 section ID，**不可硬编码**——脚本必须动态探测。
3. **cron 频率**：每小时太慢（pbr restart 后要等近 1 小时恢复），每分钟 + 每日 --force 是正解。
4. `dest_addr` **不支持文件路径**（报 Unknown entry）；geo:cn 前缀也不支持（pbr 1.2.2 中）。唯一可靠路径：`dest_addr='user'` + 脚本灌集合。
5. `uplink_interface` 是字符串不是 list。
6. **IPv6 兜底**：policy `src_addr` 只写 IPv4 时不会自动生成 IPv6 兜底规则；本方案 ipv6_enabled=0 让 IPv6 全走 wg0 默认路由（含回退），避免 IPv6 国外流量静默漏到本地 wan。
