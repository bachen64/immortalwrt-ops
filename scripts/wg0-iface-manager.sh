#!/bin/sh
# ============================================================================
# wg0 接口管理器 v2.7 (POSIX兼容版)
# 每5分钟检测wg0对端DDNS的变化，动态管理WG接口
# 当检测到wg0连接到本地地址，尝试修复
# v2.5: cron巡检静默运行，仅在事件发生时记录日志（IP变化/重启/警告/错误）；
#        使用 --check 可查看完整诊断输出。
# v2.6: 修复DNS解析——真实查询失败时曾把dnsmasq自身的127.0.0.1:53 server行
#        误当答案，导致误判"IP变化"并反复重启wg0（JM1 2026-11-03事故）。
#        现在只接受"Name:"行之后的地址；本地/可疑答案按解析失败处理并跳过本轮。
# v2.7: 对端IP未变但wg0自身DISCONNECTED时（如重启后endpoint卡在0.0.0.0），
#        强制重启wg0以恢复连接。
# ============================================================================

# ============================================================================
# 配置参数区
# ============================================================================
DDNS_DOMAIN="kcn01.dynv6.net"
WG_INTERFACE="wg0"
IP_FILE="/var/run/office_last_ip.txt"
LOG_TAG="wg0-iface-manager"
LOCK_FILE="/var/run/wg_ddns.lock"
LOG_FILE="/tmp/wg_ddns.log"

# 连接检测参数
CONNECT_CHECK_TIMEOUT=5
RECONNECT_WAIT_TIME=10
DNS_RESOLVE_TIMEOUT=3

# 重试机制参数
MAX_RETRY_ATTEMPTS=2
RETRY_BASE_DELAY=5
RETRY_MAX_DELAY=30

# wg0 特定参数
WG_RESTART_DELAY=3
NETWORK_STABILIZE_DELAY=5

# 日志级别控制
LOG_LEVEL="INFO"
DEBUG_MODE=0
# SILENT=1: 正常巡检噪声被抑制（cron MONITOR 运行时）；
#           事件日志（IP变化/重启/警告/错误）始终记录。
# SILENT=0: 输出完整诊断信息（手动 --check 运行时）。
SILENT=0

# ============================================================================
# 日志系统 - POSIX兼容版
# ============================================================================

# 日志级别数值映射
get_log_level_num() {
    case "$LOG_LEVEL" in
        DEBUG|debug) echo 0 ;;
        INFO|info) echo 1 ;;
        WARNING|warning) echo 2 ;;
        ERROR|error) echo 3 ;;
        *) echo 1 ;;
    esac
}

# 内部日志函数
log_internal() {
    level="$1"
    message="$2"
    log_message="$level - $message"
    
    logger -t "$LOG_TAG" "$log_message"
    echo "$log_message" >> "$LOG_FILE"
    
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "$log_message" >&2
    fi
}

log_debug() {
    if [ $(get_log_level_num) -le 0 ]; then
        log_internal "DEBUG" "$1"
    fi
}

log_info() {
    if [ $(get_log_level_num) -le 1 ]; then
        log_internal "INFO" "$1"
    fi
}

log_warning() {
    if [ $(get_log_level_num) -le 2 ]; then
        log_internal "WARNING" "$1"
    fi
}

log_error() {
    if [ $(get_log_level_num) -le 3 ]; then
        log_internal "ERROR" "$1"
    fi
}

log_status() {
    status="$1"
    message="$2"
    
    case "$status" in
        SUCCESS) emoji="✅" ;;
        WARNING) emoji="⚠️" ;;
        ERROR)   emoji="❌" ;;
        INFO)    emoji="ℹ️" ;;
        *)       emoji="🔸" ;;
    esac
    
    log_info "$emoji $message"
}

# 巡检噪声日志：仅在 SILENT=0（手动诊断）时输出。
# 事件日志（IP变化/重启/警告/错误）禁止使用此函数。
log_verbose() {
    if [ "$SILENT" -eq 0 ]; then
        log_info "$1"
    fi
}

# ============================================================================
# 初始化检查
# ============================================================================
check_requirements() {
    required_commands="wg nslookup logger flock ip ifdown ifup"
    
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "缺少必需的命令: $cmd"
            return 1
        fi
    done
    
    return 0
}

# ============================================================================
# 进程锁管理 - POSIX兼容版
# ============================================================================
setup_lock() {
    # 检查flock是否可用
    if ! command -v flock >/dev/null 2>&1; then
        log_warning "flock命令不可用，跳过锁检查"
        return 0
    fi
    
    # 尝试获取锁，非阻塞模式
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_warning "检测到脚本已在运行，退出本次执行"
        exit 0
    fi
}

cleanup() {
    # 释放锁
    if [ -n "$LOCK_FILE" ] && [ -e "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE" 2>/dev/null
    fi
    log_debug "清理锁文件和资源"
}
trap cleanup EXIT INT TERM

# ============================================================================
# 网络诊断功能 - POSIX兼容版
# ============================================================================
check_dns_resolution() {
    domain="$1"
    ip_type="$2"

    log_debug "检查DNS解析: domain=$domain, type=$ip_type"

    # 只取 "Name:" 行下一行的地址。
    # busybox nslookup 在 "Name:" 之前还有一段 server 输出 "Address 1: 127.0.0.1:53"；
    # 以前 grep|tail 会在真实查询失败时把它误当答案（2026-11-03 JM1 误判"IP变化"事故）。
    # 列位置不可靠（"Address:" 与 "Address 1:"），因此直接剥掉行首标签。
    result=$(nslookup -type="$ip_type" "$domain" 2>/dev/null \
        | sed -n '/^Name:/{n;s/^[^:]*:[[:space:]]*//;p}')

    # 本地/可疑答案直接判为失败（纵深防御）
    if [ -n "$result" ] && is_local_address "$result"; then
        log_warning "DNS答案疑似本地地址 ($domain -> $result)，按解析失败处理"
        echo ""
        return 1
    fi

    if [ -n "$result" ]; then
        log_debug "DNS解析成功: $domain -> $result"
        echo "$result"
        return 0
    else
        log_warning "DNS解析失败: $domain (类型: $ip_type)"
        return 1
    fi
}

resolve_domain_ip() {
    domain="$1"
    domain_ip=""
    
    domain_ip=$(check_dns_resolution "$domain" "AAAA")
    
    if [ -z "$domain_ip" ]; then
        log_debug "IPv6解析失败，尝试IPv4解析"
        domain_ip=$(check_dns_resolution "$domain" "A")
    fi
    
    if [ -n "$domain_ip" ]; then
        echo "$domain_ip"
        return 0
    else
        log_error "无法解析域名: $domain"
        return 1
    fi
}

is_local_address() {
    ip="$1"
    
    # 检查IPv4本地地址
    case "$ip" in
        127.*|localhost) return 0 ;;
        10.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*|192.168.*) return 0 ;;
    esac
    
    # 检查IPv6本地地址
    case "$ip" in
        ::1|0:0:0:0:0:0:0:1|fe80:*) return 0 ;;
    esac
    
    return 1
}

# wg0 状态检查函数 - POSIX兼容版
get_current_peer_ip() {
    # 方法1: 尝试解析 wg show 的完整输出
    wg_output=$(wg show "$WG_INTERFACE" 2>/dev/null)
    
    if [ -n "$wg_output" ]; then
        # 查找 endpoint 行
        endpoint_line=$(echo "$wg_output" | grep "^[[:space:]]*endpoint:")
        
        if [ -n "$endpoint_line" ]; then
            # 清理空格和 endpoint: 前缀
            endpoint_line=$(echo "$endpoint_line" | sed 's/^[[:space:]]*endpoint:[[:space:]]*//')
            
            # 提取 IPv6 地址 (格式: [ip]:port)
            if echo "$endpoint_line" | grep -q "\[.*\]:[0-9][0-9]*"; then
                echo "$endpoint_line" | sed 's/\[\(.*\)\]:[0-9][0-9]*/\1/'
                return 0
            # 提取 IPv4 地址 (格式: ip:port)
            elif echo "$endpoint_line" | grep -q "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*:[0-9][0-9]*"; then
                echo "$endpoint_line" | sed 's/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\):[0-9][0-9]*/\1/'
                return 0
            fi
        fi
    fi
    
    # 方法2: 尝试解析 wg show endpoints 的简洁输出
    endpoints_output=$(wg show "$WG_INTERFACE" endpoints 2>/dev/null)
    
    if [ -n "$endpoints_output" ]; then
        # 匹配 IPv6 地址 (格式: [ip]:port)
        if echo "$endpoints_output" | grep -q "\[.*\]:[0-9][0-9]*"; then
            echo "$endpoints_output" | sed 's/.*\[\(.*\)\]:[0-9][0-9]*.*/\1/'
            return 0
        # 匹配 IPv4 地址 (格式: ip:port)
        elif echo "$endpoints_output" | grep -q "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*:[0-9][0-9]*"; then
            echo "$endpoints_output" | sed 's/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\):[0-9][0-9]*.*/\1/'
            return 0
        fi
    fi
    
    # 如果都没找到，返回空
    echo ""
    return 1
}

# wg0 连接状态检查
check_wg_connection() {
    current_ip=$(get_current_peer_ip)
    
    if [ -z "$current_ip" ]; then
        log_debug "$WG_INTERFACE未连接或未获取到对端IP"
        echo "DISCONNECTED"
        return 2
    elif is_local_address "$current_ip"; then
        log_warning "检测到$WG_INTERFACE连接到本地地址: $current_ip"
        echo "LOCAL_CONNECTION"
        return 1
    else
        log_debug "$WG_INTERFACE正常连接到: $current_ip"
        echo "CONNECTED"
        return 0
    fi
}

# 检查 wg0 接口是否存在且有 IP 地址
check_wg_interface_health() {
    # 1. 检查接口是否存在
    if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        log_debug "$WG_INTERFACE接口不存在"
        echo "INTERFACE_MISSING"
        return 1
    fi
    
    # 2. 检查接口是否有 IP 地址
    if ! ip addr show "$WG_INTERFACE" 2>/dev/null | grep -q "inet "; then
        log_debug "$WG_INTERFACE接口没有分配IP地址"
        echo "NO_IP_ADDRESS"
        return 2
    fi
    
    # 3. 检查 wg0 隧道状态
    if ! wg show "$WG_INTERFACE" >/dev/null 2>&1; then
        log_debug "$WG_INTERFACE接口配置可能有问题"
        echo "WG_CONFIG_ERROR"
        return 3
    fi
    
    echo "HEALTHY"
    return 0
}

# ============================================================================
# wg0 管理功能
# ============================================================================
restart_wg0() {
    attempt=1
    max_attempts=2
    result=1
    
    while [ $attempt -le $max_attempts ] && [ $result -ne 0 ]; do
        log_status "INFO" "重启$WG_INTERFACE接口 (尝试 $attempt/$max_attempts)"
        
        if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
            log_error "$WG_INTERFACE接口不存在"
            return 1
        fi
        
        log_debug "关闭 $WG_INTERFACE 接口"
        if ifdown "$WG_INTERFACE" 2>/dev/null; then
            log_debug "$WG_INTERFACE接口已关闭"
            sleep "$WG_RESTART_DELAY"
        else
            log_warning "ifdown失败，尝试替代方法"
            ip link set dev "$WG_INTERFACE" down
            sleep 2
        fi
        
        log_debug "等待网络稳定..."
        sleep "$NETWORK_STABILIZE_DELAY"
        
        log_debug "启动 $WG_INTERFACE 接口"
        if ifup "$WG_INTERFACE" 2>/dev/null; then
            log_debug "$WG_INTERFACE接口已启动"
            
            log_debug "等待$WG_INTERFACE连接建立..."
            sleep "$RECONNECT_WAIT_TIME"
            
            connection_state=$(check_wg_connection)
            if [ "$connection_state" = "CONNECTED" ]; then
                new_ip=$(get_current_peer_ip)
                log_status "SUCCESS" "$WG_INTERFACE重启成功，新对端IP: $new_ip"
                result=0
            else
                log_warning "$WG_INTERFACE重启后连接状态: $connection_state"
                result=1
            fi
        else
            log_error "ifup失败，尝试替代方法"
            ip link set dev "$WG_INTERFACE" up
            sleep 3
            
            interface_health=$(check_wg_interface_health)
            if [ "$interface_health" = "HEALTHY" ] || [ "$interface_health" = "NO_IP_ADDRESS" ]; then
                sleep "$RECONNECT_WAIT_TIME"
                connection_state=$(check_wg_connection)
                if [ "$connection_state" = "CONNECTED" ]; then
                    new_ip=$(get_current_peer_ip)
                    log_status "SUCCESS" "$WG_INTERFACE通过替代方法启动成功"
                    result=0
                else
                    log_warning "$WG_INTERFACE接口已启动但连接状态: $connection_state"
                    result=1
                fi
            else
                log_error "无法启动$WG_INTERFACE接口（健康状态: $interface_health）"
                result=1
            fi
        fi
        
        if [ $result -ne 0 ]; then
            delay=$((RETRY_BASE_DELAY * attempt))
            if [ $delay -gt $RETRY_MAX_DELAY ]; then
                delay=$RETRY_MAX_DELAY
            fi
            log_debug "$WG_INTERFACE重启失败，等待 ${delay}秒后重试"
            sleep $delay
        fi
        
        attempt=$((attempt + 1))
    done
    
    return $result
}

fix_local_connection() {
    log_status "WARNING" "检测到$WG_INTERFACE连接到本地地址，尝试修复"
    
    current_ip=$(get_current_peer_ip)
    log_debug "当前错误状态: 连接到 $current_ip"
    
    if restart_wg0; then
        log_status "SUCCESS" "$WG_INTERFACE本地连接问题修复成功"
        return 0
    else
        log_error "$WG_INTERFACE本地连接问题修复失败"
        return 1
    fi
}

# ============================================================================
# DDNS监控功能
# ============================================================================
read_last_ip() {
    if [ -f "$IP_FILE" ]; then
        cat "$IP_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

save_current_ip() {
    ip="$1"
    echo "$ip" > "$IP_FILE"
    log_debug "已保存IP记录: $ip -> $IP_FILE"
}

handle_ip_change() {
    old_ip="$1"
    new_ip="$2"
    
    log_status "INFO" "检测到$WG_INTERFACE对端IP变化: $old_ip -> $new_ip"
    save_current_ip "$new_ip"
    
    if restart_wg0; then
        log_status "SUCCESS" "$WG_INTERFACE对端已更新到新IP: $new_ip"
        return 0
    else
        log_error "$WG_INTERFACE更新对端IP失败"
        return 1
    fi
}

monitor_ddns() {
    log_verbose "开始$WG_INTERFACE对端DDNS监控检查"
    
    domain_ip=$(resolve_domain_ip "$DDNS_DOMAIN")
    if [ -z "$domain_ip" ]; then
        log_error "$WG_INTERFACE对端DDNS解析失败，跳过本次检查"
        return 1
    fi

    # 纵深防御：本地/可疑对端IP一律不动作
    if is_local_address "$domain_ip"; then
        log_warning "解析到的对端DDNS疑似本地地址 ($domain_ip)，跳过本次检查"
        return 1
    fi
    
    current_ip=$(get_current_peer_ip)
    last_ip=$(read_last_ip)
    
    # 处理空值显示
    if [ -z "$current_ip" ]; then
        current_display="(无)"
    else
        current_display="$current_ip"
    fi
    
    if [ -z "$last_ip" ]; then
        last_display="(无)"
    else
        last_display="$last_ip"
    fi
    
    log_verbose "DDNS检查: 当前解析IP=$domain_ip, 当前连接IP=$current_display, 上次记录IP=$last_display"
    
    connection_state=$(check_wg_connection)
    if [ "$connection_state" = "LOCAL_CONNECTION" ]; then
        fix_local_connection
        current_ip=$(get_current_peer_ip)
    fi
    
    if [ -z "$last_ip" ]; then
        log_status "INFO" "首次运行，记录$WG_INTERFACE对端初始IP: $domain_ip"
        save_current_ip "$domain_ip"
    elif [ "$domain_ip" != "$last_ip" ]; then
        handle_ip_change "$last_ip" "$domain_ip"
    else
        # 对端IP未变：仅在wg0自身掉线时才动作。
        # 覆盖重启后endpoint卡在0.0.0.0/空地址、DNS已恢复但wg0自己没起来的场景。
        if [ "$connection_state" = "DISCONNECTED" ]; then
            log_warning "对端IP未变但$WG_INTERFACE处于DISCONNECTED，强制重启$WG_INTERFACE"
            if restart_wg0; then
                current_ip=$(get_current_peer_ip)
                log_status "SUCCESS" "$WG_INTERFACE已通过强制重启恢复（IP未变）"
            else
                log_error "强制重启未能恢复$WG_INTERFACE"
            fi
        else
            log_debug "$WG_INTERFACE对端IP未变化，无需操作"
        fi
    fi
    
    return 0
}

# ============================================================================
# 优化的健康检查功能
# ============================================================================
perform_health_check() {
    log_verbose "执行$WG_INTERFACE健康检查"
    
    # 1. 检查$WG_INTERFACE对端连接状态
    connection_state=$(check_wg_connection)
    
    # 2. 检查$WG_INTERFACE接口基本健康状态
    interface_health=$(check_wg_interface_health)
    
    # 3. 检查 DNS 解析
    dns_status="FAIL"
    if resolve_domain_ip "$DDNS_DOMAIN" >/dev/null; then
        dns_status="OK"
    fi
    
    # 4. 获取详细的 wg0 状态信息
    endpoint_info=""
    handshake_info=""
    transfer_info=""
    
    wg_output=$(wg show "$WG_INTERFACE" 2>/dev/null)
    
    if [ -n "$wg_output" ]; then
        # 提取端点信息
        endpoint_info=$(echo "$wg_output" | grep "^[[:space:]]*endpoint:" | head -1 | sed 's/^[[:space:]]*endpoint:[[:space:]]*//')
        
        # 提取最后握手时间
        handshake_info=$(echo "$wg_output" | grep "^[[:space:]]*latest handshake:" | head -1 | sed 's/^[[:space:]]*latest handshake:[[:space:]]*//')
        
        # 提取传输统计
        transfer_info=$(echo "$wg_output" | grep "^[[:space:]]*transfer:" | head -1 | sed 's/^[[:space:]]*transfer:[[:space:]]*//')
    fi
    
    # 输出优化的健康检查报告（仅详细模式；cron巡检时抑制）
    log_verbose "健康检查报告:"
    log_verbose "  - $WG_INTERFACE对端连接: $connection_state"
    log_verbose "  - $WG_INTERFACE接口健康状态: $interface_health"
    log_verbose "  - $WG_INTERFACE对端DNS解析: $dns_status"

    if [ -n "$endpoint_info" ]; then
        log_verbose "  - 端点: $endpoint_info"
    fi

    if [ -n "$handshake_info" ]; then
        log_verbose "  - 最后握手: $handshake_info"
    fi

    if [ -n "$transfer_info" ]; then
        log_verbose "  - 传输统计: $transfer_info"
    fi
    
    # 根据连接状态决定健康检查结果
    case "$connection_state" in
        CONNECTED)
            # 即使连接到对端，也要检查接口基本健康
            case "$interface_health" in
                HEALTHY)
                    log_verbose "健康检查通过: $WG_INTERFACE完全正常"
                    return 0
                    ;;
                NO_IP_ADDRESS)
                    log_status "WARNING" "健康检查警告: $WG_INTERFACE已连接但对端IP正常，接口可能缺少IP地址"
                    return 1
                    ;;
                *)
                    log_status "WARNING" "健康检查警告: $WG_INTERFACE已连接但对端IP正常，接口状态: $interface_health"
                    return 1
                    ;;
            esac
            ;;
        LOCAL_CONNECTION)
            log_status "WARNING" "健康检查警告: $WG_INTERFACE连接到本地地址"
            return 2
            ;;
        DISCONNECTED)
            log_status "ERROR" "健康检查失败: $WG_INTERFACE未连接"
            return 3
            ;;
        *)
            log_status "ERROR" "健康检查失败: 未知状态"
            return 4
            ;;
    esac
}

# ============================================================================
# 命令行接口
# ============================================================================
show_usage() {
    cat << EOF
$WG_INTERFACE 接口管理器

用法: $0 [选项]

选项:
  --check         只执行健康检查，不进行修复操作
  --debug         启用调试模式
  --force         强制运行，即使检测到其他实例
  --help          显示此帮助信息
  --version       显示版本信息

示例:
  $0              正常执行DDNS监控和修复
  $0 --check      只检查状态，不执行任何修复
  $0 --debug      启用详细日志输出

EOF
}

show_version() {
    echo "wg0 接口管理器 v2.7 (POSIX兼容版)"
}

# ============================================================================
# 主程序
# ============================================================================
main() {
    mode="MONITOR"
    force_run=0
    
    # 设置锁
    setup_lock
    
    while [ $# -gt 0 ]; do
        case $1 in
            --check)
                mode="CHECK"
                shift
                ;;
            --debug)
                DEBUG_MODE=1
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --force)
                force_run=1
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # cron (MONITOR) 运行默认静默，除非显式指定 --debug
    if [ "$mode" = "MONITOR" ] && [ "$DEBUG_MODE" -eq 0 ]; then
        SILENT=1
    fi

    log_verbose "脚本启动，模式: $mode"
    log_debug "运行参数: LOG_LEVEL=$LOG_LEVEL, DEBUG_MODE=$DEBUG_MODE"
    
    if ! check_requirements; then
        log_error "系统要求检查失败"
        exit 1
    fi
    
    case "$mode" in
        CHECK)
            perform_health_check
            health_status=$?
            exit $health_status
            ;;
        MONITOR)
            if monitor_ddns; then
                log_verbose "DDNS监控完成"
                # 静默执行健康检查，只记录错误
                if ! perform_health_check >/dev/null 2>&1; then
                    log_warning "健康检查未通过，但DDNS监控已完成"
                fi
                exit 0
            else
                log_error "DDNS监控过程中出现错误"
                exit 1
            fi
            ;;
    esac
}

main "$@"
