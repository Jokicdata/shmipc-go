#!/bin/bash
#
# shmipc-preload 带宽分析脚本
# 
# 功能：分析带宽瓶颈和内存带宽使用情况
# 
# 使用方法：
#   ./bandwidth_analysis.sh [msg_size]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRELOAD_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$SCRIPT_DIR/logs/bandwidth"
DATE_STR=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_section() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

check_dependencies() {
    local missing=()
    
    command -v perf >/dev/null 2>&1 || missing+=("perf")
    command -v qperf >/dev/null 2>&1 || missing+=("qperf")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖工具: ${missing[*]}"
        exit 1
    fi
}

get_memory_bandwidth() {
    log_section "内存带宽分析"
    
    log_info "测试内存带宽..."
    
    if command -v mbw >/dev/null 2>&1; then
        mbw 256M 2>&1 | tee "$LOG_DIR/mem_bandwidth_${DATE_STR}.log"
    else
        log_warn "mbw 未安装，跳过内存带宽测试"
        log_info "安装方法: apt install mbw 或 yum install mbw"
    fi
}

get_cache_info() {
    log_section "CPU 缓存信息"
    
    log_info "获取 CPU 缓存信息..."
    
    {
        echo "=== L1 数据缓存 ==="
        getconf LEVEL1_DCACHE_SIZE
        getconf LEVEL1_DCACHE_LINESIZE
        getconf LEVEL1_DCACHE_ASSOC
        
        echo ""
        echo "=== L2 缓存 ==="
        getconf LEVEL2_CACHE_SIZE
        getconf LEVEL2_CACHE_LINESIZE
        getconf LEVEL2_CACHE_ASSOC
        
        echo ""
        echo "=== L3 缓存 ==="
        getconf LEVEL3_CACHE_SIZE
        getconf LEVEL3_CACHE_LINESIZE
        getconf LEVEL3_CACHE_ASSOC
        
    } | tee "$LOG_DIR/cache_info_${DATE_STR}.log"
}

analyze_cache_performance() {
    local pid=$1
    local duration=${2:-10}
    
    log_section "缓存性能分析"
    
    log_info "分析进程 $pid 的缓存性能..."
    
    perf stat -e cycles,instructions,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses \
        -p $pid -o "$LOG_DIR/cache_perf_${DATE_STR}.log" -- sleep $duration
    
    cat "$LOG_DIR/cache_perf_${DATE_STR}.log"
}

run_bandwidth_test() {
    local msg_size=$1
    local use_shmipc=$2
    
    log_section "带宽测试 (msg_size=$msg_size, shmipc=$use_shmipc)"
    
    local log_file="$LOG_DIR/bandwidth_${msg_size}_$([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")_${DATE_STR}.log"
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    else
        qperf &
    fi
    local server_pid=$!
    sleep 2
    
    perf stat -e cycles,instructions,cache-references,cache-misses \
        -p $server_pid -o "${log_file}.perf" &
    local perf_pid=$!
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    else
        qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    fi
    
    kill $perf_pid 2>/dev/null || true
    wait $perf_pid 2>/dev/null || true
    
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    log_info "结果保存到: $log_file"
    log_info "性能数据: ${log_file}.perf"
}

analyze_memory_bandwidth_usage() {
    local msg_size=$1
    local duration=${2:-10}
    
    log_section "内存带宽使用分析"
    
    log_info "启动测试程序..."
    
    LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    local server_pid=$!
    sleep 2
    
    LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t $duration tcp_bw &
    local client_pid=$!
    
    log_info "监控内存带宽使用..."
    
    {
        echo "时间,rx_bytes,tx_bytes,rx_packets,tx_packets"
        
        local start_time=$(date +%s)
        local prev_rx=0
        local prev_tx=0
        
        while true; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            if [[ $elapsed -ge $duration ]]; then
                break
            fi
            
            read rx_bytes tx_bytes rx_packets tx_packets <<< $(cat /proc/net/dev | grep "lo:" | awk '{print $2, $10, $3, $11}')
            
            if [[ $prev_rx -gt 0 ]]; then
                local rx_delta=$((rx_bytes - prev_rx))
                local tx_delta=$((tx_bytes - prev_tx))
                local rx_rate=$((rx_delta / 1024 / 1024))
                local tx_rate=$((tx_delta / 1024 / 1024))
                
                echo "$(date +%H:%M:%S),$rx_rate,$tx_rate,$rx_packets,$tx_packets"
            fi
            
            prev_rx=$rx_bytes
            prev_tx=$tx_bytes
            
            sleep 1
        done
        
    } | tee "$LOG_DIR/memory_bandwidth_${DATE_STR}.csv"
    
    kill $client_pid 2>/dev/null || true
    kill $server_pid 2>/dev/null || true
    wait $client_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
}

generate_bandwidth_report() {
    log_section "生成带宽分析报告"
    
    local report_file="$LOG_DIR/bandwidth_report_${DATE_STR}.txt"
    
    {
        echo "========================================"
        echo "  shmipc-preload 带宽分析报告"
        echo "========================================"
        echo ""
        echo "生成时间: $(date)"
        echo ""
        
        echo "=== 系统信息 ==="
        echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2)"
        echo "内存: $(free -h | grep Mem | awk '{print $2}')"
        echo "内核: $(uname -r)"
        echo ""
        
        echo "=== 缓存信息 ==="
        echo "L1 数据缓存: $(getconf LEVEL1_DCACHE_SIZE | numfmt --to=iec)"
        echo "L2 缓存: $(getconf LEVEL2_CACHE_SIZE | numfmt --to=iec)"
        echo "L3 缓存: $(getconf LEVEL3_CACHE_SIZE | numfmt --to=iec)"
        echo ""
        
        echo "=== 带宽测试结果 ==="
        
        for log in "$LOG_DIR"/bandwidth_*_${DATE_STR}.log; do
            if [[ -f "$log" ]]; then
                local basename=$(basename "$log")
                echo ""
                echo "--- $basename ---"
                grep "tcp_bw" "$log" || echo "无带宽数据"
            fi
        done
        
        echo ""
        echo "=== 分析结论 ==="
        echo "1. 带宽瓶颈分析："
        echo "   - 如果带宽接近内存带宽上限，说明已达到硬件瓶颈"
        echo "   - 如果带宽远低于内存带宽，说明存在软件瓶颈"
        echo ""
        echo "2. 缓存性能分析："
        echo "   - 查看 cache_perf_*.log 文件中的缓存未命中率"
        echo "   - 高缓存未命中率可能表示内存访问模式不佳"
        echo ""
        echo "3. 优化建议："
        echo "   - 如果内存拷贝是瓶颈，考虑优化 CGO 数据传递"
        echo "   - 如果缓存未命中率高，考虑优化数据结构布局"
        
    } > "$report_file"
    
    log_info "报告保存到: $report_file"
    cat "$report_file"
}

print_usage() {
    echo "shmipc-preload 带宽分析脚本"
    echo ""
    echo "使用方法:"
    echo "  $0                      # 运行完整分析"
    echo "  $0 test <msg_size>      # 测试特定消息大小的带宽"
    echo "  $0 memory               # 仅分析内存带宽"
    echo "  $0 cache                # 仅分析缓存性能"
    echo "  $0 report               # 生成分析报告"
    echo ""
    echo "示例:"
    echo "  $0 test 1048576"
    echo "  $0 memory"
    echo "  $0 cache"
}

main() {
    local action=${1:-"all"}
    local msg_size=${2:-1048576}
    
    case "$action" in
        all)
            check_dependencies
            get_cache_info
            get_memory_bandwidth
            run_bandwidth_test 65536 false
            run_bandwidth_test 65536 true
            run_bandwidth_test 1048576 false
            run_bandwidth_test 1048576 true
            analyze_memory_bandwidth_usage 1048576 10
            generate_bandwidth_report
            ;;
        test)
            check_dependencies
            run_bandwidth_test $msg_size false
            run_bandwidth_test $msg_size true
            ;;
        memory)
            get_memory_bandwidth
            ;;
        cache)
            get_cache_info
            ;;
        report)
            generate_bandwidth_report
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "未知操作: $action"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
