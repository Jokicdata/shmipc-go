#!/bin/bash
###############################################################################
# analyze_trace.sh - shmipc 内置追踪日志分析脚本
#
# 功能：
#   读取 shmipc_bridge_trace.go 生成的 /tmp/shmipc_trace.log 日志文件，
#   统计 WRITE 和 READ 各阶段的平均耗时和占比。
#
# 日志格式（由 shmipc_bridge_trace.go 输出）：
#   WRITE sid=1 size=524288 t_reduce=0.012 t_copy=0.085 t_flush=0.025 t_total=0.135
#   READ  sid=1 size=524288 copied=524288 t_read=0.015 t_copy=0.080 t_release=0.005 t_total=0.110
#
# 各字段含义：
#   WRITE:
#     t_reduce = Reserve 阶段耗时（从共享内存池获取空闲 buffer）
#     t_copy   = Memcpy 阶段耗时（从 qperf 堆内存拷贝到共享内存）
#     t_flush  = Flush 阶段耗时（通知对端进程读取数据）
#     t_total  = 整个 ShmipcWrite 总耗时
#
#   READ:
#     t_read    = ReadBytes 阶段耗时（从共享内存读取数据到 Go slice）
#     t_copy    = Memcpy 阶段耗时（从 Go slice 拷贝到 qperf 堆内存）
#     t_release = Release 阶段耗时（释放共享内存 buffer 并复用）
#     t_total   = 整个 ShmipcRead 总耗时
#
# 使用方式：
#   1. 先运行追踪版 qperf 生成日志：
#      SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw
#   2. 然后运行本脚本分析：
#      ./analyze_trace.sh
#
# 依赖：awk, bc, grep（均为 Linux 标准工具）
###############################################################################

# 追踪日志文件路径（和 shmipc_bridge_trace.go 中的路径一致）
LOG=/tmp/shmipc_trace.log

# 检查日志文件是否存在
if [ ! -f "$LOG" ]; then
    echo "Trace log not found: $LOG"
    echo "Run with: SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf ..."
    exit 1
fi

echo "=========================================="
echo "  shmipc Trace Analysis Report"
echo "=========================================="
echo ""

# ===== 连接事件 =====
# 显示 INIT、CLIENT_CONN、SERVER_CONN、OPEN_STREAM、ACCEPT_STREAM、CLOSE 等事件
# 这些事件记录了 shmipc 连接建立和关闭的过程
echo "--- Connection Events ---"
grep -E "INIT|CLIENT_CONN|SERVER_CONN|OPEN_STREAM|ACCEPT_STREAM|CLOSE" "$LOG" | head -20
echo ""

# ===== WRITE 统计 =====
# 统计所有 WRITE 调用的各阶段平均耗时和占比
echo "--- WRITE Statistics ---"
write_count=$(grep -c "WRITE" "$LOG")
echo "Total WRITE calls: $write_count"

if [ "$write_count" -gt 0 ]; then
    # 计算各阶段平均耗时（单位：毫秒）
    # awk -F't_reduce=' 以 t_reduce= 为分隔符，取后半部分
    # split($2,a," ") 以空格分割，取第一个字段即数值
    # 最后 awk 求平均值
    echo ""
    echo "  Per-stage average (ms):"
    grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Reserve (get shm buffer): %.4f\n", sum/count}'
    grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Memcpy  (data -> shm):   %.4f\n", sum/count}'
    grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Flush   (notify peer):   %.4f\n", sum/count}'
    grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Total:                  %.4f\n", sum/count}'

    # 计算各阶段占总耗时的百分比
    # 先提取各阶段平均值，再用 bc 计算百分比
    echo ""
    echo "  Per-stage percentage:"
    reserve_avg=$(grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    copy_avg=$(grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    flush_avg=$(grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    total_avg=$(grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

    if [ "$(echo "$total_avg > 0" | bc -l 2>/dev/null)" = "1" ] 2>/dev/null; then
        printf "    Reserve: %.1f%%\n" "$(echo "$reserve_avg / $total_avg * 100" | bc -l)"
        printf "    Memcpy:  %.1f%%\n" "$(echo "$copy_avg / $total_avg * 100" | bc -l)"
        printf "    Flush:   %.1f%%\n" "$(echo "$flush_avg / $total_avg * 100" | bc -l)"
    else
        echo "    (unable to calculate percentages)"
    fi

    # 统计写入数据大小的分布
    # 可以看到每次 write 调用传了多少字节
    echo ""
    echo "  Data size distribution:"
    grep "WRITE" "$LOG" | awk -F'size=' '{split($2,a," "); print a[1]}' | \
        sort -n | uniq -c | sort -rn | head -10
fi

# ===== READ 统计 =====
# 统计所有 READ 调用的各阶段平均耗时和占比
echo ""
echo "--- READ Statistics ---"
read_count=$(grep -c "READ" "$LOG")
echo "Total READ calls: $read_count"

if [ "$read_count" -gt 0 ]; then
    echo ""
    echo "  Per-stage average (ms):"
    grep "READ" "$LOG" | awk -F't_read=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Read    (from shm):       %.4f\n", sum/count}'
    grep "READ" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Memcpy  (shm -> buf):     %.4f\n", sum/count}'
    grep "READ" "$LOG" | awk -F't_release=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Release (recycle buf):    %.4f\n", sum/count}'
    grep "READ" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Total:                    %.4f\n", sum/count}'

    echo ""
    echo "  Per-stage percentage:"
    read_avg=$(grep "READ" "$LOG" | awk -F't_read=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    rcopy_avg=$(grep "READ" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    release_avg=$(grep "READ" "$LOG" | awk -F't_release=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    rtotal_avg=$(grep "READ" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

    if [ "$(echo "$rtotal_avg > 0" | bc -l 2>/dev/null)" = "1" ] 2>/dev/null; then
        printf "    Read:    %.1f%%\n" "$(echo "$read_avg / $rtotal_avg * 100" | bc -l)"
        printf "    Memcpy:  %.1f%%\n" "$(echo "$rcopy_avg / $rtotal_avg * 100" | bc -l)"
        printf "    Release: %.1f%%\n" "$(echo "$release_avg / $rtotal_avg * 100" | bc -l)"
    else
        echo "    (unable to calculate percentages)"
    fi
fi

echo ""
echo "=========================================="
