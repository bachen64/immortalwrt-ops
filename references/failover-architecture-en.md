# Full-Tunnel + metric 10/20: Triple Automatic Failover Architecture

> Production-verified on Buero (123.1), fault-injection tested 2026-10-29.

## Architecture

```
wg0 allowed_ips '0.0.0.0/0' + '::/0'  route_allowed_ips '1'  metric '10'   # default full takeover (IPv4+IPv6)
wan                                   metric '20'                          # physical uplink fallback
pbr (ignored_interface=wg0)           CN IPv4 → wan                        # offload rule
```

- pbr does exactly one thing: strip CN IPv4 from the tunnel back to wan. Everything else rides wg0's default route.
- Peer-subnet routes are managed automatically by wg0's `route_allowed_ips` (peer `allowed_ips` covers them → routes appear). **Do not** hand-write static routes into a wg0 table.

## The triple fallback chain

```
pbr stops ──► CN IPv4 loses the offload rule ──► rides wg0 tunnel (still online, CN traffic detours via proxy)
wg0 stops ──► default route gone ──► rides wan physical uplink (CN traffic fully normal)
wan also down ──► no route left ──► CN traffic truly dead
```

| Failure layer | Remaining path | CN traffic status |
|---|---|---|
| pbr only down | wg0 | online, but CN detours via proxy |
| pbr + wg0 down | wan | fully normal |
| all three down | none | dead |

## Fault-injection method (lesson: never lose your SSH session)

**Do NOT** run `ifdown wg0` / `stop pbr` from the controller (the SSH session dies and nothing auto-recovers). Instead: push the fault-injection script onto the device itself and run it in the background with setsid, auto-recovering on a timer:

```sh
# on the device (OpenWrt has no nohup, use setsid)
cat > /root/fault-inject.sh <<'EOF'
#!/bin/sh
# stop pbr after 30 s, restart after 60 s — recovers by itself
/etc/init.d/pbr stop
sleep 30
/etc/init.d/pbr start
EOF
chmod +x /root/fault-inject.sh
setsid /root/fault-inject.sh </dev/null >/dev/null 2>&1 &
```

Meanwhile sample from the controller (every 10 s):

```sh
while true; do date +%T; ip route get 114.114.114.114 | head -1; sleep 10; done
```

Measured record (Buero, 2026-10-29):
- Baseline: dual default routes `wg0 metric 10` + `wan metric 20` ✓
- `pbr stop` → 114.114.114.114 switches from `pbr_wan→wan` to `dev wg0`, rule 30000 gone ✓
- `pbr start` → rules rebuild automatically ✓
- `ifdown wg0` → only `wan metric 20` remains, exit IP = 121.231.144.212 (local CN ISP) ✓
- `ifup wg0` → restored ✓

> Note: LAN users see a few seconds of jitter during injection (measured: full cycle recovers within 30 s). Tell users before injecting faults on production gear.
