#!/bin/bash
# shmipc-perf-profile.sh - Comprehensive performance profiling script
# Usage: sudo ./shmipc-perf-profile.sh <pid> [output_dir]

set -e

PID=${1:-}
OUTPUT_DIR=${2:-"/tmp/shmipc_perf_$(date +%Y%m%d_%H%M%S)"}
DURATION=30

if [ -z "$PID" ]; then
    echo "Usage: $0 <pid> [output_dir]"
    echo "Example: $0 12345 /tmp/my_profile"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

echo "=== shmipc Performance Profiling ==="
echo "PID: $PID"
echo "Output: $OUTPUT_DIR"

profile_syscall() {
    echo ""
    echo "=== 1. Syscall Analysis (strace) ==="
    timeout 10 strace -c -p "$PID" 2>&1 | tee syscall_summary.txt || true
}

profile_flamegraph() {
    echo ""
    echo "=== 2. CPU Flamegraph (perf) ==="

    if command -v perf &> /dev/null; then
        perf record -F 99 -p "$PID" -g -- sleep 10 2>&1 | tee perf_record.log
        perf script -i perf.data > perf_unfolded.txt 2>&1

        if command -v stackcollapse-perf.pl &> /dev/null; then
            stackcollapse-perf.pl perf_unfolded.txt > flamegraph_input.txt
            flamegraph.pl flamegraph_input.txt > shmipc_flamegraph.svg
            echo "Flamegraph saved: shmipc_flamegraph.svg"
        fi
    else
        echo "perf not available, skipping..."
    fi
}

profile_memcpy() {
    echo ""
    echo "=== 3. Memory Copy Analysis ==="

    if [ -d "/proc/$PID" ]; then
        cat /proc/$PID/smaps | grep -A 20 "Anonymous:" | head -40
    fi
}

profile_gc() {
    echo ""
    echo "=== 4. Go GC Analysis ==="

    if [ -f "/proc/$PID/environ" ]; then
        if cat /proc/$PID/environ | tr '\0' '\n' | grep -q "GOGC"; then
            echo "GOGC=$(cat /proc/$PID/environ | tr '\0' '\n' | grep GOGC)"
        fi
    fi

    echo "Go runtime stats (if available via signals):"
    kill -USR1 "$PID" 2>/dev/null && sleep 1 || true
}

profile_shm() {
    echo ""
    echo "=== 5. Shared Memory Usage ==="
    ls -la /dev/shm/*shmipc* 2>/dev/null || echo "No shmipc shm files found"
    du -h /dev/shm/*shmipc* 2>/dev/null || true
}

profile_network() {
    echo ""
    echo "=== 6. Network/FD Analysis ==="
    ls -la /proc/$PID/fd 2>/dev/null | head -20 || true
    cat /proc/$PID/net/tcp 2>/dev/null | head -10 || true
}

generate_report() {
    echo ""
    echo "=== Generating Report ==="

    {
        echo "=========================================="
        echo "shmipc Performance Profile Report"
        echo "=========================================="
        echo "Date: $(date)"
        echo "PID: $PID"
        echo ""
        echo "--- Syscall Summary ---"
        cat syscall_summary.txt 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Shared Memory Usage ---"
        ls -la /dev/shm/*shmipc* 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Memory Maps ---"
        cat /proc/$PID/maps 2>/dev/null | grep -E "shm|dev" | head -20 || echo "N/A"
    } > "$OUTPUT_DIR/profile_report.txt"

    echo "Report saved: $OUTPUT_DIR/profile_report.txt"
}

echo "Starting profiling for ${DURATION}s..."
echo ""

profile_syscall &
PROFILE_PID=$!

sleep 5 &
SLEEP_PID=$!

wait $PROFILE_PID 2>/dev/null || true
wait $SLEEP_PID 2>/dev/null || true

profile_shm
profile_network
generate_report

echo ""
echo "=== Profiling Complete ==="
echo "Results saved to: $OUTPUT_DIR"