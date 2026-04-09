#!/bin/bash
# run_perf_analysis.sh - 一键运行 perf + 火焰图分析
#
# 使用方式:
#   ./run_perf_analysis.sh [qperf_duration]
#
# 示例:
#   ./run_perf_analysis.sh 60    # 运行 60 秒 perf 记录
#
# 前提条件:
#   1. 需要 root 权限
#   2. FlameGraph 已下载到 ~/FlameGraph 或当前目录
#   3. shmipc 已编译 (libshmipc.so)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHMIPC_DIR="/path/to/shmipc-preload"  # 修改为你的实际路径
FLAMEGRAPH_DIR=""
DURATION=${1:-60}

echo "=========================================="
echo "shmipc perf + FlameGraph Analysis"
echo "=========================================="
echo "Duration: ${DURATION}s"
echo ""

setup_flamegraph() {
    echo "[Setup] Finding FlameGraph..."

    if [ -d "$SCRIPT_DIR/FlameGraph" ]; then
        FLAMEGRAPH_DIR="$SCRIPT_DIR/FlameGraph"
    elif [ -d ~/FlameGraph ]; then
        FLAMEGRAPH_DIR="$HOME/FlameGraph"
    elif [ -d "/tmp/FlameGraph" ]; then
        FLAMEGRAPH_DIR="/tmp/FlameGraph"
    else
        echo "Downloading FlameGraph..."
        cd /tmp
        git clone https://github.com/brendangregg/FlameGraph.git
        FLAMEGRAPH_DIR="/tmp/FlameGraph"
    fi

    if [ ! -f "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" ]; then
        echo "Error: stackcollapse-perf.pl not found"
        exit 1
    fi

    echo "    FlameGraph found: $FLAMEGRAPH_DIR"
}

setup_output_dir() {
    OUTPUT_DIR="/tmp/shmipc_perf_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$OUTPUT_DIR"
    cd "$OUTPUT_DIR"
    echo "    Output directory: $OUTPUT_DIR"
}

run_perf_record() {
    echo ""
    echo "[1/5] Starting perf record (${DURATION}s)..."
    echo "    Run qperf client in another terminal:"
    echo "    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t 120 tcp_bw tcp_lat"
    echo ""

    sudo perf record -F 99 -a -g -- sleep "$DURATION" &
    PERF_PID=$!
    echo "    perf record PID: $PERF_PID"

    sleep 2

    cd "$SHMIPC_DIR"
    LD_PRELOAD=./libshmipc.so qperf &
    QPERF_PID=$!
    echo "    qperf server PID: $QPERF_PID"

    echo "    Waiting for ${DURATION}s..."
    wait $PERF_PID 2>/dev/null || true

    sleep 2
    sudo pkill -f "qperf" 2>/dev/null || true

    cd "$OUTPUT_DIR"
    echo "    perf record complete"
}

generate_flamegraph() {
    echo ""
    echo "[2/5] Generating flamegraph..."

    if [ ! -f perf.data ]; then
        echo "Error: perf.data not found"
        exit 1
    fi

    echo "    Converting perf.data to folded stack..."
    sudo "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" perf.data > perf_unfolded.txt 2>/dev/null || \
        "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" perf.data > perf_unfolded.txt 2>/dev/null

    echo "    Generating SVG..."
    "$FLAMEGRAPH_DIR/flamegraph.pl" --colors=java perf_unfolded.txt > shmipc_flamegraph.svg

    echo "    FlameGraph: $OUTPUT_DIR/shmipc_flamegraph.svg"
}

run_perf_report() {
    echo ""
    echo "[3/5] Generating perf report..."

    {
        echo "=========================================="
        echo "perf report - Top Functions by Overhead"
        echo "=========================================="
        echo ""

        sudo perf report --stdio -g none -i perf.data 2>/dev/null | head -80

        echo ""
        echo "=========================================="
        echo "perf report - Call Graph (Top 20)"
        echo "=========================================="
        echo ""

        sudo perf report --stdio -g caller -i perf.data 2>/dev/null | head -100

    } > perf_report.txt

    echo "    Report: $OUTPUT_DIR/perf_report.txt"
}

analyze_shmipc_functions() {
    echo ""
    echo "[4/5] Analyzing shmipc functions..."

    {
        echo "=========================================="
        echo "shmipc Function Analysis"
        echo "=========================================="
        echo ""

        echo "--- Symbols containing 'shmipc' or 'Shmipc' ---"
        if [ -f perf.data ]; then
            sudo perf script -i perf.data 2>/dev/null | grep -i "shmipc" | head -50
        fi
        echo ""

        echo "--- Symbols containing 'Write' or 'Read' ---"
        if [ -f perf.data ]; then
            sudo perf script -i perf.data 2>/dev/null | grep -E "(Write|Read)" | head -50
        fi
        echo ""

        echo "--- Go runtime symbols ---"
        if [ -f perf.data ]; then
            sudo perf script -i perf.data 2>/dev/null | grep -E "runtime\." | head -30
        fi
        echo ""

    } > shmipc_analysis.txt

    echo "    Analysis: $OUTPUT_DIR/shmipc_analysis.txt"
}

show_summary() {
    echo ""
    echo "[5/5] Complete!"
    echo ""
    echo "=========================================="
    echo "Analysis Complete!"
    echo "=========================================="
    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    echo ""
    echo "Generated files:"
    ls -la "$OUTPUT_DIR"
    echo ""
    echo "Key results:"
    echo "  - shmipc_flamegraph.svg  : 火焰图 (用浏览器打开)"
    echo "  - perf_report.txt        : perf 报告"
    echo "  - shmipc_analysis.txt     : shmipc 函数分析"
    echo ""
    echo "View flamegraph:"
    echo "  firefox $OUTPUT_DIR/shmipc_flamegraph.svg"
    echo ""
    echo "View perf report:"
    echo "  cat $OUTPUT_DIR/perf_report.txt"
    echo ""
    echo "Copy to Windows desktop:"
    echo "  cp $OUTPUT_DIR/shmipc_flamegraph.svg /mnt/c/Users/\$USER/Desktop/"
}

setup_flamegraph
setup_output_dir
run_perf_record
generate_flamegraph
run_perf_report
analyze_shmipc_functions
show_summary
