#!/bin/bash

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          shmipc-preload 一键性能测试                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

check_dependencies() {
    echo "检查依赖工具..."
    
    local missing=()
    
    command -v qperf >/dev/null 2>&1 || missing+=("qperf")
    command -v perf >/dev/null 2>&1 || missing+=("perf")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "缺少以下工具: ${missing[*]}"
        echo ""
        echo "安装命令:"
        echo "  Ubuntu/Debian: sudo apt install ${missing[*]}"
        echo "  CentOS/RHEL:   sudo yum install ${missing[*]}"
        return 1
    fi
    
    echo "✓ 所有依赖已安装"
    return 0
}

build_libraries() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "编译库文件..."
    echo "════════════════════════════════════════════════════════════"
    
    if [ -f Makefile.optimized ]; then
        make -f Makefile.optimized all
    elif [ -f Makefile ]; then
        make all
    else
        echo "错误: 找不到 Makefile"
        return 1
    fi
    
    if [ ! -f libshmipc.so ]; then
        echo "错误: 编译失败"
        return 1
    fi
    
    echo ""
    echo "✓ 编译成功"
    echo "  - libshmipc.so (原始版本)"
    [ -f libshmipc_optimized.so ] && echo "  - libshmipc_optimized.so (优化版本)"
    return 0
}

quick_benchmark() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "快速性能测试"
    echo "════════════════════════════════════════════════════════════"
    
    local SIZES=(512 65536 524288)
    local RESULTS_DIR=./quick_test_results
    mkdir -p $RESULTS_DIR
    
    for SIZE in "${SIZES[@]}"; do
        echo ""
        echo "测试消息大小: $SIZE bytes"
        echo "────────────────────────────────────────────────────────────"
        
        pkill -f "qperf" 2>/dev/null
        sleep 1
        
        echo "  [1/3] Socket (原始)..."
        qperf &
        sleep 2
        qperf 127.0.0.1 -m $SIZE -t 5 tcp_bw tcp_lat > $RESULTS_DIR/socket_$SIZE.log 2>&1
        pkill -f "qperf" 2>/dev/null
        sleep 1
        
        echo "  [2/3] shmipc (原始版本)..."
        LD_PRELOAD=./libshmipc.so qperf &
        sleep 2
        LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m $SIZE -t 5 tcp_bw tcp_lat > $RESULTS_DIR/shmipc_orig_$SIZE.log 2>&1
        pkill -f "qperf" 2>/dev/null
        sleep 1
        
        if [ -f libshmipc_optimized.so ]; then
            echo "  [3/3] shmipc (优化版本)..."
            LD_PRELOAD=./libshmipc_optimized.so qperf &
            sleep 2
            LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m $SIZE -t 5 tcp_bw tcp_lat > $RESULTS_DIR/shmipc_opt_$SIZE.log 2>&1
            pkill -f "qperf" 2>/dev/null
        fi
    done
    
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "测试结果汇总"
    echo "════════════════════════════════════════════════════════════"
    
    for SIZE in "${SIZES[@]}"; do
        echo ""
        echo "消息大小: $SIZE bytes"
        echo "┌──────────────┬──────────────┬──────────────┐"
        echo "│   版本       │  带宽(MB/s)  │  延迟(us)    │"
        echo "├──────────────┼──────────────┼──────────────┤"
        
        local bw lat
        
        bw=$(grep "tcp_bw" $RESULTS_DIR/socket_$SIZE.log 2>/dev/null | awk '{print $NF}')
        lat=$(grep "tcp_lat" $RESULTS_DIR/socket_$SIZE.log 2>/dev/null | awk '{print $NF}')
        printf "│ %-12s │ %10s   │ %10s   │\n" "Socket" "${bw:-N/A}" "${lat:-N/A}"
        
        bw=$(grep "tcp_bw" $RESULTS_DIR/shmipc_orig_$SIZE.log 2>/dev/null | awk '{print $NF}')
        lat=$(grep "tcp_lat" $RESULTS_DIR/shmipc_orig_$SIZE.log 2>/dev/null | awk '{print $NF}')
        printf "│ %-12s │ %10s   │ %10s   │\n" "shmipc-orig" "${bw:-N/A}" "${lat:-N/A}"
        
        if [ -f $RESULTS_DIR/shmipc_opt_$SIZE.log ]; then
            bw=$(grep "tcp_bw" $RESULTS_DIR/shmipc_opt_$SIZE.log 2>/dev/null | awk '{print $NF}')
            lat=$(grep "tcp_lat" $RESULTS_DIR/shmipc_opt_$SIZE.log 2>/dev/null | awk '{print $NF}')
            printf "│ %-12s │ %10s   │ %10s   │\n" "shmipc-opt" "${bw:-N/A}" "${lat:-N/A}"
        fi
        
        echo "└──────────────┴──────────────┴──────────────┘"
    done
}

show_next_steps() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "下一步"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "1. 详细性能分析:"
    echo "   cd performance_analysis && ./perf_shmipc.sh"
    echo ""
    echo "2. 综合基准测试:"
    echo "   cd performance_analysis && ./comprehensive_bench.sh"
    echo ""
    echo "3. 延迟对比测试:"
    echo "   cd performance_analysis && ./latency_comparison.sh"
    echo ""
    echo "4. 查看优化说明:"
    echo "   cat PERFORMANCE_OPTIMIZATION.md"
    echo ""
    echo "5. 使用优化版本:"
    echo "   LD_PRELOAD=./libshmipc_optimized.so <your-program>"
    echo ""
    echo "详细文档: performance_analysis/README.md"
}

main() {
    check_dependencies || exit 1
    build_libraries || exit 1
    quick_benchmark
    show_next_steps
}

main "$@"
