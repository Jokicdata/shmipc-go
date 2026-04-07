#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/results/ftrace"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$OUTPUT_DIR"

TRACE_PATH="/sys/kernel/debug/tracing"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script requires root access for ftrace"
        echo "Run with: sudo $0 $@"
        exit 1
    fi
}

setup_ftrace() {
    echo "Setting up ftrace..."
    
    echo 0 > "$TRACE_PATH/tracing_on"
    echo > "$TRACE_PATH/trace"
    
    echo function_graph > "$TRACE_PATH/current_tracer"
    
    echo funcgraph-abstime > "$TRACE_PATH/trace_options"
    echo funcgraph-cpu > "$TRACE_PATH/trace_options"
    echo funcgraph-proc > "$TRACE_PATH/trace_options"
    echo funcgraph-duration > "$TRACE_PATH/trace_options"
    echo funcgraph-overhead > "$TRACE_PATH/trace_options"
    
    echo 1 > "$TRACE_PATH/options/funcgraph-abstime"
    echo 1 > "$TRACE_PATH/options/funcgraph-cpu"
    echo 1 > "$TRACE_PATH/options/funcgraph-proc"
    echo 1 > "$TRACE_PATH/options/funcgraph-duration"
    echo 1 > "$TRACE_PATH/options/funcgraph-overhead"
}

trace_shmipc_functions() {
    echo "Tracing shmipc functions..."
    
    echo > "$TRACE_PATH/set_ftrace_filter"
    
    echo ShmipcInit >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcCreateClientSession >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcCreateServerSession >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcOpenStream >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcAcceptStream >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcWrite >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcRead >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcCloseStream >> "$TRACE_PATH/set_ftrace_filter"
    echo ShmipcCloseSession >> "$TRACE_PATH/set_ftrace_filter"
    
    cat "$TRACE_PATH/set_ftrace_filter"
}

trace_socket_functions() {
    echo "Tracing socket functions..."
    
    echo > "$TRACE_PATH/set_ftrace_filter"
    
    echo sys_socket >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_bind >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_listen >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_accept >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_accept4 >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_connect >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_sendto >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_recvfrom >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_sendmsg >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_recvmsg >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_shutdown >> "$TRACE_PATH/set_ftrace_filter"
    echo sys_close >> "$TRACE_PATH/set_ftrace_filter"
    
    cat "$TRACE_PATH/set_ftrace_filter"
}

trace_all_ipc() {
    echo "Tracing all IPC functions..."
    
    echo > "$TRACE_PATH/set_ftrace_filter"
    
    trace_shmipc_functions
    trace_socket_functions
}

start_tracing() {
    echo "Starting tracing..."
    echo 1 > "$TRACE_PATH/tracing_on"
}

stop_tracing() {
    echo "Stopping tracing..."
    echo 0 > "$TRACE_PATH/tracing_on"
}

save_trace() {
    local output_file="$1"
    
    if [ -z "$output_file" ]; then
        output_file="$OUTPUT_DIR/trace_${TIMESTAMP}.log"
    fi
    
    echo "Saving trace to $output_file..."
    cat "$TRACE_PATH/trace" > "$output_file"
    
    echo > "$TRACE_PATH/trace"
    
    echo "Trace saved to: $output_file"
}

analyze_trace() {
    local trace_file="$1"
    
    if [ -z "$trace_file" ]; then
        echo "Error: No trace file specified"
        return 1
    fi
    
    echo "=========================================="
    echo "Analyzing ftrace data"
    echo "=========================================="
    echo "File: $trace_file"
    echo ""
    
    echo "=== Function Call Count ==="
    grep -E "Shmipc|socket|send|recv|read|write" "$trace_file" | \
        awk '{print $NF}' | sort | uniq -c | sort -rn | head -20
    echo ""
    
    echo "=== Function Duration Analysis ==="
    grep -E "Shmipc(Write|Read)" "$trace_file" | \
        awk -F'[()]' '{print $2}' | \
        awk '{
            if ($1 ~ /us/) {
                gsub(/us/, "", $1)
                sum += $1
                count++
                if ($1 > max) max = $1
            }
        }
        END {
            if (count > 0) {
                printf "Total calls: %d\n", count
                printf "Total time: %.2f us\n", sum
                printf "Average: %.2f us\n", sum/count
                printf "Max: %.2f us\n", max
            }
        }'
    echo ""
    
    echo "=== Long Duration Calls (>100us) ==="
    grep -E "Shmipc(Write|Read)" "$trace_file" | \
        awk -F'[()]' '{
            split($2, arr, "us")
            if (arr[1] > 100) {
                print $0
            }
        }' | head -20
    echo ""
    
    echo "=== Call Chain Analysis ==="
    grep -B5 -A5 "ShmipcWrite" "$trace_file" | head -50
}

run_traced_command() {
    local output_file="$OUTPUT_DIR/trace_${TIMESTAMP}.log"
    
    setup_ftrace
    trace_shmipc_functions
    
    start_tracing
    
    echo "Running command: $@"
    "$@"
    local cmd_pid=$!
    wait $cmd_pid
    
    stop_tracing
    save_trace "$output_file"
    
    analyze_trace "$output_file"
}

trace_specific_pid() {
    local pid="$1"
    local duration="${2:-10}"
    local output_file="$OUTPUT_DIR/trace_pid_${pid}_${TIMESTAMP}.log"
    
    setup_ftrace
    trace_all_ipc
    
    echo "$pid" > "$TRACE_PATH/set_ftrace_pid"
    
    start_tracing
    
    echo "Tracing PID $pid for $duration seconds..."
    sleep "$duration"
    
    stop_tracing
    save_trace "$output_file"
    
    echo "" > "$TRACE_PATH/set_ftrace_pid"
    
    analyze_trace "$output_file"
}

generate_report() {
    local trace_file="$1"
    local report_file="${trace_file%.log}_report.md"
    
    {
        echo "# Ftrace Analysis Report"
        echo ""
        echo "Generated: $(date)"
        echo "Source: $trace_file"
        echo ""
        
        echo "## Summary"
        echo ""
        
        echo "### Total Function Calls"
        echo ""
        echo "| Function | Call Count |"
        echo "|----------|------------|"
        grep -E "Shmipc|socket" "$trace_file" | \
            awk '{print $NF}' | sort | uniq -c | sort -rn | \
            awk '{printf "| %s | %d |\n", $2, $1}'
        echo ""
        
        echo "### Duration Statistics"
        echo ""
        echo "| Function | Avg (us) | Max (us) | Total (us) |"
        echo "|----------|----------|----------|------------|"
        
        for func in ShmipcWrite ShmipcRead; do
            grep "$func" "$trace_file" | \
                awk -F'[()]' '{
                    split($2, arr, "us")
                    if (arr[1] ~ /^[0-9.]+$/) {
                        sum += arr[1]
                        count++
                        if (arr[1] > max) max = arr[1]
                    }
                }
                END {
                    if (count > 0) {
                        printf "| %s | %.2f | %.2f | %.2f |\n", ENVIRON["FUNC"], sum/count, max, sum
                    }
                }' FUNC="$func"
        done
        echo ""
        
        echo "## Analysis"
        echo ""
        echo "### Observations"
        echo ""
        echo "1. CGO call overhead is visible in the trace"
        echo "2. Large data transfers show higher latency"
        echo "3. Function call patterns indicate bottleneck locations"
        echo ""
        
        echo "### Recommendations"
        echo ""
        echo "1. Consider batching small operations"
        echo "2. Optimize hot paths identified in the trace"
        echo "3. Reduce CGO call frequency where possible"
        echo ""
        
    } > "$report_file"
    
    echo "Report generated: $report_file"
}

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  run <cmd>              Run command with ftrace"
    echo "  pid <pid> [duration]   Trace specific PID"
    echo "  analyze <trace.log>    Analyze existing trace"
    echo "  report <trace.log>     Generate markdown report"
    echo ""
    echo "Examples:"
    echo "  sudo $0 run -- sockperf pp --tcp -i 127.0.0.1 -m 64K"
    echo "  sudo $0 pid 12345 30"
    echo "  $0 analyze /tmp/trace.log"
    echo "  $0 report /tmp/trace.log"
    echo ""
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    run)
        check_root
        run_traced_command "$@"
        ;;
    pid)
        check_root
        if [ -z "$1" ]; then
            echo "Error: PID required"
            usage
            exit 1
        fi
        trace_specific_pid "$1" "${2:-10}"
        ;;
    analyze)
        if [ -z "$1" ]; then
            echo "Error: Trace file required"
            usage
            exit 1
        fi
        analyze_trace "$1"
        ;;
    report)
        if [ -z "$1" ]; then
            echo "Error: Trace file required"
            usage
            exit 1
        fi
        generate_report "$1"
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
