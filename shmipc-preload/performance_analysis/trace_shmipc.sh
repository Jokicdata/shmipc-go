#!/bin/bash

TRACE_DIR=/sys/kernel/debug/tracing
OUTPUT_DIR=./trace_results
mkdir -p $OUTPUT_DIR

echo "=== ftrace Tracing for shmipc ==="
echo "This script requires root privileges"

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root: sudo $0"
    exit 1
fi

echo "Setting up ftrace..."

echo 0 > $TRACE_DIR/tracing_on
echo nop > $TRACE_DIR/current_tracer

echo "Tracing key functions..."
echo sys_enter_write > $TRACE_DIR/set_ftrace_filter
echo sys_enter_read >> $TRACE_DIR/set_ftrace_filter
echo sys_enter_sendto >> $TRACE_DIR/set_ftrace_filter
echo sys_enter_recvfrom >> $TRACE_DIR/set_ftrace_filter
echo sys_exit_write >> $TRACE_DIR/set_ftrace_filter
echo sys_exit_read >> $TRACE_DIR/set_ftrace_filter
echo do_page_fault >> $TRACE_DIR/set_ftrace_filter
echo memcpy >> $TRACE_DIR/set_ftrace_filter

echo function > $TRACE_DIR/current_tracer
echo 1 > $TRACE_DIR/options/func_stack_trace
echo 1 > $TRACE_DIR/tracing_on

echo "ftrace started. Running test..."
echo "Running: LD_PRELOAD=../libshmipc.so qperf 127.0.0.1 -m 65536 -t 10"

cd ..
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 65536 -t 10

echo 0 > $TRACE_DIR/tracing_on

cat $TRACE_DIR/trace > $OUTPUT_DIR/ftrace_result.txt

echo ""
echo "=== Trace Summary ==="
echo "Total events: $(wc -l < $TRACE_DIR/trace)"
echo "Results saved to: $OUTPUT_DIR/ftrace_result.txt"

echo ""
echo "=== Top Functions ==="
grep -oP '(?<=\s)[a-z_]+(?=\s+)' $TRACE_DIR/trace | sort | uniq -c | sort -rn | head -20
