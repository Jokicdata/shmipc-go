#!/bin/bash
# shmipc-cgo-latency.sh - CGO boundary latency analysis
# Usage: sudo ./shmipc-cgo-latency.sh <pid>

set -e

PID=${1:-}
OUTPUT_DIR="/tmp/shmipc_cgo_trace_$(date +%Y%m%d_%H%M%S)"

if [ -z "$PID" ]; then
    echo "Usage: $0 <pid>"
    echo "Example: $0 12345"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

echo "=== CGO Latency Analysis for PID $PID ==="

measure_syscall_latency() {
    echo ""
    echo "=== 1. Syscall Latency (strace -T) ==="
    timeout 5 strace -T -p "$PID" 2>&1 | head -100 | tee syscall_latency.txt || true
}

measure_cgo_overhead() {
    echo ""
    echo "=== 2. CGO Overhead Analysis ==="

    cat /proc/$PID/stack 2>/dev/null | head -50 || echo "Cannot read stack"

    echo ""
    echo "=== Memory Maps (looking for CGO allocations) ==="
    grep -E "shmipc|memfd|dev/shm" /proc/$PID/maps 2>/dev/null | head -20 || true
}

measure_gc_impact() {
    echo ""
    echo "=== 3. GC Impact ==="

    if [ -f "/proc/$PID/status" ]; then
        echo "VmPeak: $(grep VmPeak /proc/$PID/status | awk '{print $2, $3}')"
        echo "VmRSS: $(grep VmRSS /proc/$PID/status | awk '{print $2, $3}')"
        echo "VmSwap: $(grep VmSwap /proc/$PID/status | awk '{print $2, $3}')"
    fi

    echo ""
    echo "=== GC Pauses (if GOGC interval available) ==="
    timeout 5 cat /proc/$PID/sched 2>/dev/null | grep -E "se.sum" | head -10 || true
}

trace_blocking_operations() {
    echo ""
    echo "=== 4. Blocking Operations (using perf) ==="

    if command -v perf &> /dev/null; then
        echo "Recording context switches..."
        perf record -e context-switches -p "$PID" -g -- sleep 5 2>&1 | head -20

        echo ""
        echo "Recording scheduler..."
        perf sched record -p "$PID" -- sleep 5 2>&1 | head -20

        perf report -i perf.data --stdio 2>&1 | head -100
    else
        echo "perf not available, skipping..."
    fi
}

analyze_memory_bandwidth() {
    echo ""
    echo "=== 5. Memory Bandwidth Analysis ==="

    if [ -f "/proc/$PID/io" ]; then
        echo "=== IO Stats ==="
        cat /proc/$PID/io
    fi

    echo ""
    echo "=== FD Usage ==="
    ls -la /proc/$PID/fd 2>/dev/null | wc -l
}

generate_summary() {
    echo ""
    echo "=== Analysis Summary ==="

    {
        echo "=========================================="
        echo "shmipc CGO Latency Analysis Report"
        echo "=========================================="
        echo "PID: $PID"
        echo "Date: $(date)"
        echo ""

        echo "--- Syscall Latency ---"
        grep -E "<...>" syscall_latency.txt 2>/dev/null | head -20 || echo "N/A"

        echo ""
        echo "--- Shared Memory Usage ---"
        du -h /dev/shm/*shmipc* 2>/dev/null || echo "No shmipc shm found"

        echo ""
        echo "--- Recommendations ---"
        echo "1. If syscall latency > 100us for write/read, CGO overhead is significant"
        echo "2. If GC pause > 10ms, GC is causing latency spikes"
        echo "3. If context switches > 10000/s, lock contention is high"
    } > "$OUTPUT_DIR/cgo_summary.txt"

    cat "$OUTPUT_DIR/cgo_summary.txt"
}

echo "Starting CGO analysis..."
measure_syscall_latency
measure_cgo_overhead
measure_gc_impact
analyze_memory_bandwidth
generate_summary

echo ""
echo "=== Complete ==="
echo "Results saved to: $OUTPUT_DIR"