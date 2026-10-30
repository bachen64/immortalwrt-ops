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
| Peer unreachable, "Required key not available" | peer `allowed_ips` lacks the target subnet (WireGuard filters the data plane by allowed_ips) | `wg set wg0 peer <pub> allowed-ips <ip> <net>` |
| Disconnects every night at the same time | leftover IPv6/RA config on the device (e.g. an iStoreAPP plugin was installed for IPv6 testing then removed without restoring config) | diff `/etc/config/dhcp` and `network` against a backup, revert leftovers |
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

### IPv6

| Symptom | Root cause | Fix |
|---|---|---|
| Side router's wan6 gets no PD | ONT/光猫 (Telecom gateway etc.) defaults to SLAAC /64 only, DHCPv6-PD disabled | enable PD on the ONT; router side odhcp6c should carry `-P0` (reqprefix auto) |
| Prefix changes / re-dials after iStoreOS IPv6-mode switch | systools.sh does a `network reload`; PPPoE re-dials and gets a new prefix | record the old prefix first; in half mode DDNS/socat inbound still works — don't misdiagnose |
| Side router RA conflict | `ra 'server'` enabled, fighting the main router/ONT for RA | disable RA on the side router (no DHCPv6 server) |

### Other

| Symptom | Root cause | Fix |
|---|---|---|
| dnsmasq fails to start | `addnmount` is a **list-only** option; writing it as an option crashes it (uci show can't distinguish single-element list from option) | `uci add_list` or write `list addnmount` directly in the file |
| Chinese garbles in device scripts | router shell has no UTF-8 environment (busybox sh) | device-side scripts: English-only comments |
| Long compound SSH command hangs | interactive-shell limitation on some side routers | split into simple commands, run one by one |
| HTTPS download fails | installed `wget-nossl` (the name literally means no SSL) | use built-in `uclient-fetch` (script default) or install an SSL-capable wget/curl |

## Universal recovery

1. Config broken → `sysupgrade -r /tmp/backup-XXX.tar.gz` (one-shot restore; needs a backup)
2. Remote session lost → backup channel (ttyd bound to 0.0.0.0 / WG LAN / on-site)
3. fake-ip-style weirdness → reboot (repeatedly proven the most effective)
