#!/bin/bash

echo "=== shmipc Latency Comparison Test ==="
echo "Comparing latency between socket and shmipc for different message sizes"
echo ""

cd ..

OUTPUT_DIR=./latency_results
mkdir -p $OUTPUT_DIR
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE=$OUTPUT_DIR/latency_$TIMESTAMP.csv

echo "Type,Size(Bytes),Latency(us),Percentile_50(us),Percentile_90(us),Percentile_99(us)" > $RESULT_FILE

SIZES=(64 256 512 1024 4096 8192 16384 32768 65536)

echo "=== Testing with sockperf ==="
echo ""

if ! command -v sockperf &> /dev/null; then
    echo "Error: sockperf not installed."
    echo "Install with: sudo apt install sockperf"
    exit 1
fi

echo "=== Socket Latency ==="
for SIZE in "${SIZES[@]}"; do
    echo "Testing size: $SIZE bytes"
    
    pkill -f "sockperf" 2>/dev/null
    sleep 1
    
    sockperf sr --tcp -i 127.0.0.1 -p 11111 -m $SIZE &
    SRV_PID=$!
    sleep 2
    
    RESULT=$(sockperf pp --tcp -i 127.0.0.1 -p 11111 -m $SIZE -t 10 2>&1)
    
    LATENCY=$(echo "$RESULT" | grep -oP 'avg-latency=\K[0-9.]+')
    P50=$(echo "$RESULT" | grep -oP 'percentile 50 = \K[0-9.]+')
    P90=$(echo "$RESULT" | grep -oP 'percentile 90 = \K[0-9.]+')
    P99=$(echo "$RESULT" | grep -oP 'percentile 99 = \K[0-9.]+')
    
    echo "socket,$SIZE,$LATENCY,$P50,$P90,$P99" >> $RESULT_FILE
    
    kill $SRV_PID 2>/dev/null
    sleep 1
done

echo ""
echo "=== shmipc Latency (Original) ==="
for SIZE in "${SIZES[@]}"; do
    echo "Testing size: $SIZE bytes"
    
    pkill -f "sockperf" 2>/dev/null
    sleep 1
    
    LD_PRELOAD=./libshmipc.so sockperf sr --tcp -i 127.0.0.1 -p 11111 -m $SIZE &
    SRV_PID=$!
    sleep 2
    
    RESULT=$(LD_PRELOAD=./libshmipc.so sockperf pp --tcp -i 127.0.0.1 -p 11111 -m $SIZE -t 10 2>&1)
    
    LATENCY=$(echo "$RESULT" | grep -oP 'avg-latency=\K[0-9.]+')
    P50=$(echo "$RESULT" | grep -oP 'percentile 50 = \K[0-9.]+')
    P90=$(echo "$RESULT" | grep -oP 'percentile 90 = \K[0-9.]+')
    P99=$(echo "$RESULT" | grep -oP 'percentile 99 = \K[0-9.]+')
    
    echo "shmipc_orig,$SIZE,$LATENCY,$P50,$P90,$P99" >> $RESULT_FILE
    
    kill $SRV_PID 2>/dev/null
    sleep 1
done

echo ""
echo "=== shmipc Latency (Optimized) ==="
for SIZE in "${SIZES[@]}"; do
    echo "Testing size: $SIZE bytes"
    
    pkill -f "sockperf" 2>/dev/null
    sleep 1
    
    LD_PRELOAD=./libshmipc_optimized.so sockperf sr --tcp -i 127.0.0.1 -p 11111 -m $SIZE &
    SRV_PID=$!
    sleep 2
    
    RESULT=$(LD_PRELOAD=./libshmipc_optimized.so sockperf pp --tcp -i 127.0.0.1 -p 11111 -m $SIZE -t 10 2>&1)
    
    LATENCY=$(echo "$RESULT" | grep -oP 'avg-latency=\K[0-9.]+')
    P50=$(echo "$RESULT" | grep -oP 'percentile 50 = \K[0-9.]+')
    P90=$(echo "$RESULT" | grep -oP 'percentile 90 = \K[0-9.]+')
    P99=$(echo "$RESULT" | grep -oP 'percentile 99 = \K[0-9.]+')
    
    echo "shmipc_opt,$SIZE,$LATENCY,$P50,$P90,$P99" >> $RESULT_FILE
    
    kill $SRV_PID 2>/dev/null
    sleep 1
done

echo ""
echo "=== Results ==="
cat $RESULT_FILE | column -t -s ','

echo ""
echo "Results saved to: $RESULT_FILE"
echo ""
echo "To visualize, run:"
echo "  python3 plot_latency.py $RESULT_FILE"
