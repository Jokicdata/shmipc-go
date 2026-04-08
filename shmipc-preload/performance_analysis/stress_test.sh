#!/bin/bash

echo "=== shmipc Stress Test ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

DURATION=${1:-60}
NUM_CLIENTS=${2:-4}
MSG_SIZE=${3:-65536}

echo "Parameters:"
echo "  Duration: ${DURATION}s"
echo "  Clients: $NUM_CLIENTS"
echo "  Message Size: $MSG_SIZE bytes"
echo ""

echo "Starting server..."
LD_PRELOAD=./libshmipc.so qperf &
SRV_PID=$!
sleep 2

echo "Starting $NUM_CLIENTS client processes..."
PIDS=""

for i in $(seq 1 $NUM_CLIENTS); do
    echo "  Starting client $i..."
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m $MSG_SIZE -t $DURATION tcp_bw > /tmp/stress_client_$i.log 2>&1 &
    PIDS="$PIDS $!"
done

echo ""
echo "Running stress test for ${DURATION}s..."
echo "Monitoring system resources..."

for i in $(seq 1 $DURATION); do
    CPU=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    MEM=$(free | grep Mem | awk '{print ($3/$2) * 100.0}')
    
    printf "\r[%3ds] CPU: %5.1f%% | MEM: %5.1f%%" $i $CPU $MEM
    sleep 1
done

echo ""
echo ""
echo "Waiting for clients to finish..."
for PID in $PIDS; do
    wait $PID 2>/dev/null
done

echo ""
echo "Stopping server..."
kill $SRV_PID 2>/dev/null

echo ""
echo "=== Results ==="
for i in $(seq 1 $NUM_CLIENTS); do
    echo "Client $i:"
    tail -5 /tmp/stress_client_$i.log
    echo ""
done

echo "Stress test completed."
