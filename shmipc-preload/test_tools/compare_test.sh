#!/bin/bash
# compare_test.sh - TCP vs shmipc-opt 性能对比测试
# Usage: ./compare_test.sh

LOG_DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="compare_${LOG_DATE}.log"
MSG_SIZES=(512 8192 65536 262144 524288)

echo "=== TCP vs shmipc-opt 性能对比测试 ===" | tee $LOG_FILE
echo "开始时间: $(date)" | tee -a $LOG_FILE

echo ""
echo "========================================="
echo "测试 1: 原生 TCP (对照组)"
echo "=========================================" | tee -a $LOG_FILE

for MSG_SIZE in "${MSG_SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "--- MSG_SIZE = $MSG_SIZE (TCP) ---" | tee -a $LOG_FILE
    qperf 127.0.0.1 -m $MSG_SIZE -t 20 2>&1 | tee -a $LOG_FILE
    sleep 3
done

echo ""
echo "========================================="
echo "测试 2: shmipc 优化版"
echo "=========================================" | tee -a $LOG_FILE

for MSG_SIZE in "${MSG_SIZES[@]}"; do
    echo "" | tee -a $LOG_FILE
    echo "--- MSG_SIZE = $MSG_SIZE (shmipc-opt) ---" | tee -a $LOG_FILE
    LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 -m $MSG_SIZE -t 20 2>&1 | tee -a $LOG_FILE
    sleep 3
done

echo ""
echo "========================================="
echo "测试完成"
echo "结束时间: $(date)"
echo "日志: $LOG_FILE"
echo "========================================="