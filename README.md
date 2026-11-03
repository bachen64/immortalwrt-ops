# immortalwrt-ops

AI-agent Skill for operating **ImmortalWrt / iStoreOS / OpenWrt** routers (fw4 + nftables).
Battle-tested on production devices — smart routing (official `pbr`), WireGuard failover, chnroute, IPv6 and troubleshooting.

## What it covers

- **Official PBR smart routing** ("default full-tunnel + CN offload"): `/etc/config/pbr` production template, `dest_addr='user'` policy, dynamic nft-set detection, cron-based chnroute import (`--force` daily update).
- **Triple automatic failover**: wg0 `metric 10` + wan `metric 20` — pbr down → traffic falls back to wg0; wg0 down → falls back to wan; nothing breaks silently. Fault-injection method included.
- **WireGuard diagnosis**: fake-ip endpoint stalls (OpenClash), missing `allowed_ips` ("Required key not available"), nightly disconnects; plus `wg0-iface-manager.sh` cron self-heal (DDNS change detection, local-endpoint recovery, v2.7 DISCONNECTED recovery).
- **IPv6**: DHCPv6-PD issues (ONT/光猫 not delegating prefixes), iStoreOS `systools.sh` mode-switch side effects, RA conflicts on side routers.
- **Backup/restore**: `sysupgrade -b/-r`, iStoreOS overlay backup, config diffing against backups.
- **Troubleshooting cheat-sheet**: symptom → root cause → fix (include timing, `uplink_interface` string-vs-list, `addnmount` list-only, `wget-nossl` no-SSL, and more).

## Install

Copy (or clone) the `immortalwrt-ops` folder into your agent's skill directory, e.g.:

```text
<agent-workspace>/.user_skills/immortalwrt-ops/
├── SKILL.md
├── references/
│   ├── pbr-chnroute.md
│   ├── failover-architecture.md
│   └── troubleshooting.md
└── scripts/
    ├── pbr.user.chnroute     # deploy to router: /usr/share/pbr/pbr.user.chnroute
    ├── check-route.sh        # read-only health check, run on router
    └── wg0-iface-manager.sh  # wg0 DDNS self-heal v2.7 — deploy to /usr/bin/ + cron */5
```

> This repo also ships `scripts/wg0-iface-manager-en.sh` (mirror of the active
> English version above) and `scripts/wg0-iface-manager.sh` in the repo root as
> the Chinese-comment edition for reference; the router deployment uses the
> English active file.

## Requirements (on the router)

| Component | Needed for |
|---|---|
| `jq` | chnroute script (nft JSON parsing) — required |
| `uclient-fetch` | built-in downloader used by the script — no wget needed |
| `curl` | optional, exit-IP verification |
| `pbr` / `luci-app-pbr` | official policy-based-routing package (opkg/apk) |

> Do **not** install `wget-nossl` (no SSL support — HTTPS downloads fail).

## Safety notes

- Device-side scripts use English-only comments (Chinese garbles on router shells).
- Always back up (`sysupgrade -b`) before changing config on remote/edge devices.
- The included `pbr.user.chnroute` is the exact script running in production (2026-10) on a 24/7 router.

## License

MIT (see LICENSE).
