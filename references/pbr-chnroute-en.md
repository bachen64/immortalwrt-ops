# Official PBR Policy Routing: Complete Configuration (ImmortalWrt 25.x / iStoreOS)

> Proven on production: Buero (123.1) + Test (31.1). Package: pbr 1.2.2-r20 (fw4/nftables).
> Architecture: **default full-tunnel + CN offload** — wg0 carries everything (IPv4+IPv6), one pbr policy strips CN IPv4 back to wan.

## 1. Install packages & dependencies

```sh
opkg update && opkg install pbr luci-app-pbr jq curl   # ImmortalWrt 25.x uses apk: apk update && apk add pbr luci-app-pbr jq curl
```

| Component | Required? | Purpose |
|---|---|---|
| `jq` | **Required** | chnroute script parses nft JSON (dynamic set-name probe / element count) |
| `uclient-fetch` | Built-in | downloader used by the script (lightweight, HTTPS + `--no-check-certificate`), **no wget needed** |
| `curl` | Recommended | exit-IP verification only (`ifconfig.me` needs HTTPS), not a script dependency |
| `wget-nossl` | **Do NOT install** | no SSL support — HTTPS downloads always fail (learned the hard way) |

## 2. /etc/config/pbr (production-tested template)

```sh
config pbr 'config'
	option enabled '1'
	option fw_mask '00ff0000'
	option ipv6_enabled '0'              # IPv6 rides the wg0 default route; pbr manages IPv4 only
	option nft_rule_counter '0'
	option nft_set_auto_merge '1'
	option nft_set_counter '0'
	option nft_set_flags_interval '1'
	option nft_set_flags_timeout '0'
	option nft_set_policy 'performance'
	option nft_user_set_counter '0'
	option procd_boot_trigger_delay '5000'   # boot delay, lets wg0 come up first
	option procd_reload_delay '0'
	option resolver_set 'dnsmasq.nftset'
	option strict_enforcement '1'        # killswitch: no leak when the interface is down
	option uplink_interface 'wan'        # STRING, not a list!
	option uplink_interface6 'wan6'
	option uplink_ip_rules_priority '30000'
	option uplink_mark '00010000'
	option verbosity '2'
	list ignored_interface 'wg0'         # pbr leaves wg0 alone
	list lan_device 'br-lan'
	list resolver_instance '*'
	option config_compat '27'
	option config_version '1.2.2-r20'
	option rule_create_option 'add'
	option webui_show_ignore_target '0'
	list supported_interface 'wan'

config policy
	option name 'Bypass China'
	option dest_addr 'user'              # auto-creates the pbr_wan_4_dst_ip_cfg* set
	option interface 'wan'

config include
	option path '/usr/share/pbr/pbr.user.chnroute'
	option enabled '0'                   # MUST stay disabled! see pitfall 1
```

**Key points**:
- `uplink_interface` is a **string** (not a list); using `uci add_list` breaks interface detection.
- `dest_addr='user'` is the only reliable chnroute path: the policy auto-creates the user set, the script fills it.
- `ignored_interface wg0`: pbr does not manage wg0; wg0's own full-tunnel default route is the fallback.

## 3. chnroute import script (/usr/share/pbr/pbr.user.chnroute)

Full script: `../scripts/pbr.user.chnroute` (deploy as-is; English-only comments to avoid router-shell garbling). Core logic:

1. Probe the set name dynamically: `nft -j list sets inet fw4 | jq ... | grep '^pbr_wan_4_dst_ip_'`
2. Set missing → exit (never blocks pbr startup)
3. Default mode + set non-empty → exit silently
4. `--force` or set empty → flush set → download `https://ispip.clang.cn/all_cn.txt` → filter valid CIDRs → `nft -f -` atomic import

Dependencies: jq, uclient-fetch (built-in). Alternative source: `https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt`.

## 4. cron (replaces include; solves the boot-timing problem)

```sh
# every minute: exit silently if the set is non-empty, import only when empty (≤1 min recovery after pbr restart)
* * * * * /usr/share/pbr/pbr.user.chnroute
# every day 04:30: --force refresh of chnroute
30 4 * * * /usr/share/pbr/pbr.user.chnroute --force
```

## 5. Verification checklist

```sh
ip rule | grep -E "30000|pbr"                    # expect: 30000: from all fwmark 0x10000 lookup pbr_wan
nft list sets inet fw4 | grep pbr_wan_4_dst_ip_   # set exists
NFT_SET=$(nft -j list sets inet fw4 | jq -r '.nftables[].set.name' | grep '^pbr_wan_4_dst_ip_')
nft list set inet fw4 $NFT_SET | grep -c '/'      # element count ≥2900
ip route get 114.114.114.114                      # → dev wan
ip route get 8.8.8.8                              # → dev wg0
curl -s --connect-timeout 5 ifconfig.me           # global exit = proxy IP
curl -s --connect-timeout 5 https://www.baidu.com -o /dev/null -w '%{http_code}'  # CN 200
```

## Pitfalls (each one cost real debugging time)

1. **include MUST be disabled**: during pbr startup the set is not created yet; an include that imports data crashes the start. Replace with cron.
2. **Set name carries a cfg suffix**: `pbr_wan_4_dst_ip_cfg026ff5` — the `cfg026ff5` part is the policy section ID, **never hard-code it**; probe dynamically.
3. **cron frequency**: hourly is too slow (nearly 1 h recovery after pbr restart); every-minute + daily `--force` is the right combo.
4. `dest_addr` **does not accept file paths** (Unknown entry) and geo:cn prefixes are unsupported in pbr 1.2.2. Only reliable path: `dest_addr='user'` + script-filled set.
5. `uplink_interface` is a string, not a list.
6. **IPv6 fallback**: a policy whose `src_addr` only lists IPv4 does not auto-generate IPv6 fallback rules; with `ipv6_enabled=0` all IPv6 rides the wg0 default route (including fallback), avoiding silent IPv6 leaks to the local wan.
