#!/bin/bash

LOG_DATE=$(date +%Y%m%d%H%M)
LOG_FILE="$LOG_DATE"_sock_shmipc_bench_test.log

MSG_SIZES=(512 1024 8192 65536 131072 262144 524288)

nohup ./net.traffic.sh > "$LOG_DATE"_net_traffic.log 2>&1 &
TRAFFIC_PID=$!

sleep 20

pkill -f "sockperf" 
LD_PRELOAD=../libshmipc.so sockperf sr --tcp &
SOCKPERF_PID=$!

for MSG_SIZE in "${MSG_SIZES[@]}"; do
    echo "=== test start:msg-size = $MSG_SIZE ===" | tee -a $LOG_FILE
    date | tee -a $LOG_FILE
    LD_PRELOAD=../libshmipc.so sockperf ping-pong --ip 127.0.0.1 --tcp --port 11111 --msg-size $MSG_SIZE --time 120 | tee -a $LOG_FILE
    date | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE

    echo "=== smcd stat reset  ===" | tee -a $LOG_FILE
    smcd stat reset | tee -a $LOG_FILE
    echo "=== msg-size = $MSG_SIZE ===" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE

    sleep 20
done

echo "Stopping sockperf server..." | tee -a $LOG_FILE
kill $SOCKPERF_PID

sleep 20

echo "Stopping net.traffic.sh..." | tee -a $LOG_FILE
pkill -f "traffic"
kill $TRAFFIC_PID

echo "=== net traffic  ===" | tee -a $LOG_FILE
cat "$LOG_DATE"_net_traffic.log | tee -a $LOG_FILE

echo "test finished, the log is saved:$LOG_FILE" | tee -a $LOG_FILE
