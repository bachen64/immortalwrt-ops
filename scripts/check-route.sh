#!/bin/sh
# Route/failover health check for OpenWrt/ImmortalWrt pbr + WireGuard setup
# Read-only: run on the router or via SSH, no changes made.
# Usage: sh check-route.sh [CN_IP] [GLOBAL_IP]
# Default targets: 114.114.114.114 (CN), 8.8.8.8 (global)

CN="${1:-114.114.114.114}"
GLOBAL="${2:-8.8.8.8}"

echo "== Firmware =="
cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION
echo "== WG handshake =="
wg show wg0 | grep -E "latest handshake|endpoint|transfer" 
echo "== ip rule (pbr) =="
ip rule | grep -E "30000|pbr" || echo "  (no pbr rules)"
echo "== chnroute set =="
NFT_SET=$(nft -j list sets inet fw4 2>/dev/null | jq -r '.nftables[].set.name' | grep '^pbr_wan_4_dst_ip_' | head -1)
if [ -n "$NFT_SET" ]; then
    CNT=$(nft -j list set inet fw4 "$NFT_SET" 2>/dev/null | jq 'try (.nftables[] | select(.set) | .set.elem | length) // 0')
    echo "  set=$NFT_SET elements=$CNT"
else
    echo "  (chnroute set not found)"
fi
echo "== Default routes =="
ip route | grep default
echo "== Route to CN ($CN) =="
ip route get "$CN" | head -1
echo "== Route to global ($GLOBAL) =="
ip route get "$GLOBAL" | head -1
echo "== Peer reachability =="
for HOST in 10.0.0.1 192.168.56.1; do
    if ping -c 1 -W 1 "$HOST" >/dev/null 2>&1; then
        echo "  $HOST OK"
    else
        echo "  $HOST FAIL"
    fi
done
echo "== Exit IP (global) =="
curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "  (curl not available)"
echo "== Done =="
