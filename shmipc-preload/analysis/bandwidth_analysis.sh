#!/bin/bash
#
# ============================================================================
# shmipc-preload 带宽分析脚本
# ============================================================================
# 
# 【脚本功能】
# 本脚本用于分析 shmipc-preload 的带宽瓶颈和内存带宽使用情况。
# 主要功能包括：
#   1. 内存带宽测试 - 测试系统内存带宽上限
#   2. CPU 缓存信息获取 - 获取 L1/L2/L3 缓存大小
#   3. 缓存性能分析 - 分析缓存命中率和未命中率
#   4. 带宽测试 - 测试不同消息大小下的带宽
#   5. 内存带宽使用监控 - 实时监控内存带宽使用
#   6. 生成分析报告 - 汇总所有分析结果
# 
# 【使用方法】
#   ./bandwidth_analysis.sh [action] [msg_size]
#
# 【参数说明】
#   action: 操作类型
#     - all      : 运行完整分析（默认）
#     - test     : 测试特定消息大小的带宽
#     - memory   : 仅分析内存带宽
#     - cache    : 仅分析缓存性能
#     - report   : 生成分析报告
#   msg_size: 消息大小（字节），默认 1048576 (1MB)
#
# 【示例】
#   ./bandwidth_analysis.sh                    # 运行完整分析
#   ./bandwidth_analysis.sh test 65536         # 测试 64KB 消息的带宽
#   ./bandwidth_analysis.sh memory             # 仅分析内存带宽
#   ./bandwidth_analysis.sh cache              # 仅分析缓存性能
#   ./bandwidth_analysis.sh report             # 生成分析报告
#
# 【输出结果】
#   logs/bandwidth/mem_bandwidth_*.log     - 内存带宽测试结果
#   logs/bandwidth/cache_info_*.log        - CPU 缓存信息
#   logs/bandwidth/cache_perf_*.log        - 缓存性能数据
#   logs/bandwidth/bandwidth_*.log         - 带宽测试结果
#   logs/bandwidth/memory_bandwidth_*.csv  - 内存带宽使用监控数据
#   logs/bandwidth/bandwidth_report_*.txt  - 带宽分析报告
#
# 【依赖工具】
#   - perf  : Linux 内核性能分析工具
#   - qperf : 网络性能测试工具
#   - mbw   : 内存带宽测试工具（可选）
#
# 【作者】shmipc-preload 分析工具
# 【版本】1.0
# ============================================================================

# ============================================================================
# set -e 的作用：
# 当脚本中任何命令返回非零退出码时，立即退出脚本。
# 这是一种错误处理机制，可以防止错误被忽略。
# ============================================================================
set -e

# ============================================================================
# 变量定义部分
# ============================================================================

# ---------------------------------------------------------------------------
# SCRIPT_DIR: 获取当前脚本所在的目录
# 
# 语法解释：
#   ${BASH_SOURCE[0]}  - 当前脚本的完整路径
#   dirname            - 提取路径中的目录部分
#   cd                 - 切换到该目录
#   pwd                - 获取当前工作目录的绝对路径
#
# 为什么要这样做？
#   这样可以确保无论从哪个目录运行脚本，都能正确找到相关文件。
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# PRELOAD_DIR: 获取 shmipc-preload 的根目录
# ---------------------------------------------------------------------------
PRELOAD_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# LOG_DIR: 日志输出目录
# ---------------------------------------------------------------------------
LOG_DIR="$SCRIPT_DIR/logs/bandwidth"

# ---------------------------------------------------------------------------
# DATE_STR: 当前日期时间字符串，用于生成唯一的日志文件名
# ---------------------------------------------------------------------------
DATE_STR=$(date +%Y%m%d_%H%M%S)

# ---------------------------------------------------------------------------
# mkdir -p: 创建目录
# 
# -p 参数的作用：
#   1. 如果目录已存在，不会报错
#   2. 如果父目录不存在，会递归创建
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

# ============================================================================
# 颜色定义部分
# ============================================================================
# 
# ANSI 颜色转义码说明：
#   \033[ 是转义序列的开始
#   0;31m 中的数字表示颜色和样式
#   \033[0m 重置所有样式
#
# 颜色代码：
#   0;31 - 红色 (RED)
#   0;32 - 绿色 (GREEN)
#   1;33 - 黄色加粗 (YELLOW)
#   0;34 - 蓝色加粗 (BLUE)
#   0    - 重置 (NC = No Color)
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# 日志函数定义
# ============================================================================

# ---------------------------------------------------------------------------
# log_info: 输出信息级别的日志（绿色）
# ---------------------------------------------------------------------------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# ---------------------------------------------------------------------------
# log_warn: 输出警告级别的日志（黄色）
# ---------------------------------------------------------------------------
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# ---------------------------------------------------------------------------
# log_error: 输出错误级别的日志（红色）
# ---------------------------------------------------------------------------
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ---------------------------------------------------------------------------
# log_section: 输出章节标题（蓝色）
# 
# 用于分隔不同的分析阶段，使输出更清晰
# ---------------------------------------------------------------------------
log_section() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# ============================================================================
# 检查函数定义
# ============================================================================

# ---------------------------------------------------------------------------
# check_dependencies: 检查依赖工具是否安装
# 
# 语法解释：
#   local missing=()        - 声明一个空数组，用于存储缺失的工具
#   command -v perf         - 检查 perf 命令是否存在
#   >/dev/null 2>&1         - 将标准输出和错误输出都丢弃
#   || missing+=("perf")    - 如果命令不存在，添加到 missing 数组
#
#   ${#missing[@]}          - 获取数组长度
#   ${missing[*]}           - 获取数组所有元素
# ---------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    
    # 检查 perf 是否安装
    # command -v 返回命令路径，如果命令不存在则返回非零退出码
    command -v perf >/dev/null 2>&1 || missing+=("perf")
    command -v qperf >/dev/null 2>&1 || missing+=("qperf")
    
    # 如果有缺失的工具，打印错误信息并退出
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖工具: ${missing[*]}"
        exit 1
    fi
}

# ============================================================================
# 分析函数定义
# ============================================================================

# ---------------------------------------------------------------------------
# get_memory_bandwidth: 测试系统内存带宽
# 
# 内存带宽是影响 shmipc 性能的重要因素之一。
# 如果 shmipc 的带宽接近内存带宽上限，说明已达到硬件瓶颈。
# 
# mbw 工具说明：
#   mbw 是一个内存带宽测试工具，可以测试内存复制、内存读取等操作的带宽。
#   参数 256M 表示测试 256MB 数据的内存带宽。
# ---------------------------------------------------------------------------
get_memory_bandwidth() {
    log_section "内存带宽分析"
    
    log_info "测试内存带宽..."
    
    # 检查 mbw 是否安装
    # command -v mbw >/dev/null 2>&1 - 检查 mbw 命令是否存在
    if command -v mbw >/dev/null 2>&1; then
        # mbw 256M - 测试 256MB 数据的内存带宽
        # 2>&1 - 将标准错误重定向到标准输出
        # | tee "$LOG_DIR/mem_bandwidth_${DATE_STR}.log" - 同时输出到终端和文件
        mbw 256M 2>&1 | tee "$LOG_DIR/mem_bandwidth_${DATE_STR}.log"
    else
        log_warn "mbw 未安装，跳过内存带宽测试"
        log_info "安装方法: apt install mbw 或 yum install mbw"
    fi
}

# ---------------------------------------------------------------------------
# get_cache_info: 获取 CPU 缓存信息
# 
# CPU 缓存对性能影响很大：
#   - L1 缓存最快但最小（通常 32KB-64KB）
#   - L2 缓存较快（通常 256KB-1MB）
#   - L3 缓存最大但最慢（通常 8MB-64MB）
# 
# getconf 命令说明：
#   getconf - 查询系统配置变量
#   LEVEL1_DCACHE_SIZE - L1 数据缓存大小
#   LEVEL1_DCACHE_LINESIZE - L1 缓存行大小
#   LEVEL1_DCACHE_ASSOC - L1 缓存关联度
# ---------------------------------------------------------------------------
get_cache_info() {
    log_section "CPU 缓存信息"
    
    log_info "获取 CPU 缓存信息..."
    
    {
        echo "=== L1 数据缓存 ==="
        # getconf LEVEL1_DCACHE_SIZE - 获取 L1 数据缓存大小（字节）
        getconf LEVEL1_DCACHE_SIZE
        # getconf LEVEL1_DCACHE_LINESIZE - 获取缓存行大小（字节）
        # 缓存行是 CPU 读取内存的最小单位，通常是 64 字节
        getconf LEVEL1_DCACHE_LINESIZE
        # getconf LEVEL1_DCACHE_ASSOC - 获取缓存关联度
        # 关联度影响缓存命中率，越高越好
        getconf LEVEL1_DCACHE_ASSOC
        
        echo ""
        echo "=== L2 缓存 ==="
        getconf LEVEL2_CACHE_SIZE
        getconf LEVEL2_CACHE_LINESIZE
        getconf LEVEL2_CACHE_ASSOC
        
        echo ""
        echo "=== L3 缓存 ==="
        getconf LEVEL3_CACHE_SIZE
        getconf LEVEL3_CACHE_LINESIZE
        getconf LEVEL3_CACHE_ASSOC
        
    } | tee "$LOG_DIR/cache_info_${DATE_STR}.log"
}

# ---------------------------------------------------------------------------
# analyze_cache_performance: 分析进程的缓存性能
# 
# 参数：
#   $1 - pid: 要分析的进程 ID
#   $2 - duration: 分析时长（秒），默认 10 秒
#
# perf stat 参数说明：
#   -e events - 指定要统计的事件
#   -p pid    - 指定要分析的进程
#   -o file   - 指定输出文件
#   -- sleep N - 统计 N 秒
#
# 事件说明：
#   cycles            - CPU 周期数
#   instructions      - 指令数
#   cache-references  - 缓存访问次数
#   cache-misses      - 缓存未命中次数
#   L1-dcache-loads   - L1 数据缓存加载次数
#   L1-dcache-load-misses - L1 数据缓存加载未命中次数
#   LLC-loads         - 最后一级缓存（L3）加载次数
#   LLC-load-misses   - 最后一级缓存加载未命中次数
# ---------------------------------------------------------------------------
analyze_cache_performance() {
    local pid=$1
    local duration=${2:-10}
    
    log_section "缓存性能分析"
    
    log_info "分析进程 $pid 的缓存性能..."
    
    # perf stat - 统计硬件性能计数器
    # -e 指定要统计的事件列表
    perf stat -e cycles,instructions,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses \
        -p $pid -o "$LOG_DIR/cache_perf_${DATE_STR}.log" -- sleep $duration
    
    # 显示统计结果
    cat "$LOG_DIR/cache_perf_${DATE_STR}.log"
}

# ---------------------------------------------------------------------------
# run_bandwidth_test: 运行带宽测试
# 
# 参数：
#   $1 - msg_size: 消息大小（字节）
#   $2 - use_shmipc: 是否使用 shmipc (true/false)
#
# 同时使用 perf 监控缓存性能，以便分析带宽瓶颈
# ---------------------------------------------------------------------------
run_bandwidth_test() {
    local msg_size=$1
    local use_shmipc=$2
    
    log_section "带宽测试 (msg_size=$msg_size, shmipc=$use_shmipc)"
    
    # 生成日志文件名
    # $([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")
    # 这是一个条件表达式，根据 use_shmipc 的值选择输出 "shmipc" 或 "socket"
    local log_file="$LOG_DIR/bandwidth_${msg_size}_$([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")_${DATE_STR}.log"
    
    # 启动 qperf 服务器
    # & 符号表示在后台运行
    # $! 获取最后一个后台进程的 PID
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    else
        qperf &
    fi
    local server_pid=$!
    sleep 2
    
    # 同时启动 perf 监控缓存性能
    # & 符号表示在后台运行
    perf stat -e cycles,instructions,cache-references,cache-misses \
        -p $server_pid -o "${log_file}.perf" &
    local perf_pid=$!
    
    # 运行 qperf 客户端
    # 参数说明：
    #   127.0.0.1  - 连接本地服务器
    #   -m $msg_size - 设置消息大小
    #   -t 10      - 测试时长 10 秒
    #   tcp_bw     - 测试 TCP 带宽
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    else
        qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    fi
    
    # 停止 perf 监控
    # 2>/dev/null - 将错误输出丢弃
    # || true - 即使失败也继续
    kill $perf_pid 2>/dev/null || true
    wait $perf_pid 2>/dev/null || true
    
    # 停止 qperf 服务器
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    log_info "结果保存到: $log_file"
    log_info "性能数据: ${log_file}.perf"
}

# ---------------------------------------------------------------------------
# analyze_memory_bandwidth_usage: 分析内存带宽使用情况
# 
# 参数：
#   $1 - msg_size: 消息大小（字节）
#   $2 - duration: 分析时长（秒），默认 10 秒
#
# 通过监控 /proc/net/dev 文件来获取网络接口的流量统计
# ---------------------------------------------------------------------------
analyze_memory_bandwidth_usage() {
    local msg_size=$1
    local duration=${2:-10}
    
    log_section "内存带宽使用分析"
    
    log_info "启动测试程序..."
    
    # 启动 qperf 服务器
    LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    local server_pid=$!
    sleep 2
    
    # 启动 qperf 客户端（后台运行）
    LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t $duration tcp_bw &
    local client_pid=$!
    
    log_info "监控内存带宽使用..."
    
    {
        # CSV 表头
        echo "时间,rx_bytes,tx_bytes,rx_packets,tx_packets"
        
        # 获取开始时间
        # $(date +%s) - 获取当前时间的 Unix 时间戳（秒）
        local start_time=$(date +%s)
        
        # 初始化前一次的统计值
        local prev_rx=0
        local prev_tx=0
        
        # 循环监控
        while true; do
            # 获取当前时间
            local current_time=$(date +%s)
            
            # 计算已经过的时间
            # $(( )) 是算术扩展，用于进行整数运算
            local elapsed=$((current_time - start_time))
            
            # 如果已经过了指定时长，退出循环
            if [[ $elapsed -ge $duration ]]; then
                break
            fi
            
            # 读取网络接口统计信息
            # cat /proc/net/dev - 读取网络设备统计信息
            # grep "lo:" - 过滤出回环接口（lo）的信息
            # awk '{print $2, $10, $3, $11}' - 提取接收字节数、发送字节数、接收包数、发送包数
            # read rx_bytes tx_bytes rx_packets tx_packets - 将提取的值赋给变量
            read rx_bytes tx_bytes rx_packets tx_packets <<< $(cat /proc/net/dev | grep "lo:" | awk '{print $2, $10, $3, $11}')
            
            # 如果不是第一次读取，计算速率
            if [[ $prev_rx -gt 0 ]]; then
                # 计算增量
                local rx_delta=$((rx_bytes - prev_rx))
                local tx_delta=$((tx_bytes - prev_tx))
                
                # 转换为 MB/s
                # $((rx_delta / 1024 / 1024)) - 将字节转换为 MB
                local rx_rate=$((rx_delta / 1024 / 1024))
                local tx_rate=$((tx_delta / 1024 / 1024))
                
                # 输出统计信息
                # $(date +%H:%M:%S) - 获取当前时间（时:分:秒）
                echo "$(date +%H:%M:%S),$rx_rate,$tx_rate,$rx_packets,$tx_packets"
            fi
            
            # 保存当前值，用于下次计算增量
            prev_rx=$rx_bytes
            prev_tx=$tx_bytes
            
            # 等待 1 秒
            sleep 1
        done
        
    } | tee "$LOG_DIR/memory_bandwidth_${DATE_STR}.csv"
    
    # 停止测试程序
    kill $client_pid 2>/dev/null || true
    kill $server_pid 2>/dev/null || true
    wait $client_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# generate_bandwidth_report: 生成带宽分析报告
# 
# 汇总所有分析结果，生成最终报告
# ---------------------------------------------------------------------------
generate_bandwidth_report() {
    log_section "生成带宽分析报告"
    
    local report_file="$LOG_DIR/bandwidth_report_${DATE_STR}.txt"
    
    {
        echo "========================================"
        echo "  shmipc-preload 带宽分析报告"
        echo "========================================"
        echo ""
        echo "生成时间: $(date)"
        echo ""
        
        # 系统信息
        echo "=== 系统信息 ==="
        # lscpu - 显示 CPU 信息
        # grep 'Model name' - 过滤出 CPU 型号
        # cut -d: -f2 - 以冒号分隔，取第二列
        echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2)"
        # free -h - 显示内存信息（人类可读格式）
        # grep Mem - 过滤出内存行
        # awk '{print $2}' - 提取第二列（总内存）
        echo "内存: $(free -h | grep Mem | awk '{print $2}')"
        echo "内核: $(uname -r)"
        echo ""
        
        # 缓存信息
        echo "=== 缓存信息 ==="
        # numfmt --to=iec - 将字节数转换为人类可读格式（如 32K, 1M）
        echo "L1 数据缓存: $(getconf LEVEL1_DCACHE_SIZE | numfmt --to=iec)"
        echo "L2 缓存: $(getconf LEVEL2_CACHE_SIZE | numfmt --to=iec)"
        echo "L3 缓存: $(getconf LEVEL3_CACHE_SIZE | numfmt --to=iec)"
        echo ""
        
        # 带宽测试结果
        echo "=== 带宽测试结果 ==="
        
        # 遍历所有带宽测试日志文件
        # for log in "$LOG_DIR"/bandwidth_*_${DATE_STR}.log - 遍历匹配的文件
        for log in "$LOG_DIR"/bandwidth_*_${DATE_STR}.log; do
            if [[ -f "$log" ]]; then
                local basename=$(basename "$log")
                echo ""
                echo "--- $basename ---"
                # grep "tcp_bw" - 查找包含 tcp_bw 的行
                # || echo "无带宽数据" - 如果没有找到，输出提示
                grep "tcp_bw" "$log" || echo "无带宽数据"
            fi
        done
        
        echo ""
        echo "=== 分析结论 ==="
        echo "1. 带宽瓶颈分析："
        echo "   - 如果带宽接近内存带宽上限，说明已达到硬件瓶颈"
        echo "   - 如果带宽远低于内存带宽，说明存在软件瓶颈"
        echo ""
        echo "2. 缓存性能分析："
        echo "   - 查看 cache_perf_*.log 文件中的缓存未命中率"
        echo "   - 高缓存未命中率可能表示内存访问模式不佳"
        echo ""
        echo "3. 优化建议："
        echo "   - 如果内存拷贝是瓶颈，考虑优化 CGO 数据传递"
        echo "   - 如果缓存未命中率高，考虑优化数据结构布局"
        
    } > "$report_file"
    
    log_info "报告保存到: $report_file"
    cat "$report_file"
}

# ---------------------------------------------------------------------------
# print_usage: 打印使用帮助
# ---------------------------------------------------------------------------
print_usage() {
    echo "shmipc-preload 带宽分析脚本"
    echo ""
    echo "使用方法:"
    echo "  $0                      # 运行完整分析"
    echo "  $0 test <msg_size>      # 测试特定消息大小的带宽"
    echo "  $0 memory               # 仅分析内存带宽"
    echo "  $0 cache                # 仅分析缓存性能"
    echo "  $0 report               # 生成分析报告"
    echo ""
    echo "示例:"
    echo "  $0 test 1048576"
    echo "  $0 memory"
    echo "  $0 cache"
}

# ============================================================================
# 主函数
# ============================================================================
# 
# main 函数是脚本的入口点
# $1 表示脚本的第一个参数
# ${1:-"all"} 表示如果 $1 未设置，则使用默认值 "all"
# ---------------------------------------------------------------------------
main() {
    local action=${1:-"all"}
    local msg_size=${2:-1048576}
    
    # case 语句：类似于其他语言的 switch
    # 语法：case $var in pattern) commands ;; esac
    case "$action" in
        all)
            # 运行完整分析
            check_dependencies
            get_cache_info
            get_memory_bandwidth
            run_bandwidth_test 65536 false
            run_bandwidth_test 65536 true
            run_bandwidth_test 1048576 false
            run_bandwidth_test 1048576 true
            analyze_memory_bandwidth_usage 1048576 10
            generate_bandwidth_report
            ;;
        test)
            # 测试特定消息大小的带宽
            check_dependencies
            run_bandwidth_test $msg_size false
            run_bandwidth_test $msg_size true
            ;;
        memory)
            # 仅分析内存带宽
            get_memory_bandwidth
            ;;
        cache)
            # 仅获取缓存信息
            get_cache_info
            ;;
        report)
            # 生成分析报告
            generate_bandwidth_report
            ;;
        help|--help|-h)
            # 显示帮助
            print_usage
            ;;
        *)
            # 未知命令
            log_error "未知操作: $action"
            print_usage
            exit 1
            ;;
    esac
}

# ============================================================================
# 脚本执行入口
# ============================================================================
# 
# "$@" 表示传递给脚本的所有参数
# 例如：./bandwidth_analysis.sh test 65536
# "$@" 就是 "test" "65536"
# ============================================================================
main "$@"
