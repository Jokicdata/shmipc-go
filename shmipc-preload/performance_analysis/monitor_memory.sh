#!/bin/bash

echo "=== shmipc Memory Usage Monitor ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ -z "$1" ]; then
    echo "Usage: $0 <pid>"
    echo "  Monitors memory usage of the specified process"
    exit 1
fi

PID=$1

if [ ! -d /proc/$PID ]; then
    echo "Error: Process $PID not found"
    exit 1
fi

echo "Monitoring process $PID..."
echo "Press Ctrl+C to stop"
echo ""

echo "Time,Shared_Mem(KB),Private_Mem(KB),Virtual_Mem(KB),RSS(KB),Shared_Clean(KB),Shared_Dirty(KB)"

while true; do
    if [ ! -d /proc/$PID ]; then
        echo "Process $PID has terminated"
        break
    fi
    
    SMB_FILE=/dev/shm/shmipc_*_server_*
    SHARED_MEM=$(ls $SMB_FILE 2>/dev/null | xargs -I {} sh -c 'stat -c %s {} 2>/dev/null' | awk '{sum+=$1} END {print sum/1024}')
    
    if [ -z "$SHARED_MEM" ]; then
        SHARED_MEM=0
    fi
    
    PRIVATE_MEM=$(awk '/Private/{sum+=$2} END {print sum}' /proc/$PID/smaps 2>/dev/null)
    VIRTUAL_MEM=$(awk '/VmSize/{print $2}' /proc/$PID/status 2>/dev/null)
    RSS=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null)
    SHARED_CLEAN=$(awk '/Shared_Clean/{sum+=$2} END {print sum}' /proc/$PID/smaps 2>/dev/null)
    SHARED_DIRTY=$(awk '/Shared_Dirty/{sum+=$2} END {print sum}' /proc/$PID/smaps 2>/dev/null)
    
    TIMESTAMP=$(date +%H:%M:%S)
    
    echo "$TIMESTAMP,$SHARED_MEM,$PRIVATE_MEM,$VIRTUAL_MEM,$RSS,$SHARED_CLEAN,$SHARED_DIRTY"
    
    sleep 1
done
