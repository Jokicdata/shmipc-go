#!/bin/bash
# shmipc-perf-analyze.sh - Performance bottleneck analysis script using ftrace
# Usage: sudo ./shmipc-perf-analyze.sh <pid> [duration]

set -e

PID=${1:-}
DURATION=${2:-10}
OUTPUT_DIR="/tmp/shmipc_trace_$(date +%Y%m%d_%H%M%S)"
MOUNT_POINT="/sys/kernel/debug/tracing"

setup_ftrace() {
    echo "Setting up ftrace..."

    if [ ! -d "$MOUNT_POINT" ]; then
        echo "Error: ftrace not available. Try: mount -t debugfs debugfs /sys/kernel/debug"
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"
    cd "$MOUNT_POINT"

    echo 0 > tracing_on
    echo > trace
    echo nop > current_tracer

    echo "function" > available_tracers
    echo "function_graph" >> available_tracers
    echo "hwlat" >> available_tracers

    echo 0 > events/enable
    echo > events/sched/sched_switch/enable
    echo > events/sched/sched_wakeup/enable
}

trace_syscalls() {
    echo "Tracing syscalls for PID: $PID"
    cd "$MOUNT_POINT"

    echo "syscall_entry_read> trace
syscall_exit_read" >> set_event
    echo "syscall_entry_write>> trace
syscall_exit_write" >> set_event
    echo "syscall_entry_send>> trace
syscall_exit_send" >> set_event
    echo "syscall_entry_recv>> trace
syscall_exit_recv" >> set_event
    echo "syscall_entry_sendto>> trace
syscall_exit_sendto" >> set_event
    echo "syscall_entry_recvfrom>> trace
syscall_exit_recvfrom" >> set_event

    echo 1 > events/syscalls/enable
}

trace_memory_copies() {
    echo "Tracing memory copy operations..."
    cd "$MOUNT_POINT"

    echo "Copy operations:"
    echo "    common_preempt_enable" >> set_event
}

trace_blocking() {
    echo "Tracing blocking operations..."
    cd "$MOUNT_POINT"

    echo "mutex_lock> trace
mutex_locked" >> set_event
    echo "mutex_unlock" >> set_event

    echo "rwsem_lock> trace
rwsem_locked" >> set_event
    echo "rwsem_unlock" >> set_event
}

trace_go_runtime() {
    echo "Tracing Go runtime (if compiled with -履行)..."
    cd "$MOUNT_POINT"

    echo "probe:runtime.malg> trace
probe:runtime.main" >> set_event
}

start_trace() {
    echo "Starting trace for ${DURATION}s..."
    cd "$MOUNT_POINT"

    echo 1 > tracing_on

    sleep "$DURATION"

    echo 0 > tracing_on
}

extract_latency() {
    echo "=== Latency Analysis ==="
    grep -c "latency" trace 2>/dev/null || echo "No latency data"

    echo ""
    echo "=== Syscall Summary ==="
    cat trace | awk '{print $4}' | sort | uniq -c | sort -rn | head -20

    echo ""
    echo "=== Function Call Count (top 20) ==="
    cat trace | grep " ==> " | awk -F'(' '{print $1}' | awk '{print $NF}' | sort | uniq -c | sort -rn | head -20
}

extract_blocking() {
    echo ""
    echo "=== Mutex/RWLock Blocking Events ==="
    cat trace | grep -E "mutex_lock|rwsem_lock" | head -50

    echo ""
    echo "=== Long Duration Events (>1ms) ==="
    cat trace | awk -F'latency=' '{if ($2+0 > 1000) print}' | head -20
}

save_trace() {
    echo "Saving trace to $OUTPUT_DIR..."
    cp trace "$OUTPUT_DIR/full_trace.txt"
    cp trace_pipe "$OUTPUT_DIR/trace_pipe.txt" 2>/dev/null || true
    cat trace | head -10000 > "$OUTPUT_DIR/trace_head.txt"

    {
        echo "=== shmipc Performance Trace Report ==="
        echo "Generated: $(date)"
        echo "PID: $PID"
        echo "Duration: ${DURATION}s"
        echo ""
        extract_latency
        extract_blocking
    } > "$OUTPUT_DIR/report.txt"

    echo "Trace saved to $OUTPUT_DIR/"
    echo "Report: $OUTPUT_DIR/report.txt"
}

cleanup() {
    echo "Cleaning up ftrace..."
    cd "$MOUNT_POINT"
    echo 0 > tracing_on
    echo > trace
    echo > events/enable
    echo > set_event
}

if [ -z "$PID" ]; then
    echo "Usage: $0 <pid> [duration]"
    echo "Example: $0 12345 30"
    echo ""
    echo "This script requires root privileges (sudo)"
    exit 1
fi

trap cleanup EXIT

setup_ftrace
trace_syscalls
trace_blocking
start_trace
save_trace

echo ""
echo "=== Analysis Complete ==="
cat "$OUTPUT_DIR/report.txt"