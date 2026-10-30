# 全隧道 + metric 10/20：三重自动回退架构

> 生产验证：Buero (123.1)，2026-10-29 故障注入实测全过。

## 架构

```
wg0 allowed_ips '0.0.0.0/0' + '::/0'  route_allowed_ips '1'  metric '10'   # 默认全接管（IPv4+IPv6）
wan                                   metric '20'                          # 物理直连兜底
pbr（ignored_interface=wg0）          国内 IPv4 → wan                       # 剥离规则
```

- pbr 只管"把国内 IPv4 从隧道剥离回 wan"这一件事，其余全部交给 wg0 默认路由。
- 对端网段互访路由由 wg0 的 `route_allowed_ips` 自动管理（peer allowed_ips 覆盖即自动建路由），**不要**手写 wg0_table 静态路由。

## 三重回退链

```
pbr 停止 ──► 国内 IPv4 失去剥离规则 ──► 走 wg0 隧道（仍能上网，国内流量绕代理）
wg0 停止 ──► 默认路由失效 ──► 走 wan 物理直连（国内流量完全正常）
wan 也断 ──► 无路可走 ──► 国内流量才真正断流
```

| 故障层级 | 剩余路径 | 国内流量状态 |
|---|---|---|
| 仅 pbr 停 | wg0 | 可上网，绕代理 |
| pbr + wg0 停 | wan | 完全正常 |
| 三层全断 | 无 | 断流 |

## 故障注入实测法（防 SSH 断连的教训）

**不要**在控制端直接 `ifdown wg0` / `stop pbr`（SSH 会话会断、且无法自动复原）。正确做法：把故障注入脚本**传到设备本地**，用 setsid 后台跑，定时自动恢复：

```sh
# 设备端（OpenWrt 无 nohup，用 setsid）
cat > /root/fault-inject.sh <<'EOF'
#!/bin/sh
# 30 秒后停 pbr，60 秒后重启，全程自动恢复
/etc/init.d/pbr stop
sleep 30
/etc/init.d/pbr start
EOF
chmod +x /root/fault-inject.sh
setsid /root/fault-inject.sh </dev/null >/dev/null 2>&1 &
```

控制端同时验证（每 10 秒采样）：

```sh
while true; do date +%T; ip route get 114.114.114.114 | head -1; sleep 10; done
```

实测记录（Buero，2026-10-29）：
- 基线：双默认路由 `wg0 metric 10` + `wan metric 20` ✓
- `pbr stop` → 114.114.114.114 由 `pbr_wan→wan` 变 `dev wg0`，30000 规则消失 ✓
- `pbr start` → 自动重建 ✓
- `ifdown wg0` → 默认路由只剩 wan metric 20，出口 121.231.144.212（本地电信 IP）✓
- `ifup wg0` → 复原 ✓

> 注：故障注入期间 LAN 用户有几秒抖动（实测全程 30 秒内自动恢复）。生产设备操作前告知用户。
