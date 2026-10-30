# Troubleshooting Cheat-Sheet + Known Pitfalls

## Quick commands (all read-only — run these first)

```sh
# system
cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION   # firmware version
uptime; free -h; df -h /overlay                        # resources
# interfaces
ip -br a; ip route; ip rule; ip -6 route               # addrs / routes / policy routes
wg show wg0                                             # WG: latest-handshakes, endpoint, allowed_ips, transfer
# nftables (fw4)
nft list ruleset | head -100                            # full ruleset (big — grep it)
nft -j list sets inet fw4 | jq -r '.nftables[].set.name'  # set inventory
# services
/etc/init.d/pbr status; logread | grep -E "pbr|wireguard" | tail -50
# connectivity
ping -c 2 10.0.0.1; ip route get 114.114.114.114; ip route get 8.8.8.8
curl -s --connect-timeout 5 ifconfig.me                 # exit IP
nslookup kcn01.dynv6.net 8.8.8.8                        # endpoint resolution (DDNS drift?)
```

## Pitfall list (look up by symptom)

### WireGuard down / stale handshake

| Symptom | Root cause | Fix |
|---|---|---|
| endpoint = `198.18.0.x`, handshake frozen | OpenClash fake-ip mapped the WG endpoint domain to a fake-ip | **Reboot first** (right after boot OpenClash has not hijacked DNS yet, WG handshakes against the real address); **do NOT** ifdown/ifup wg0 (handshake resets to zero, worse) |
| Peer unreachable, "Required key not available" | peer `allowed_ips` lacks the target subnet (WireGuard filters the data plane by allowed_ips) | `wg set wg0 peer <pub> allowed-ips <ip> <net>`; to persist via UCI note `config wireguard_<if>` is an **anonymous section** — use `uci add_list network.@wireguard_<if>[0].allowed_ips=...` (by-name `network.wireguard_wg0` yields Entry not found / Invalid argument) |
| Disconnects every night (~04:00) | OpenClash daily auto-restart DNS window + endpoint domain resolved to a fake-ip (measured on Home: `kcn01.dynv6.net` → `198.18.0.34`, real is 240e:...) | **Root fix**: whitelist the endpoint domain in `/etc/openclash/custom/openclash_custom_fake_filter.list` (with `custom_fakeip_filter_mode 'blacklist'` = real resolution), restart OpenClash; `nslookup <domain> 127.0.0.1` must return the real IP. ⚠️ File may lack a trailing newline — `echo >>` glues onto the last comment line; `tail` first, append with `printf '\n<domain>\n'` |
| Disconnects every night at the same time (leftover-IPv6 scenario) | leftover IPv6/RA config on the device (e.g. an iStoreAPP plugin was installed for IPv6 testing then removed without restoring config) | diff `/etc/config/dhcp` and `network` against a backup, revert leftovers |
| No handshake after reboot | OpenClash startup order/cache; endpoint is a DDNS name with wrong resolution | check logread timing; `nslookup` the name manually, temporarily pin the IP endpoint |

### PBR routing anomalies

| Symptom | Root cause | Fix |
|---|---|---|
| pbr restart fails / startup blocked | include script runs too early (set not created yet) | `uci set pbr.include.enabled='0'`; import via cron instead |
| CN traffic also goes via proxy | set is empty (chnroute not imported) | run `/usr/share/pbr/pbr.user.chnroute --force` manually; check the cron entry |
| "set not found" / name mismatch | set name carries the policy section-ID suffix; hard-coding fails | probe dynamically: `nft -j list sets inet fw4 \| jq ... \| grep '^pbr_wan_4_dst_ip_'` |
| `dest_addr` with file path / geo:cn errors | pbr 1.2.2 supports neither | use `dest_addr='user'` + script-filled set |
| `uplink_interface` as a list has no effect | uplink_interface is a string, not a list | `uci set` (single value), not `add_list` |
| Global IPv6 leaks to local wan | policy `src_addr` lists IPv4 only, no IPv6 fallback | keep `ipv6_enabled=0`: all IPv6 rides the wg0 default route (fallback included) |
| Conflicts with OpenClash / mwan3 | mwan3 grabs `ip rule` on start; OpenClash TUN fights over marks | do not co-install mwan3; pbr uses high fw_mask (`00ff0000`) to stay isolated |
| pbr fails to start: `Default fw4 chain 'mangle_forward' is missing!` | device firewall is **fw3/iptables**, not fw4 — pbr 1.2.2 hard-requires fw4's nftables mangle chains; **two devices on the same firmware version can differ** (measured: Buero=fw4, JM1=fw3) | switch to fw4 first: add an Allow-SSH lifeline rule → `apk del firewall && apk add firewall4` → `/etc/init.d/firewall restart` (may exceed 60s; protect with an SSH-side timeout) → verify `nft list tables` shows `inet fw4`. See "Other" table |
| `ip route get` without a mark shows CN targets going via wg0 | unmarked lookups follow the plain rules only (full-tunnel default IS the expected behavior); they can't reflect the mangle marking | verify the CN bypass with `ip route get 114.114.114.114 mark 0x10000` (must hit table pbr_wan / dev wan); foreign with `ip route get 8.8.8.8` (unmarked → wg0) |

### IPv6

| Symptom | Root cause | Fix |
|---|---|---|
| Side router's wan6 gets no PD | ONT/光猫 (Telecom gateway etc.) defaults to SLAAC /64 only, DHCPv6-PD disabled | enable PD on the ONT; router side odhcp6c should carry `-P0` (reqprefix auto) |
| Prefix changes / re-dials after iStoreOS IPv6-mode switch | systools.sh does a `network reload`; PPPoE re-dials and gets a new prefix | record the old prefix first; in half mode DDNS/socat inbound still works — don't misdiagnose |
| Side router RA conflict | `ra 'server'` enabled, fighting the main router/ONT for RA | disable RA on the side router (no DHCPv6 server) |

### Other

| Symptom | Root cause | Fix |
|---|---|---|
| Peer subnet still unreachable after allowed_ips updated | `wg set` only changes the runtime allowed_ips — it does **not** make netifd rebuild peer routes (route_allowed_ips routes are created on interface reconfig only) | after changing UCI, run `ifup wg0` (or `/etc/init.d/network restart`); verify `ip route \| grep <subnet>` shows `dev wg0` |
| fw4 reports `Section @nat[x] specifies unknown option 'dest'` | fw4 nat rules have **no `dest` field** (dest belongs to zone forwarding); re-saving firewall via LuCI often drops the nat rule | nat rule needs only `src` + `target 'MASQUERADE'`; verify live: `nft list ruleset \| grep -i masquerade` shows the rule with a non-zero counter |
| dnsmasq fails to start | `addnmount` is a **list-only** option; writing it as an option crashes it (uci show can't distinguish single-element list from option) | `uci add_list` or write `list addnmount` directly in the file |
| Chinese garbles in device scripts | router shell has no UTF-8 environment (busybox sh) | device-side scripts: English-only comments |
| Long compound SSH command hangs | interactive-shell limitation on some side routers | split into simple commands, run one by one |
| HTTPS download fails | installed `wget-nossl` (the name literally means no SSL) | use built-in `uclient-fetch` (script default) or install an SSL-capable wget/curl |
| Firewall service "active with no instances" and iptables/nft are all empty (**bare-metal/no rules**) | fw3 package installed but the **fw3 binary is missing** (`/usr/sbin/fw3: No such file or directory`), rules never loaded | fingerprint: `nft list tables` has neither `inet fw4` nor `ip` tables + `iptables -t nat -L` empty; network "stability" rides solely on the wg tunnel. Root fix: switch to fw4 (see PBR table row) |
| SSH unreachable right after fw3→fw4 switch | fw4 defaults to wan input REJECT; the bare-metal era was ACCEPT | **add an Allow-SSH rule BEFORE switching** (src wan / proto tcp / dest_port 22 / target ACCEPT); or reach it via the wg/lan zone |
| `firewall restart` hangs >60s | `flowoffload='1'` but the kernel has **no nf_flow_table_ipv4 module** | check `ls /sys/module \| grep flow` first; keep `flowoffload='0'` on module-less devices (don't copy Buero's flow_offloading=1 blindly) |
| busybox lacks base64/od/timeout (stripped builds like JM1) | stripped busybox applets | deploy scripts via ssh stdin `cat > file` (no base64 hop) + `sed -i 's/\r$//'` for CRLF; use SSH-side timeouts instead of device-side `timeout` |
| `logread` cron.err floods every minute with `USER root pid X cmd ...` (e.g. pbr.user.chnroute) | busybox crond logs **every cron job execution** to syslog cron.err; this line is **not filtered by cronloglevel** (measured: `-l 7` and `-l 8` both log; busybox semantics 0=most verbose, 8=default least — raising the level does nothing) | append `-L /tmp/crond.log` to the `procd_set_param command` line in `/etc/init.d/cron` (logs go to a file, logread stays clean; the file lives in /tmp and is cleared on reboot), then `/etc/init.d/cron restart`. Verify: no new `logread \| grep cron` lines + `/tmp/crond.log` has content. Applied to Buero/JM1 on 2026-10-30 |

## Universal recovery

1. Config broken → `sysupgrade -r /tmp/backup-XXX.tar.gz` (one-shot restore; needs a backup)
2. Remote session lost → backup channel (ttyd bound to 0.0.0.0 / WG LAN / on-site)
3. fake-ip-style weirdness → reboot (repeatedly proven the most effective)
