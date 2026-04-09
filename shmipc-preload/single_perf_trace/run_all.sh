#!/bin/bash
# run_all.sh - 一键运行完整性能分析（perf + ftrace + qperf）
#
# 使用方式:
#   ./run_all.sh [duration]
#
# 示例:
#   ./run_all.sh 60    # 运行 60 秒分析
#
# 完整流程:
#   1. 启动 qperf server
#   2. 运行 ftrace 记录
#   3. 运行 qperf client (512KB, 120秒)
#   4. 运行 perf record
#   5. 生成火焰图
#   6. 输出分析报告

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHMIPC_DIR="$(dirname "$SCRIPT_DIR")"
DURATION=${1:-60}

OUTPUT_DIR="/tmp/shmipc_full_analysis_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

FLAMEGRAPH_DIR=""
QPERF_SERVER_PID=""
QPERF_CLIENT_PID=""
PERF_PID=""

cleanup() {
    echo ""
    echo "[Cleanup] Stopping processes..."
    sudo pkill -f "perf record" 2>/dev/null || true
    sudo pkill -f "qperf" 2>/dev/null || true
    sudo kill -SIGINT $PERF_PID 2>/dev/null || true
    kill $QPERF_SERVER_PID 2>/dev/null || true
    kill $QPERF_CLIENT_PID 2>/dev/null || true
    echo "[Cleanup] Done"
}

trap cleanup EXIT

setup() {
    echo "=========================================="
    echo "shmipc Full Performance Analysis"
    echo "=========================================="
    echo "Duration: ${DURATION}s"
    echo "Output: $OUTPUT_DIR"
    echo ""

    if [ "$(id -u)" -ne 0 ]; then
        echo "Warning: Not running as root, some features may not work"
    fi

    echo "[Setup 1/6] Checking FlameGraph..."
    if [ -d ~/FlameGraph ]; then
        FLAMEGRAPH_DIR="$HOME/FlameGraph"
    elif [ -d /tmp/FlameGraph ]; then
        FLAMEGRAPH_DIR="/tmp/FlameGraph"
    else
        echo "Downloading FlameGraph..."
        cd /tmp
        git clone --depth 1 https://github.com/brendangregg/FlameGraph.git
        FLAMEGRAPH_DIR="/tmp/FlameGraph"
    fi
    echo "    FlameGraph: $FLAMEGRAPH_DIR"

    echo "[Setup 2/6] Checking shmipc build..."
    if [ ! -f "$SHMIPC_DIR/libshmipc.so" ]; then
        echo "Building shmipc..."
        cd "$SHMIPC_DIR"
        make clean && make opt
    fi
    echo "    libshmipc.so found"

    echo "[Setup 3/6] Setting up ftrace..."
    if [ -d /sys/kernel/debug/tracing ]; then
        sudo chmod 777 /sys/kernel/debug/tracing/* 2>/dev/null || true
    fi
    echo "    ftrace ready"
}

start_qperf_server() {
    echo ""
    echo "[Step 1/6] Starting qperf server..."
    cd "$SHMIPC_DIR"
    LD_PRELOAD=./libshmipc.so qperf &
    QPERF_SERVER_PID=$!
    echo "    Server PID: $QPERF_SERVER_PID"
    sleep 2
}

start_ftrace() {
    echo ""
    echo "[Step 2/6] Starting ftrace..."
    cd /sys/kernel/debug/tracing

    sudo bash -c "cat > /tmp/ftrace_start.sh << 'EOF'
#!/bin/bash
cd /sys/kernel/debug/tracing
echo 0 > tracing_on
echo > trace
echo function_graph > current_tracer
echo > set_ftrace_filter
echo '*shmipc*' > set_ftrace_filter
echo 1 > events/enable
echo 1 > tracing_on
EOF
chmod +x /tmp/ftrace_start.sh
/tmp/ftrace_start.sh"

    echo "    ftrace started"
}

start_perf_record() {
    echo ""
    echo "[Step 3/6] Starting perf record..."
    cd "$OUTPUT_DIR"

    sudo perf record -F 99 -a -g -- sleep "$DURATION" &
    PERF_PID=$!
    echo "    perf PID: $PERF_PID"
}

run_qperf_client() {
    echo ""
    echo "[Step 4/6] Running qperf client..."
    echo "    Command: LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t $((DURATION)) tcp_bw tcp_lat"
    echo ""

    cd "$SHMIPC_DIR"
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t "$DURATION" tcp_bw tcp_lat &
    QPERF_CLIENT_PID=$!

    echo "    Client PID: $QPERF_CLIENT_PID"
    wait $QPERF_CLIENT_PID 2>/dev/null || true
    echo "    qperf client finished"
}

stop_and_save_ftrace() {
    echo ""
    echo "[Step 5/6] Stopping ftrace..."
    cd /sys/kernel/debug/tracing

    sudo bash -c "echo 0 > tracing_on"
    sudo cp trace "$OUTPUT_DIR/ftrace_raw.txt"
    sudo chmod 666 "$OUTPUT_DIR/ftrace_raw.txt"

    echo "    ftrace saved to: $OUTPUT_DIR/ftrace_raw.txt"
}

wait_perf() {
    echo ""
    echo "[Step 6/6] Waiting for perf..."
    wait $PERF_PID 2>/dev/null || true
    sleep 3
    echo "    perf finished"
}

generate_reports() {
    echo ""
    echo "[Report 1/3] Analyzing ftrace..."

    {
        echo "=========================================="
        echo "ftrace Analysis Report"
        echo "=========================================="
        echo ""

        echo "--- Trace Summary ---"
        echo "Total lines: $(wc -l < "$OUTPUT_DIR/ftrace_raw.txt")"
        echo ""

        echo "--- Function Call Count (Top 20) ---"
        grep "funcgraph_entry" "$OUTPUT_DIR/ftrace_raw.txt" 2>/dev/null | \
            awk '{print $NF}' | sed 's/}//g' | sort | uniq -c | sort -rn | head -20 || \
            echo "    No funcgraph_entry data"
        echo ""

        echo "--- shmipc Related ---"
        grep -i "shmipc\|Shmipc" "$OUTPUT_DIR/ftrace_raw.txt" 2>/dev/null | head -30 || \
            echo "    No shmipc symbols found"
        echo ""

        echo "--- Sample (first 50 lines) ---"
        head -50 "$OUTPUT_DIR/ftrace_raw.txt"
        echo ""

    } > "$OUTPUT_DIR/ftrace_report.txt"

    echo "    ftrace report: $OUTPUT_DIR/ftrace_report.txt"
}

generate_flamegraph() {
    echo ""
    echo "[Report 2/3] Generating flamegraph..."

    cd "$OUTPUT_DIR"

    if [ -f perf.data ]; then
        "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" perf.data > perf_folded.txt 2>/dev/null || true
        "$FLAMEGRAPH_DIR/flamegraph.pl" --colors=java perf_folded.txt > shmipc_flamegraph.svg 2>/dev/null || true
        echo "    FlameGraph: $OUTPUT_DIR/shmipc_flamegraph.svg"
    else
        echo "    perf.data not found, skipping flamegraph"
    fi
}

generate_perf_report() {
    echo ""
    echo "[Report 3/3] Generating perf report..."

    cd "$OUTPUT_DIR"

    {
        echo "=========================================="
        echo "perf Report"
        echo "=========================================="
        echo ""

        if [ -f perf.data ]; then
            sudo perf report --stdio -g none -i perf.data 2>/dev/null | head -60
        else
            echo "perf.data not found"
        fi

    } > "$OUTPUT_DIR/perf_report.txt"

    echo "    perf report: $OUTPUT_DIR/perf_report.txt"
}

show_final_summary() {
    echo ""
    echo "=========================================="
    echo "All Complete!"
    echo "=========================================="
    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    echo ""
    echo "Files generated:"
    ls -la "$OUTPUT_DIR"
    echo ""
    echo "Key files:"
    echo "  - shmipc_flamegraph.svg  : 火焰图 (用浏览器打开)"
    echo "  - ftrace_report.txt      : ftrace 分析报告"
    echo "  - perf_report.txt        : perf 报告"
    echo "  - ftrace_raw.txt         : 原始 ftrace 数据"
    echo ""
    echo "View flamegraph:"
    if [ -f "$OUTPUT_DIR/shmipc_flamegraph.svg" ]; then
        echo "  firefox $OUTPUT_DIR/shmipc_flamegraph.svg"
        echo "  # or copy to Windows:"
        echo "  cp $OUTPUT_DIR/shmipc_flamegraph.svg /mnt/c/Users/\$USER/Desktop/"
    fi
    echo ""
    echo "View ftrace report:"
    echo "  cat $OUTPUT_DIR/ftrace_report.txt"
    echo ""
}

setup
start_qperf_server
start_ftrace
start_perf_record
run_qperf_client
stop_and_save_ftrace
wait_perf
generate_reports
generate_flamegraph
generate_perf_report
show_final_summary
