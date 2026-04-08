#!/bin/bash
#
# shmipc-preload ftrace 分析脚本
# 
# 功能：使用 ftrace 追踪内核函数调用和耗时
# 
# 使用方法：
#   sudo ./ftrace_analysis.sh <command>
#
# 示例：
#   sudo ./ftrace_analysis.sh "qperf 127.0.0.1 tcp_lat"
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs/ftrace"
DATE_STR=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

TRACING_DIR="/sys/kernel/debug/tracing"

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

setup_ftrace() {
    log_info "设置 ftrace..."
    
    echo 0 > "$TRACING_DIR/tracing_on"
    echo > "$TRACING_DIR/trace"
    
    echo function_graph > "$TRACING_DIR/current_tracer"
    echo 1 > "$TRACING_DIR/options/funcgraph-abstime"
    echo 1 > "$TRACING_DIR/options/funcgraph-cpu"
    echo 1 > "$TRACING_DIR/options/funcgraph-proc"
    echo 1 > "$TRACING_DIR/options/funcgraph-duration"
    echo 1 > "$TRACING_DIR/options/funcgraph-overhead"
    
    echo > "$TRACING_DIR/set_ftrace_filter"
    
    log_info "ftrace 设置完成"
}

trace_socket_functions() {
    log_info "追踪 socket 相关内核函数..."
    
    echo > "$TRACING_DIR/set_ftrace_filter"
    
    cat >> "$TRACING_DIR/set_ftrace_filter" << 'EOF'
SyS_socket
SyS_bind
SyS_listen
SyS_accept4
SyS_connect
SyS_sendto
SyS_recvfrom
SyS_write
SyS_read
SyS_close
sock_sendmsg
sock_recvmsg
tcp_sendmsg
tcp_recvmsg
unix_stream_sendmsg
unix_stream_recvmsg
copy_to_user
copy_from_user
EOF
    
    log_info "已设置追踪函数列表"
}

trace_memory_functions() {
    log_info "追踪内存相关内核函数..."
    
    echo > "$TRACING_DIR/set_ftrace_filter"
    
    cat >> "$TRACING_DIR/set_ftrace_filter" << 'EOF'
__memcpy
__memmove
copy_to_user
copy_from_user
copy_page
clear_page
EOF
    
    log_info "已设置内存函数追踪列表"
}

trace_ipc_functions() {
    log_info "追踪 IPC 相关内核函数..."
    
    echo > "$TRACING_DIR/set_ftrace_filter"
    
    cat >> "$TRACING_DIR/set_ftrace_filter" << 'EOF'
shmctl
shmat
shmdt
mmap
munmap
memfd_create
EOF
    
    log_info "已设置 IPC 函数追踪列表"
}

run_trace() {
    local cmd=$1
    local output_file="$LOG_DIR/trace_${DATE_STR}.log"
    
    log_info "开始追踪: $cmd"
    log_info "输出文件: $output_file"
    
    echo 1 > "$TRACING_DIR/tracing_on"
    
    $cmd &
    local cmd_pid=$!
    
    sleep 10
    
    echo 0 > "$TRACING_DIR/tracing_on"
    
    cat "$TRACING_DIR/trace" > "$output_file"
    
    wait $cmd_pid 2>/dev/null || true
    
    log_info "追踪完成"
}

analyze_trace() {
    local trace_file=$1
    local analysis_file="${trace_file%.log}_analysis.txt"
    
    log_info "分析追踪结果..."
    
    {
        echo "========================================"
        echo "  ftrace 分析报告"
        echo "========================================"
        echo ""
        
        echo "=== 函数调用统计 ==="
        grep -oP '(?<=\s)[a-zA-Z_][a-zA-Z0-9_]*(?=\s*\()' "$trace_file" 2>/dev/null | \
            sort | uniq -c | sort -rn | head -20
        
        echo ""
        echo "=== 耗时最长的函数调用 (Top 20) ==="
        grep -E '\s+[0-9]+\.[0-9]+ us' "$trace_file" 2>/dev/null | \
            sed 's/.*\s\([0-9]\+\.[0-9]\+\) us.*/\1 &/' | \
            sort -rn | head -20
        
        echo ""
        echo "=== 耗时超过 100us 的函数调用 ==="
        grep -E '\s+[0-9]+\.[0-9]+ us' "$trace_file" 2>/dev/null | \
            awk '{if($NF ~ /[0-9]+\.[0-9]+ us/) {gsub(/[^0-9.]/,"",$NF); if($NF > 100) print}}' | \
            head -50
        
        echo ""
        echo "=== copy_to_user/copy_from_user 调用统计 ==="
        grep -E 'copy_to_user|copy_from_user' "$trace_file" 2>/dev/null | \
            wc -l
        echo "总调用次数"
        
        echo ""
        echo "=== 内存操作耗时统计 ==="
        grep -E '__memcpy|__memmove|copy_to_user|copy_from_user' "$trace_file" 2>/dev/null | \
            grep -oE '[0-9]+\.[0-9]+ us' | \
            awk '{sum+=$1; count++} END {print "平均耗时: " sum/count " us, 总调用次数: " count}'
        
    } > "$analysis_file"
    
    log_info "分析报告保存到: $analysis_file"
    cat "$analysis_file"
}

cleanup() {
    log_info "清理 ftrace 设置..."
    
    echo 0 > "$TRACING_DIR/tracing_on"
    echo nop > "$TRACING_DIR/current_tracer"
    echo > "$TRACING_DIR/set_ftrace_filter"
    echo > "$TRACING_DIR/trace"
    
    log_info "清理完成"
}

print_usage() {
    echo "shmipc-preload ftrace 分析脚本"
    echo ""
    echo "使用方法:"
    echo "  sudo $0 socket <command>     # 追踪 socket 函数"
    echo "  sudo $0 memory <command>     # 追踪内存函数"
    echo "  sudo $0 ipc <command>        # 追踪 IPC 函数"
    echo "  sudo $0 all <command>        # 追踪所有函数"
    echo ""
    echo "示例:"
    echo "  sudo $0 socket 'qperf 127.0.0.1 tcp_lat'"
    echo "  sudo $0 memory 'qperf 127.0.0.1 tcp_bw'"
}

main() {
    local trace_type=${1:-"help"}
    local cmd=$2
    
    case "$trace_type" in
        socket)
            check_root
            setup_ftrace
            trace_socket_functions
            run_trace "$cmd"
            analyze_trace "$LOG_DIR/trace_${DATE_STR}.log"
            cleanup
            ;;
        memory)
            check_root
            setup_ftrace
            trace_memory_functions
            run_trace "$cmd"
            analyze_trace "$LOG_DIR/trace_${DATE_STR}.log"
            cleanup
            ;;
        ipc)
            check_root
            setup_ftrace
            trace_ipc_functions
            run_trace "$cmd"
            analyze_trace "$LOG_DIR/trace_${DATE_STR}.log"
            cleanup
            ;;
        all)
            check_root
            setup_ftrace
            trace_socket_functions
            run_trace "$cmd"
            analyze_trace "$LOG_DIR/trace_${DATE_STR}.log"
            cleanup
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "未知追踪类型: $trace_type"
            print_usage
            exit 1
            ;;
    esac
}

trap cleanup EXIT

main "$@"
