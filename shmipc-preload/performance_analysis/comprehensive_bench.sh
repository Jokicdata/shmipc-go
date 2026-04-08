#!/bin/bash

OUTPUT_DIR=./benchmark_results
mkdir -p $OUTPUT_DIR
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE=$OUTPUT_DIR/comprehensive_bench_$TIMESTAMP.log

SIZES=(64 256 512 1024 4096 8192 16384 32768 65536 131072 262144 524288 1048576)

cd ..

echo "=== Comprehensive Benchmark ===" | tee $LOG_FILE
echo "Date: $(date)" | tee -a $LOG_FILE
echo "Hostname: $(hostname)" | tee -a $LOG_FILE
echo "Kernel: $(uname -r)" | tee -a $LOG_FILE
echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)" | tee -a $LOG_FILE
echo "Memory: $(free -h | grep Mem | awk '{print $2}')" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE

echo "=== Environment Variables ===" | tee -a $LOG_FILE
echo "SHMIPC_BUFFER_SIZE: ${SHMIPC_BUFFER_SIZE:-default (256MB)}" | tee -a $LOG_FILE
echo "SHMIPC_QUEUE_CAP: ${SHMIPC_QUEUE_CAP:-default (8192)}" | tee -a $LOG_FILE
echo "SHMIPC_BATCH_IO: ${SHMIPC_BATCH_IO:-default (enabled)}" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE

echo "=== Testing Original Socket ===" | tee -a $LOG_FILE
echo "Starting qperf server..."
pkill -f "qperf" 2>/dev/null
sleep 1
qperf &
QPERF_PID=$!
sleep 2

for SIZE in "${SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "=== Socket - Size: $SIZE bytes ===" | tee -a $LOG_FILE
    qperf 127.0.0.1 -m $SIZE -t 10 -oo msg_size:$SIZE:$SIZE 2>&1 | tee -a $LOG_FILE
    sleep 1
done

kill $QPERF_PID 2>/dev/null
sleep 2

echo "" | tee -a $LOG_FILE
echo "=== Testing shmipc (Original Implementation) ===" | tee -a $LOG_FILE
echo "Starting qperf server with shmipc..."
pkill -f "qperf" 2>/dev/null
sleep 1
LD_PRELOAD=./libshmipc.so qperf &
QPERF_PID=$!
sleep 2

for SIZE in "${SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "=== shmipc (Original) - Size: $SIZE bytes ===" | tee -a $LOG_FILE
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m $SIZE -t 10 -oo msg_size:$SIZE:$SIZE 2>&1 | tee -a $LOG_FILE
    sleep 1
done

kill $QPERF_PID 2>/dev/null
sleep 2

echo "" | tee -a $LOG_FILE
echo "=== Testing shmipc (Optimized - Large Buffer) ===" | tee -a $LOG_FILE
export SHMIPC_BUFFER_SIZE=$((256 * 1024 * 1024))
echo "Starting qperf server with optimized shmipc..."
pkill -f "qperf" 2>/dev/null
sleep 1
LD_PRELOAD=./libshmipc_optimized.so qperf &
QPERF_PID=$!
sleep 2

for SIZE in "${SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "=== shmipc (Optimized) - Size: $SIZE bytes ===" | tee -a $LOG_FILE
    LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m $SIZE -t 10 -oo msg_size:$SIZE:$SIZE 2>&1 | tee -a $LOG_FILE
    sleep 1
done

kill $QPERF_PID 2>/dev/null

echo "" | tee -a $LOG_FILE
echo "=== Testing shmipc (Optimized + Batch IO) ===" | tee -a $LOG_FILE
export SHMIPC_BATCH_IO=1
echo "Starting qperf server with batch IO..."
pkill -f "qperf" 2>/dev/null
sleep 1
LD_PRELOAD=./libshmipc_optimized.so qperf &
QPERF_PID=$!
sleep 2

for SIZE in "${SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "=== shmipc (Batch IO) - Size: $SIZE bytes ===" | tee -a $LOG_FILE
    LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m $SIZE -t 10 -oo msg_size:$SIZE:$SIZE 2>&1 | tee -a $LOG_FILE
    sleep 1
done

kill $QPERF_PID 2>/dev/null

echo "" | tee -a $LOG_FILE
echo "=== Benchmark Completed ===" | tee -a $LOG_FILE
echo "Results saved to: $LOG_FILE" | tee -a $LOG_FILE

echo "" | tee -a $LOG_FILE
echo "=== Summary ===" | tee -a $LOG_FILE
echo "To analyze results, run:" | tee -a $LOG_FILE
echo "  grep -E '(tcp_bw|tcp_lat)' $LOG_FILE" | tee -a $LOG_FILE
