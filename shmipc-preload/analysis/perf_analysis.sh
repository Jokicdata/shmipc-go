#!/bin/bash
#
# ============================================================================
# shmipc-preload 性能分析脚本
# ============================================================================
# 
# 【脚本功能】
# 本脚本用于自动运行 shmipc-preload 的性能测试，并收集分析数据。
# 主要功能包括：
#   1. 延迟测试 - 测试不同消息大小下的通信延迟
#   2. 带宽测试 - 测试不同消息大小下的通信带宽
#   3. 对比测试 - 对比原始 socket 和 shmipc 的性能差异
#   4. perf 分析 - 使用 perf 工具分析 CPU 热点
#   5. strace 分析 - 使用 strace 追踪系统调用
# 
# 【使用方法】
#   ./perf_analysis.sh <test_type> [msg_size]
#
# 【参数说明】
#   test_type: 测试类型
#     - latency    : 延迟测试
#     - bandwidth  : 带宽测试
#     - comparison : 对比测试（推荐，自动测试多种消息大小）
#     - perf       : perf CPU 热点分析
#     - strace     : strace 系统调用追踪
#   msg_size: 消息大小（字节），默认测试多个大小
#
# 【示例】
#   ./perf_analysis.sh comparison              # 运行对比测试
#   ./perf_analysis.sh latency 65536           # 测试 64KB 消息的延迟
#   ./perf_analysis.sh bandwidth 1048576       # 测试 1MB 消息的带宽
#   sudo ./perf_analysis.sh perf 12345         # 分析进程 12345 的 CPU 热点
#
# 【输出结果】
#   logs/latency_*.log      - 延迟测试结果
#   logs/bandwidth_*.log    - 带宽测试结果
#   logs/comparison_*.csv   - 对比测试结果（CSV 格式）
#   logs/perf_*.data        - perf 分析数据
#   logs/strace_*.log       - strace 追踪日志
#
# 【依赖工具】
#   - perf     : Linux 内核性能分析工具
#   - qperf    : 网络性能测试工具
#   - sockperf : Socket 性能测试工具（可选）
#
# 【作者】shmipc-preload 分析工具
# 【版本】1.0
# ============================================================================

# ============================================================================
# set -e 的作用：
# 当脚本中任何命令返回非零退出码时，立即退出脚本。
# 这是一种错误处理机制，可以防止错误被忽略。
# 例如：如果某个命令执行失败，脚本会立即停止，而不是继续执行后续命令。
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
#   例如：如果脚本在 /home/user/analysis/ 目录下，
#   即使从 /tmp 目录运行，SCRIPT_DIR 也会是 /home/user/analysis/
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# PRELOAD_DIR: 获取 shmipc-preload 的根目录
# 
# 语法解释：
#   dirname "$SCRIPT_DIR" - 获取脚本目录的父目录
#
# 目录结构：
#   shmipc-preload/
#   ├── analysis/           <- SCRIPT_DIR (脚本所在目录)
#   │   └── perf_analysis.sh
#   ├── libshmipc.so        <- PRELOAD_DIR (preload 根目录)
#   └── libshmipc_go.so
# ---------------------------------------------------------------------------
PRELOAD_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# LOG_DIR: 日志输出目录
# ---------------------------------------------------------------------------
LOG_DIR="$SCRIPT_DIR/logs"

# ---------------------------------------------------------------------------
# DATE_STR: 当前日期时间字符串，用于生成唯一的日志文件名
# 
# 语法解释：
#   date +%Y%m%d_%H%M%S - 格式化日期时间
#   %Y - 四位年份 (2024)
#   %m - 两位月份 (01-12)
#   %d - 两位日期 (01-31)
#   %H - 24小时制小时 (00-23)
#   %M - 分钟 (00-59)
#   %S - 秒 (00-59)
#   结果示例：20240115_143025
# ---------------------------------------------------------------------------
DATE_STR=$(date +%Y%m%d_%H%M%S)

# ---------------------------------------------------------------------------
# mkdir -p: 创建目录
# 
# -p 参数的作用：
#   1. 如果目录已存在，不会报错
#   2. 如果父目录不存在，会递归创建
#
# 例如：mkdir -p /a/b/c 会创建 /a、/a/b、/a/b/c 三个目录
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
#   0    - 重置 (NC = No Color)
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================================================
# 日志函数定义
# ============================================================================

# ---------------------------------------------------------------------------
# log_info: 输出信息级别的日志
# 
# 语法解释：
#   echo -e        - 启用转义序列解析
#   ${GREEN}       - 绿色开始
#   [INFO]         - 日志标签
#   ${NC}          - 颜色重置
#   $1             - 函数的第一个参数（日志内容）
#
# 使用示例：
#   log_info "测试开始"
#   输出：[INFO] 测试开始 （绿色）
# ---------------------------------------------------------------------------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# ---------------------------------------------------------------------------
# log_warn: 输出警告级别的日志
# ---------------------------------------------------------------------------
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# ---------------------------------------------------------------------------
# log_error: 输出错误级别的日志
# ---------------------------------------------------------------------------
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# 检查函数定义
# ============================================================================

# ---------------------------------------------------------------------------
# check_root: 检查是否以 root 权限运行
# 
# 语法解释：
#   $EUID - 当前用户的有效用户 ID
#   -ne   - 不等于
#   0     - root 用户的 UID
#
# 为什么需要 root 权限？
#   perf、ftrace 等工具需要访问内核调试接口，需要 root 权限。
# ---------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

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
    command -v sockperf >/dev/null 2>&1 || missing+=("sockperf")
    
    # 如果有缺失的工具，打印错误信息并退出
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖工具: ${missing[*]}"
        log_info "安装方法:"
        log_info "  perf:     yum install perf 或 apt install linux-tools-common"
        log_info "  qperf:    yum install qperf 或 apt install qperf"
        log_info "  sockperf: 编译安装 https://github.com/Mellanox/sockperf"
        exit 1
    fi
}

# ============================================================================
# 测试函数定义
# ============================================================================

# ---------------------------------------------------------------------------
# run_latency_test: 运行延迟测试
# 
# 参数：
#   $1 - msg_size: 消息大小（字节）
#   $2 - use_shmipc: 是否使用 shmipc (true/false)
#
# 语法解释：
#   local msg_size=$1       - 将第一个参数赋值给局部变量
#   $([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")
#     - 这是一个命令替换，根据 use_shmipc 的值选择输出 "shmipc" 或 "socket"
#     - 用于生成不同的日志文件名
# ---------------------------------------------------------------------------
run_latency_test() {
    local msg_size=$1
    local use_shmipc=$2
    
    # 生成日志文件名
    # 示例：latency_65536_shmipc_20240115_143025.log
    local log_file="$LOG_DIR/latency_${msg_size}_$([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")_${DATE_STR}.log"
    
    log_info "运行延迟测试: msg_size=$msg_size, shmipc=$use_shmipc"
    
    # 启动 qperf 服务器
    # & 符号表示在后台运行
    # LD_PRELOAD 环境变量用于预加载共享库
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    else
        qperf &
    fi
    local server_pid=$!
    
    # 等待服务器启动
    # sleep 2 表示等待 2 秒
    sleep 2
    
    # 运行 qperf 客户端
    # 参数说明：
    #   127.0.0.1  - 连接本地服务器
    #   -m $msg_size - 设置消息大小
    #   -t 10      - 测试时长 10 秒
    #   tcp_lat    - 测试 TCP 延迟
    # 2>&1        - 将标准错误重定向到标准输出
    # | tee "$log_file" - 同时输出到终端和文件
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t 10 tcp_lat 2>&1 | tee "$log_file"
    else
        qperf 127.0.0.1 -m $msg_size -t 10 tcp_lat 2>&1 | tee "$log_file"
    fi
    
    # 停止服务器
    # 2>/dev/null - 将错误输出丢弃（如果进程已结束，kill 会报错）
    # || true      - 即使 kill 失败也继续执行（防止 set -e 导致脚本退出）
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    log_info "结果保存到: $log_file"
}

# ---------------------------------------------------------------------------
# run_bandwidth_test: 运行带宽测试
# 
# 与 run_latency_test 类似，但测试的是带宽（tcp_bw）而不是延迟（tcp_lat）
# ---------------------------------------------------------------------------
run_bandwidth_test() {
    local msg_size=$1
    local use_shmipc=$2
    local log_file="$LOG_DIR/bandwidth_${msg_size}_$([ "$use_shmipc" = "true" ] && echo "shmipc" || echo "socket")_${DATE_STR}.log"
    
    log_info "运行带宽测试: msg_size=$msg_size, shmipc=$use_shmipc"
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
    else
        qperf &
    fi
    local server_pid=$!
    sleep 2
    
    if [[ "$use_shmipc" = "true" ]]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    else
        qperf 127.0.0.1 -m $msg_size -t 10 tcp_bw 2>&1 | tee "$log_file"
    fi
    
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    log_info "结果保存到: $log_file"
}

# ---------------------------------------------------------------------------
# run_perf_analysis: 运行 perf 分析
# 
# 参数：
#   $1 - pid: 要分析的进程 ID
#
# perf 参数说明：
#   record   - 记录采样数据
#   -g       - 记录调用栈
#   -o       - 指定输出文件
#   -p $pid  - 指定要分析的进程
#   -- sleep 5 - 采样 5 秒
# ---------------------------------------------------------------------------
run_perf_analysis() {
    local pid=$1
    local output_file="$LOG_DIR/perf_${pid}_${DATE_STR}.data"
    
    log_info "运行 perf 分析: pid=$pid"
    
    # 运行 perf 记录
    # 2>/dev/null - 丢弃错误输出
    # || true     - 即使失败也继续
    perf record -g -o "$output_file" -p $pid -- sleep 5 2>/dev/null || true
    
    log_info "perf 数据保存到: $output_file"
    log_info "查看报告: perf report -i $output_file"
}

# ---------------------------------------------------------------------------
# run_strace_analysis: 运行 strace 分析
# 
# strace 参数说明：
#   -T       - 显示系统调用耗时
#   -tt      - 显示微秒级时间戳
#   -f       - 追踪子进程
#   -o       - 指定输出文件
# ---------------------------------------------------------------------------
run_strace_analysis() {
    local cmd=$1
    local output_file="$LOG_DIR/strace_${DATE_STR}.log"
    
    log_info "运行 strace 分析: $cmd"
    
    strace -T -tt -f -o "$output_file" $cmd &
    local strace_pid=$!
    
    sleep 10
    kill $strace_pid 2>/dev/null || true
    
    log_info "strace 日志保存到: $output_file"
}

# ---------------------------------------------------------------------------
# run_comparison_test: 运行对比测试
# 
# 这是推荐的测试方式，会自动测试多种消息大小，并生成对比报告
# ---------------------------------------------------------------------------
run_comparison_test() {
    # 定义要测试的消息大小数组
    # 语法：array=(element1 element2 ...)
    # 这些大小分别是：1KB, 8KB, 64KB, 256KB, 1MB
    local msg_sizes=(1024 8192 65536 262144 1048576)
    
    # 创建 CSV 文件并写入表头
    local summary_file="$LOG_DIR/comparison_${DATE_STR}.csv"
    echo "msg_size,socket_latency_us,shmipc_latency_us,latency_improvement,socket_bandwidth_GBps,shmipc_bandwidth_GBps,bandwidth_improvement" > "$summary_file"
    
    # 遍历所有消息大小
    # 语法：for var in "${array[@]}" - 遍历数组所有元素
    for msg_size in "${msg_sizes[@]}"; do
        log_info "测试消息大小: $msg_size bytes"
        
        # 定义各个日志文件路径
        local socket_lat_file="$LOG_DIR/latency_${msg_size}_socket_${DATE_STR}.log"
        local shmipc_lat_file="$LOG_DIR/latency_${msg_size}_shmipc_${DATE_STR}.log"
        local socket_bw_file="$LOG_DIR/bandwidth_${msg_size}_socket_${DATE_STR}.log"
        local shmipc_bw_file="$LOG_DIR/bandwidth_${msg_size}_shmipc_${DATE_STR}.log"
        
        # 运行测试
        run_latency_test $msg_size false
        run_latency_test $msg_size true
        run_bandwidth_test $msg_size false
        run_bandwidth_test $msg_size true
        
        # 从日志文件中提取结果
        # grep "tcp_lat" - 查找包含 tcp_lat 的行
        # awk '{print $3}' - 提取第三列（延迟值）
        # head -1 - 只取第一行
        # || echo "N/A" - 如果失败，输出 N/A
        local socket_lat=$(grep "tcp_lat" "$socket_lat_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        local shmipc_lat=$(grep "tcp_lat" "$shmipc_lat_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        local socket_bw=$(grep "tcp_bw" "$socket_bw_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        local shmipc_bw=$(grep "tcp_bw" "$shmipc_bw_file" 2>/dev/null | awk '{print $3}' | head -1 || echo "N/A")
        
        # 计算提升百分比
        local lat_imp="N/A"
        local bw_imp="N/A"
        
        # bc 是一个计算器，用于浮点运算
        # scale=2 表示保留两位小数
        if [[ "$socket_lat" != "N/A" && "$shmipc_lat" != "N/A" ]]; then
            lat_imp=$(echo "scale=2; ($socket_lat - $shmipc_lat) / $socket_lat * 100" | bc 2>/dev/null || echo "N/A")
        fi
        
        if [[ "$socket_bw" != "N/A" && "$shmipc_bw" != "N/A" ]]; then
            bw_imp=$(echo "scale=2; ($shmipc_bw - $socket_bw) / $socket_bw * 100" | bc 2>/dev/null || echo "N/A")
        fi
        
        # 将结果写入 CSV 文件
        echo "$msg_size,$socket_lat,$shmipc_lat,$lat_imp,$socket_bw,$shmipc_bw,$bw_imp" >> "$summary_file"
        
        sleep 5
    done
    
    log_info "对比结果保存到: $summary_file"
    cat "$summary_file"
}

# ---------------------------------------------------------------------------
# print_usage: 打印使用帮助
# ---------------------------------------------------------------------------
print_usage() {
    echo "shmipc-preload 性能分析脚本"
    echo ""
    echo "使用方法:"
    echo "  $0 latency [msg_size]           # 延迟测试"
    echo "  $0 bandwidth [msg_size]         # 带宽测试"
    echo "  $0 comparison                   # 对比测试（推荐）"
    echo "  $0 perf <pid>                   # perf 分析"
    echo "  $0 strace <command>             # strace 分析"
    echo ""
    echo "示例:"
    echo "  $0 latency 65536"
    echo "  $0 bandwidth 1048576"
    echo "  $0 comparison"
    echo "  $0 perf 12345"
    echo "  $0 strace 'qperf 127.0.0.1 tcp_lat'"
}

# ============================================================================
# 主函数
# ============================================================================
# 
# main 函数是脚本的入口点
# $1 表示脚本的第一个参数
# ${1:-"help"} 表示如果 $1 未设置，则使用默认值 "help"
# ---------------------------------------------------------------------------
main() {
    local test_type=${1:-"help"}
    
    # case 语句：类似于其他语言的 switch
    # 语法：case $var in pattern) commands ;; esac
    case "$test_type" in
        latency)
            # 延迟测试
            # ${2:-65536} 表示如果第二个参数未设置，使用默认值 65536
            local msg_size=${2:-65536}
            check_dependencies
            run_latency_test $msg_size false
            run_latency_test $msg_size true
            ;;
        bandwidth)
            # 带宽测试
            local msg_size=${2:-1048576}
            check_dependencies
            run_bandwidth_test $msg_size false
            run_bandwidth_test $msg_size true
            ;;
        comparison)
            # 对比测试（推荐）
            check_dependencies
            run_comparison_test
            ;;
        perf)
            # perf 分析
            check_root
            local pid=$2
            if [[ -z "$pid" ]]; then
                log_error "请指定进程 PID"
                exit 1
            fi
            run_perf_analysis $pid
            ;;
        strace)
            # strace 分析
            local cmd=$2
            if [[ -z "$cmd" ]]; then
                log_error "请指定要追踪的命令"
                exit 1
            fi
            run_strace_analysis "$cmd"
            ;;
        help|--help|-h)
            # 显示帮助
            print_usage
            ;;
        *)
            # 未知命令
            log_error "未知测试类型: $test_type"
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
# 例如：./perf_analysis.sh latency 65536
# "$@" 就是 "latency" "65536"
# ============================================================================
main "$@"
