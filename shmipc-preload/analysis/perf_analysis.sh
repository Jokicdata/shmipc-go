#!/bin/bash
#
# shmipc-preload 性能分析脚本
# 
# 功能：自动运行性能测试并收集分析数据
# 
# 使用方法：
#   ./perf_analysis.sh <test_type> [msg_size]
#
# 参数：
#   test_type: latency | bandwidth | all
#   msg_size:  消息大小（字节），默认测试多个大小
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRELOAD_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$SCRIPT_DIR/logs"
DATE_STR=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    
    command -v perf >/dev/null 2>&1 || missing+=("perf")
    command -v qperf >/dev/null 2>&1 || missing+=("qperf")
    command -v sockperf >/dev/null 2>&1 || missing+=("sockperf")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖工具: ${missing[*]}"
        log_info "安装方法:"
        log_info "  perf:     yum install perf 或 apt install linux-tools-common"
        log_info "  qperf:    yum install qperf 或 apt install qperf"
        log_info "  sockperf: 编译安装 https://github.com/Mellanox/sockperf"
        exit 1
    fi
}

run_latency_test() {
    local msg_size=$1
    local use_shmipc=$2
    local log_file="$LOG_DIR/latency_${msg_size}_$([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")_${DATE_STR}.log"
    
    log_info "运行延迟测试: msg_size=$msg_size, shmipc=$use_shmipc"
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    else
        qperf &
    fi
    local server_pid=$!
    sleep 2
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t 10 tcp_lat 2>&1 | tee "$log_file"
    else
        qperf 127.0.0.1 -m $msg_size -t 10 tcp_lat 2>&1 | tee "$log_file"
    fi
    
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    log_info "结果保存到: $log_file"
}

run_bandwidth_test() {
    local msg_size=$1
    local use_shmipc=$2
    local log_file="$LOG_DIR/bandwidth_${msg_size}_$([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")_${DATE_STR}.log"
    
    log_info "运行带宽测试: msg_size=$msg_size, shmipc=$use_shmipc"
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    else
        qperf &
    fi
    local server_pid=$!
    sleep 2
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    else
        qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    fi
    
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    log_info "结果保存到: $log_file"
}

run_perf_analysis() {
    local pid=$1
    local output_file="$LOG_DIR/perf_${pid}_${DATE_STR}.data"
    
    log_info "运行 perf 分析: pid=$pid"
    
    perf record -g -o "$output_file" -p $pid -- sleep 5 2>/dev/null || true
    
    log_info "perf 数据保存到: $output_file"
    log_info "查看报告: perf report -i $output_file"
}

run_strace_analysis() {
    local cmd=$1
    local output_file="$LOG_DIR/strace_${DATE_STR}.log"
    
    log_info "运行 strace 分析: $cmd"
    
    strace -T -tt -f -o "$output_file" $cmd &
    local strace_pid=$!
    
    sleep 10
    kill $strace_pid 2>/dev/null || true
    
    log_info "strace 日志保存到: $output_file"
}

run_comparison_test() {
    local msg_sizes=(1024 8192 65536 262144 1048576)
    local summary_file="$LOG_DIR/comparison_${DATE_STR}.csv"
    
    echo "msg_size,socket_latency_us,shmipc_latency_us,latency_improvement,socket_bandwidth_GBps,shmipc_bandwidth_GBps,bandwidth_improvement" > "$summary_file"
    
    for msg_size in "${msg_sizes[@]}"; do
        log_info "测试消息大小: $msg_size bytes"
        
        local socket_lat_file="$LOG_DIR/latency_${msg_size}_socket_${DATE_STR}.log"
        local shmipc_lat_file="$LOG_DIR/latency_${msg_size}_shmipc_${DATE_STR}.log"
        local socket_bw_file="$LOG_DIR/bandwidth_${msg_size}_socket_${DATE_STR}.log"
        local shmipc_bw_file="$LOG_DIR/bandwidth_${msg_size}_shmipc_${DATE_STR}.log"
        
        run_latency_test $msg_size false
        run_latency_test $msg_size true
        run_bandwidth_test $msg_size false
        run_bandwidth_test $msg_size true
        
        local socket_lat=$(grep "tcp_lat" "$socket_lat_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        local shmipc_lat=$(grep "tcp_lat" "$shmipc_lat_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        local socket_bw=$(grep "tcp_bw" "$socket_bw_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        local shmipc_bw=$(grep "tcp_bw" "$shmipc_bw_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        
        local lat_imp="N/A"
        local bw_imp="N/A"
        
        if [[ "$socket_lat" != "N/A" && "$shmipc_lat" != "N/A" ]]; then
            lat_imp=$(echo "scale=2; ($socket_lat - $shmipc_lat) / $socket_lat * 100" | bc 2>/dev/null || echo "N/A")
        fi
        
        if [[ "$socket_bw" != "N/A" && "$shmipc_bw" != "N/A" ]]; then
            bw_imp=$(echo "scale=2; ($shmipc_bw - $socket_bw) / $socket_bw * 100" | bc 2>/dev/null || echo "N/A")
        fi
        
        echo "$msg_size,$socket_lat,$shmipc_lat,$lat_imp,$socket_bw,$shmipc_bw,$bw_imp" >> "$summary_file"
        
        sleep 5
    done
    
    log_info "对比结果保存到: $summary_file"
    cat "$summary_file"
}

print_usage() {
    echo "shmipc-preload 性能分析脚本"
    echo ""
    echo "使用方法:"
    echo "  $0 latency [msg_size]           # 延迟测试"
    echo "  $0 bandwidth [msg_size]         # 带宽测试"
    echo "  $0 comparison                   # 对比测试（推荐）"
    echo "  $0 perf <pid>                   # perf 分析"
    echo "  $0 strace <command>             # strace 分析"
    echo ""
    echo "示例:"
    echo "  $0 latency 65536"
    echo "  $0 bandwidth 1048576"
    echo "  $0 comparison"
    echo "  $0 perf 12345"
    echo "  $0 strace 'qperf 127.0.0.1 tcp_lat'"
}

main() {
    local test_type=${1:-"help"}
    
    case "$test_type" in
        latency)
            local msg_size=${2:-65536}
            check_dependencies
            run_latency_test $msg_size false
            run_latency_test $msg_size true
            ;;
        bandwidth)
            local msg_size=${2:-1048576}
            check_dependencies
            run_bandwidth_test $msg_size false
            run_bandwidth_test $msg_size true
            ;;
        comparison)
            check_dependencies
            run_comparison_test
            ;;
        perf)
            check_root
            local pid=$2
            if [[ -z "$pid" ]]; then
                log_error "请指定进程 PID"
                exit 1
            fi
            run_perf_analysis $pid
            ;;
        strace)
            local cmd=$2
            if [[ -z "$cmd" ]]; then
                log_error "请指定要追踪的命令"
                exit 1
            fi
            run_strace_analysis "$cmd"
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "未知测试类型: $test_type"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
