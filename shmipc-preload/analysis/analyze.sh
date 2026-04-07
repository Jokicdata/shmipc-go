#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRELOAD_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$OUTPUT_DIR"

usage() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  profile      Run with profiling enabled (time-stamp logging)"
    echo "  perf         Run with Linux perf"
    echo "  ftrace       Run with ftrace"
    echo "  flamegraph   Generate flamegraph"
    echo "  benchmark    Run comprehensive benchmark"
    echo "  analyze      Analyze existing profile data"
    echo ""
    echo "Examples:"
    echo "  $0 profile -- sockperf sr --tcp -i 127.0.0.1"
    echo "  $0 perf -- sockperf pp --tcp -i 127.0.0.1 -m 64K"
    echo "  $0 flamegraph -- qperf 127.0.0.1 tcp_bw"
    echo ""
}

check_prerequisites() {
    local missing=()
    
    if ! command -v perf &> /dev/null; then
        missing+=("perf")
    fi
    
    if [ "$1" == "flamegraph" ]; then
        if ! command -v flamegraph.pl &> /dev/null && [ ! -f "$SCRIPT_DIR/flamegraph.pl" ]; then
            missing+=("flamegraph.pl (download from https://github.com/brendangregg/FlameGraph)")
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing prerequisites:"
        for tool in "${missing[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian: sudo apt-get install linux-tools-common linux-tools-generic linux-tools-\$(uname -r)"
        echo "  CentOS/RHEL:   sudo yum install perf"
        echo "  FlameGraph:    git clone https://github.com/brendangregg/FlameGraph.git"
        exit 1
    fi
}

run_profile() {
    local log_file="$OUTPUT_DIR/profile_${TIMESTAMP}.log"
    
    echo "=========================================="
    echo "Running with profiling enabled"
    echo "=========================================="
    echo "Log file: $log_file"
    echo ""
    
    export SHMIPC_PROFILE=1
    export SHMIPC_LOG=2
    export LD_PRELOAD="$PRELOAD_DIR/libshmipc.so"
    
    "$@"
    
    local pid=$!
    wait $pid
    
    if [ -f "/tmp/shmipc_profile_$pid.log" ]; then
        mv "/tmp/shmipc_profile_$pid.log" "$log_file"
        echo ""
        echo "Profile data saved to: $log_file"
        echo ""
        echo "Quick analysis:"
        echo "  $0 analyze $log_file"
    fi
}

run_perf() {
    local perf_data="$OUTPUT_DIR/perf_${TIMESTAMP}.data"
    local perf_report="$OUTPUT_DIR/perf_${TIMESTAMP}.txt"
    
    echo "=========================================="
    echo "Running with Linux perf"
    echo "=========================================="
    echo "Perf data: $perf_data"
    echo ""
    
    export LD_PRELOAD="$PRELOAD_DIR/libshmipc.so"
    
    perf record -g -o "$perf_data" -- "$@"
    
    echo ""
    echo "Generating report..."
    perf report -i "$perf_data" --stdio > "$perf_report"
    
    echo ""
    echo "Perf report saved to: $perf_report"
    echo ""
    echo "View interactive report:"
    echo "  perf report -i $perf_data"
    echo ""
    echo "Generate flamegraph:"
    echo "  $0 flamegraph $perf_data"
}

run_ftrace() {
    local trace_file="$OUTPUT_DIR/ftrace_${TIMESTAMP}.log"
    
    echo "=========================================="
    echo "Running with ftrace"
    echo "=========================================="
    echo "Trace file: $trace_file"
    echo ""
    
    if [ ! -w /sys/kernel/debug/tracing ]; then
        echo "Error: Need root access for ftrace"
        echo "Run with: sudo $0 ftrace -- <command>"
        exit 1
    fi
    
    export LD_PRELOAD="$PRELOAD_DIR/libshmipc.so"
    
    echo "Setting up ftrace..."
    echo 0 > /sys/kernel/debug/tracing/tracing_on
    echo > /sys/kernel/debug/tracing/trace
    echo function_graph > /sys/kernel/debug/tracing/current_tracer
    
    echo Shmipc* > /sys/kernel/debug/tracing/set_ftrace_filter 2>/dev/null || true
    
    echo 1 > /sys/kernel/debug/tracing/tracing_on
    
    "$@"
    local pid=$!
    wait $pid
    
    echo 0 > /sys/kernel/debug/tracing/tracing_on
    cat /sys/kernel/debug/tracing/trace > "$trace_file"
    echo > /sys/kernel/debug/tracing/trace
    
    echo ""
    echo "Ftrace data saved to: $trace_file"
}

run_flamegraph() {
    local perf_data="$1"
    local svg_file="$OUTPUT_DIR/flamegraph_${TIMESTAMP}.svg"
    
    if [ -z "$perf_data" ]; then
        echo "Error: No perf data file specified"
        echo "Usage: $0 flamegraph <perf.data>"
        exit 1
    fi
    
    echo "=========================================="
    echo "Generating flamegraph"
    echo "=========================================="
    
    local flamegraph_script="$SCRIPT_DIR/flamegraph.pl"
    if [ ! -f "$flamegraph_script" ]; then
        flamegraph_script="flamegraph.pl"
    fi
    
    perf script -i "$perf_data" | stackcollapse-perf.pl | $flamegraph_script > "$svg_file"
    
    echo ""
    echo "Flamegraph saved to: $svg_file"
    echo ""
    echo "Open in browser:"
    echo "  firefox $svg_file"
    echo "  google-chrome $svg_file"
}

run_benchmark() {
    local result_file="$OUTPUT_DIR/benchmark_${TIMESTAMP}.log"
    
    echo "=========================================="
    echo "Running comprehensive benchmark"
    echo "=========================================="
    echo "Result file: $result_file"
    echo ""
    
    MSG_SIZES=(512 1024 4096 16384 65536 262144 1048576)
    
    echo "=== Benchmark Results ===" | tee "$result_file"
    echo "Date: $(date)" | tee -a "$result_file"
    echo "" | tee -a "$result_file"
    
    for MSG_SIZE in "${MSG_SIZES[@]}"; do
        echo "" | tee -a "$result_file"
        echo "=== Message Size: $MSG_SIZE bytes ===" | tee -a "$result_file"
        
        echo "--- Socket (baseline) ---" | tee -a "$result_file"
        run_single_benchmark "socket" "$MSG_SIZE" | tee -a "$result_file"
        
        echo "" | tee -a "$result_file"
        echo "--- shmipc-preload ---" | tee -a "$result_file"
        run_single_benchmark "shmipc" "$MSG_SIZE" | tee -a "$result_file"
        
        echo "" | tee -a "$result_file"
        sleep 5
    done
    
    echo "" | tee -a "$result_file"
    echo "Benchmark complete. Results saved to: $result_file"
}

run_single_benchmark() {
    local mode="$1"
    local msg_size="$2"
    
    if [ "$mode" == "socket" ]; then
        sockperf sr --tcp -i 127.0.0.1 -p 11111 &
        local server_pid=$!
        sleep 2
        
        sockperf pp --tcp -i 127.0.0.1 -p 11111 --msg-size "$msg_size" --time 10 2>&1
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    else
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" sockperf sr --tcp -i 127.0.0.1 -p 11111 &
        local server_pid=$!
        sleep 2
        
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" sockperf pp --tcp -i 127.0.0.1 -p 11111 --msg-size "$msg_size" --time 10 2>&1
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    fi
}

analyze_profile() {
    local log_file="$1"
    
    if [ -z "$log_file" ]; then
        echo "Error: No profile log file specified"
        echo "Usage: $0 analyze <profile.log>"
        exit 1
    fi
    
    if [ ! -f "$log_file" ]; then
        echo "Error: File not found: $log_file"
        exit 1
    fi
    
    echo "=========================================="
    echo "Analyzing profile data"
    echo "=========================================="
    echo "File: $log_file"
    echo ""
    
    echo "=== CGO Call Statistics ==="
    grep "cgo_ns=" "$log_file" | awk -F'cgo_ns=' '{print $2}' | awk '
    BEGIN {
        count = 0
        total = 0
        max = 0
        min = 9223372036854775807
    }
    {
        count++
        total += $1
        if ($1 > max) max = $1
        if ($1 < min) min = $1
        sum_sq += $1 * $1
    }
    END {
        if (count > 0) {
            avg = total / count
            variance = sum_sq / count - avg * avg
            stddev = sqrt(variance)
            printf "Total calls: %d\n", count
            printf "Total time: %.3f ms\n", total / 1000000
            printf "Average: %.2f ns\n", avg
            printf "Min: %lu ns\n", min
            printf "Max: %lu ns\n", max
            printf "Stddev: %.2f ns\n", stddev
        }
    }'
    
    echo ""
    echo "=== Latency Distribution ==="
    grep "cgo_ns=" "$log_file" | awk -F'cgo_ns=' '{print $2}' | awk '
    BEGIN {
        buckets[0] = 0    # 0-100ns
        buckets[1] = 0    # 100-500ns
        buckets[2] = 0    # 500ns-1us
        buckets[3] = 0    # 1-5us
        buckets[4] = 0    # 5-10us
        buckets[5] = 0    # 10-50us
        buckets[6] = 0    # 50-100us
        buckets[7] = 0    # 100us-1ms
        buckets[8] = 0    # >1ms
    }
    {
        if ($1 < 100) buckets[0]++
        else if ($1 < 500) buckets[1]++
        else if ($1 < 1000) buckets[2]++
        else if ($1 < 5000) buckets[3]++
        else if ($1 < 10000) buckets[4]++
        else if ($1 < 50000) buckets[5]++
        else if ($1 < 100000) buckets[6]++
        else if ($1 < 1000000) buckets[7]++
        else buckets[8]++
    }
    END {
        printf "0-100ns:      %d\n", buckets[0]
        printf "100-500ns:    %d\n", buckets[1]
        printf "500ns-1us:    %d\n", buckets[2]
        printf "1-5us:        %d\n", buckets[3]
        printf "5-10us:       %d\n", buckets[4]
        printf "10-50us:      %d\n", buckets[5]
        printf "50-100us:     %d\n", buckets[6]
        printf "100us-1ms:    %d\n", buckets[7]
        printf ">1ms:         %d\n", buckets[8]
    }'
    
    echo ""
    echo "=== Throughput Analysis ==="
    grep "bytes=" "$log_file" | awk -F'bytes=' '{split($2, a, " "); print a[1]}' | awk '
    BEGIN {
        total_bytes = 0
        count = 0
    }
    {
        total_bytes += $1
        count++
    }
    END {
        printf "Total bytes: %.2f MB\n", total_bytes / 1048576
        printf "Total operations: %d\n", count
        if (count > 0) {
            printf "Average operation size: %.2f bytes\n", total_bytes / count
        }
    }'
    
    echo ""
    echo "=== Operation Type Breakdown ==="
    echo "Write operations:"
    grep "write_shmipc" "$log_file" | wc -l
    echo "Read operations:"
    grep "read_shmipc" "$log_file" | wc -l
    echo "Send operations:"
    grep "send_shmipc" "$log_file" | wc -l
    echo "Recv operations:"
    grep "recv_shmipc" "$log_file" | wc -l
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    profile)
        run_profile "$@"
        ;;
    perf)
        check_prerequisites perf
        run_perf "$@"
        ;;
    ftrace)
        run_ftrace "$@"
        ;;
    flamegraph)
        check_prerequisites flamegraph
        run_flamegraph "$@"
        ;;
    benchmark)
        run_benchmark "$@"
        ;;
    analyze)
        analyze_profile "$@"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $command"
        usage
        exit 1
        ;;
esac
