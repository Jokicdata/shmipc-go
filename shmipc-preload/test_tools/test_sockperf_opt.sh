#!/bin/bash
# test_sockperf_opt.sh - sockperf shmipc-opt 性能测试
# Usage: ./test_sockperf_opt.sh

LOG_FILE="sockperf_opt_$(date +%Y%m%d_%H%M%S).log"
MSG_SIZES=(512 1024 8192 65536 131072 262144 524288)
PORT=11111

echo "=== sockperf shmipc-opt 性能测试 ===" | tee $LOG_FILE
echo "开始时间: $(date)" | tee -a $LOG_FILE

echo ""
echo "启动 sockperf server..."
echo "请在另一个终端运行: LD_PRELOAD=./libshmipc_opt.so sockperf sr --tcp -i 127.0.0.1 -p $PORT"
echo ""

for MSG_SIZE in "${MSG_SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "=== MSG_SIZE = $MSG_SIZE ===" | tee -a $LOG_FILE

    LD_PRELOAD=./libshmipc_opt.so sockperf ping-pong \
        --ip 127.0.0.1 --tcp --port $PORT \
        --msg-size $MSG_SIZE --time 30 2>&1 | tee -a $LOG_FILE

    echo "等待 5 秒..." && sleep 5
done

echo ""
echo "=== 测试完成 ===" | tee -a $LOG_FILE
echo "结束时间: $(date)" | tee -a $LOG_FILE
echo "日志保存到: $LOG_FILE" | tee -a $LOG_FILE