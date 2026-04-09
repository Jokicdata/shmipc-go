#!/bin/bash
# ftrace_analyze.sh - shmipc ftrace 性能分析脚本
#
# 使用方式:
#   sudo ./ftrace_analyze.sh [duration]
#
# 示例:
#   sudo ./ftrace_analyze.sh 60    # 追踪 60 秒
#   sudo ./ftrace_analyze.sh 120   # 追踪 120 秒
#
# 前提条件:
#   1. 需要 root 权限
#   2. ftrace 需要挂载: sudo mount -t debugfs debugfs /sys/kernel/debug
#   3. 内核需要启用 CONFIG_FUNCTION_TRACER

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="/tmp/shmipc_ftrace_$(date +%Y%m%d_%H%M%S)"
MOUNT_POINT="/sys/kernel/debug/tracing"
DURATION=${1:-60}

echo "=========================================="
echo "shmipc ftrace Performance Analysis"
echo "=========================================="
echo "Output directory: $OUTPUT_DIR"
echo "Duration: ${DURATION}s"
echo ""

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

cleanup() {
    echo ""
    echo "[Cleanup] Restoring ftrace settings..."
    cd "$MOUNT_POINT" 2>/dev/null || true

    echo 0 > tracing_on 2>/dev/null || true
    echo nop > current_tracer 2>/dev/null || true
    echo > set_ftrace_filter 2>/dev/null || true
    echo > trace 2>/dev/null || true
    echo 0 > events/enable 2>/dev/null || true

    echo "[Cleanup] Done"
}

trap cleanup EXIT

check_prerequisites() {
    echo "[1/8] Checking prerequisites..."

    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root"
        exit 1
    fi

    if [ ! -d "$MOUNT_POINT" ]; then
        echo "Mounting debugfs..."
        mount -t debugfs debugfs /sys/kernel/debug
        if [ $? -ne 0 ]; then
            echo "Error: Failed to mount debugfs. Try: sudo mount -t debugfs debugfs /sys/kernel/debug"
            exit 1
        fi
    fi

    if [ ! -f "$MOUNT_POINT/available_tracers" ]; then
        echo "Error: ftrace not available on this system"
        exit 1
    fi

    if ! grep -q "function_graph" "$MOUNT_POINT/available_tracers"; then
        echo "Error: function_graph tracer not available"
        exit 1
    fi

    echo "    Prerequisites OK"
}

setup_ftrace() {
    echo "[2/8] Setting up ftrace..."

    cd "$MOUNT_POINT"

    echo 0 > tracing_on
    echo > trace

    if [ -f set_ftrace_filter ]; then
        echo > set_ftrace_filter
    fi

    echo "function_graph" > current_tracer

    echo "    function_graph tracer enabled"
}

setup_events() {
    echo "[3/8] Setting up trace events..."

    cd "$MOUNT_POINT"

    echo 1 > events/enable 2>/dev/null || true

    echo "    Events enabled"
}

start_trace() {
    echo "[4/8] Starting trace..."
    echo "    Trace started at $(date)"
    echo 1 > tracing_on
}

wait_for_trace() {
    echo "[5/8] Recording for ${DURATION}s..."
    echo "    Run qperf client in another terminal:"
    echo "    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t ${DURATION} tcp_bw tcp_lat"
    echo ""

    sleep "$DURATION"
}

stop_trace() {
    echo ""
    echo "[6/8] Stopping trace..."
    echo 0 > tracing_on
    echo "    Trace stopped at $(date)"
}

save_trace() {
    echo "[7/8] Saving trace data..."

    cd "$MOUNT_POINT"

    cp trace "$OUTPUT_DIR/full_trace.txt"

    if [ -f trace_pipe ]; then
        cp trace_pipe "$OUTPUT_DIR/trace_pipe.txt"
    fi

    echo "    Saved to: $OUTPUT_DIR/full_trace.txt"
    echo "    Size: $(wc -l < "$OUTPUT_DIR/full_trace.txt") lines"
}

analyze_trace() {
    echo "[8/8] Analyzing trace..."

    cd "$OUTPUT_DIR"

    {
        echo "=========================================="
        echo "shmipc ftrace Analysis Report"
        echo "=========================================="
        echo "Date: $(date)"
        echo "Duration: ${DURATION}s"
        echo ""

        echo "--- Trace Summary ---"
        echo "Total lines: $(wc -l < full_trace.txt)"
        echo ""

        echo "--- Function Call Count (Top 20) ---"
        if grep -q "funcgraph_entry" full_trace.txt; then
            grep "funcgraph_entry" full_trace.txt | awk '{print $NF}' | \
                sed 's/}//g' | sort | uniq -c | sort -rn | head -20
        else
            grep -E "^\s*[0-9]+\.\s*[0-9]+us" full_trace.txt | head -20
        fi
        echo ""

        echo "--- Longest Function Executions (Top 20 by Duration) ---"
        if grep -q "funcgraph_exit" full_trace.txt; then
            grep "funcgraph_exit" full_trace.txt | \
                awk -F'dur=' '{print $2}' | awk '{print $1}' | \
                grep -E '^[0-9]+\.[0-9]+' | sort -rn | head -20 | \
                while read dur; do
                    echo "    ${dur}ms"
                done
        else
            grep -oE "duration=[0-9.]+" full_trace.txt | \
                sed 's/duration=//' | sort -rn | head -20 | \
                while read dur; do
                    echo "    ${dur}ms"
                done
        fi
        echo ""

        echo "--- Syscall Summary ---"
        if grep -q "syscall_entry" full_trace.txt; then
            grep "syscall_entry" full_trace.txt | awk '{print $4}' | \
                sort | uniq -c | sort -rn | head -10
        else
            echo "    No syscall data captured"
        fi
        echo ""

        echo "--- shmipc Related Functions ---"
        if grep -q "Shmipc" full_trace.txt; then
            grep "Shmipc" full_trace.txt | head -50
        else
            echo "    No Shmipc functions found (may indicate preload not working)"
        fi
        echo ""

        echo "--- write/Read Syscalls ---"
        if grep -q "syscall_entry.*write" full_trace.txt; then
            grep "syscall_entry.*write" full_trace.txt | head -10
        elif grep -q "write(" full_trace.txt; then
            grep "write(" full_trace.txt | head -10
        else
            echo "    No write syscall data"
        fi
        echo ""

        echo "--- Sample Trace (first 30 lines) ---"
        head -30 full_trace.txt
        echo ""

    } > analysis_report.txt

    echo "    Analysis saved to: $OUTPUT_DIR/analysis_report.txt"
}

show_summary() {
    echo ""
    echo "=========================================="
    echo "ftrace Analysis Complete!"
    echo "=========================================="
    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    echo ""
    echo "Files generated:"
    ls -la "$OUTPUT_DIR"
    echo ""
    echo "Key files:"
    echo "  - full_trace.txt       : Raw ftrace output"
    echo "  - analysis_report.txt  : Analysis summary"
    echo ""
    echo "View analysis:"
    echo "  cat $OUTPUT_DIR/analysis_report.txt"
    echo ""
    echo "View raw trace:"
    echo "  less $OUTPUT_DIR/full_trace.txt"
    echo ""
    echo "View specific function:"
    echo "  grep 'ShmipcWrite' $OUTPUT_DIR/full_trace.txt"
    echo ""
}

check_prerequisites
setup_ftrace
setup_events
start_trace
wait_for_trace
stop_trace
save_trace
analyze_trace
show_summary
