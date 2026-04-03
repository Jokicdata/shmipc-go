#!/bin/bash

# 获取当前日期时间，格式为YYYYMMDDHHMM
LOG_DATE=$(date +%Y%m%d%H%M)
LOG_FILE="$LOG_DATE"_bench_test.log

# 定义msg-size数组
MSG_SIZES=(512 1024 8192 65536 131072 262144 524288)

# 启动net.traffic.sh脚本，并在后台运行
nohup ./net.traffic.sh > "$LOG_DATE"_net_traffic.log 2>&1 &
TRAFFIC_PID=$!

# 等待20秒
sleep 20

# 启动sockperf服务器
pkill -f "sockperf" 
sockperf sr --tcp &
SOCKPERF_PID=$!

# 循环执行每个msg-size的测试
for MSG_SIZE in "${MSG_SIZES[@]}"; do
    # 执行sockperf ping-pong命令
    echo "=== test start:msg-size = $MSG_SIZE ===" | tee -a $LOG_FILE
    date | tee -a $LOG_FILE
    sockperf ping-pong --ip 127.0.0.1 --tcp --port 11111 --msg-size $MSG_SIZE --time 120 | tee -a $LOG_FILE
    date | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE

    # 执行smcd stat reset命令，并添加分割线
    echo "=== smcd stat reset  ===" | tee -a $LOG_FILE
    smcd stat reset | tee -a $LOG_FILE
    echo "=== msg-size = $MSG_SIZE ===" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE

    # 间隔20秒
    sleep 20
done

# 停止sockperf服务器
echo "Stopping sockperf server..." | tee -a $LOG_FILE
kill $SOCKPERF_PID

# 等待20秒
sleep 20

# 停止net.traffic.sh脚本
echo "Stopping net.traffic.sh..." | tee -a $LOG_FILE
pkill -f "traffic"
kill $TRAFFIC_PID

# 将net.traffic.sh的输出追加到日志文件末尾
echo "=== net traffic  ===" | tee -a $LOG_FILE
cat "$LOG_DATE"_net_traffic.log | tee -a $LOG_FILE

# 删除临时文件
#rm "$LOG_DATE"_net_traffic.log

echo "test finished, the log is saved:$LOG_FILE" | tee -a $LOG_FILE