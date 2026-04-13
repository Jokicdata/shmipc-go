# shmipc Preload 全链路性能分析教程

本文档提供三种方式，完整追踪 qperf 从启动到结束的全过程调用及耗时占比：
1. **ltrace** — 追踪用户态动态库函数调用（write/send/recv/ShmipcWrite 等）
2. **perf + 火焰图** — 追踪用户态+内核态，生成可视化火焰图
3. **shmipc 内置追踪** — 在代码内部打点，精确到 Reserve/memcpy/Flush 各阶段

---

## 目录

1. [环境准备](#1-环境准备)
2. [方式一：ltrace 追踪用户态函数](#2-方式一ltrace-追踪用户态函数)
3. [方式二：perf + 火焰图](#3-方式二perf--火焰图)
4. [方式三：shmipc 内置追踪](#4-方式三shmipc-内置追踪)
5. [对比实验：劫持 vs 非劫持](#5-对比实验劫持-vs-非劫持)
6. [预期结果](#6-预期结果)

---

## 1. 环境准备

### 1.1 安装工具

```bash
# Ubuntu/Debian
sudo apt-get install -y ltrace perf-tools-unstable linux-tools-common linux-tools-generic

# CentOS/RHEL
sudo yum install -y ltrace perf

# 下载 FlameGraph（生成火焰图用，一次性）
cd ~
git clone --depth 1 https://github.com/brendangregg/FlameGraph.git
```

### 1.2 编译 shmipc（三个版本）

```bash
cd /path/to/shmipc-go/shmipc-preload

# 基础版
make clean && make

# 优化版
make opt

# 追踪版
make -f Makefile.trace
```

编译成功后应有以下文件：
```
libshmipc.so           # 基础版
libshmipc_opt.so       # 优化版
libshmipc_trace.so     # 追踪版
```

### 1.3 检查权限

```bash
# perf 权限
cat /proc/sys/kernel/perf_event_paranoid
# 如果 > 1，需要设置：
sudo sysctl -w kernel.perf_event_paranoid=1

# ltrace 一般不需要 root
ltrace --version
```

---

## 2. 方式一：ltrace 追踪用户态函数

ltrace 可以追踪进程调用的动态库函数，包括 write/send/recv 以及 shmipc 的 CGO 导出函数。

### 2.1 追踪服务端（非劫持）

```bash
# Terminal 1: 启动 qperf 服务端（不用 ltrace，正常启动）
qperf

# Terminal 2: 用 ltrace 追踪客户端
ltrace -T -e 'write+read+send+recv+sendto+recvfrom' \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw 2>&1 | tee /tmp/ltrace_normal.log
```

参数说明：
- `-T`：显示每个函数调用耗时（微秒）
- `-e 'write+read+send+recv+sendto+recvfrom'`：只追踪这些函数
- `-t 10`：测试 10 秒（短一点方便追踪）

### 2.2 追踪客户端（preload 劫持）

```bash
# Terminal 1: 启动 qperf 服务端（带 preload）
LD_PRELOAD=./libshmipc_opt.so qperf

# Terminal 2: 用 ltrace 追踪客户端（带 preload）
ltrace -T -e 'write+read+send+recv+ShmipcWrite+ShmipcRead+ShmipcFlush' \
    LD_PRELOAD=./libshmipc_opt.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw 2>&1 | tee /tmp/ltrace_preload.log
```

### 2.3 追踪完整函数调用（不限过滤）

```bash
# 不加 -e 过滤，追踪所有动态库调用（输出会很多，只跑短时间）
ltrace -T -c \
    LD_PRELOAD=./libshmipc_opt.so \
    qperf 127.0.0.1 -msg_size 524288 -t 5 tcp_bw 2>&1 | tee /tmp/ltrace_full.log
```

`-c` 参数会输出统计摘要，按调用次数和时间排序。

### 2.4 查看 ltrace 结果

```bash
# 查看原始输出
head -50 /tmp/ltrace_normal.log

# 查看统计摘要（-c 模式）
cat /tmp/ltrace_full.log | tail -30

# 对比两个版本
diff /tmp/ltrace_normal.log /tmp/ltrace_preload.log | head -50
```

### 2.5 ltrace 注意事项

- ltrace **无法追踪 Go 函数内部的调用**（Go 不使用 glibc 调用约定）
- ltrace **无法追踪内核函数**（那是 ftrace/perf 的领域）
- ltrace 只能看到 C 层的 `write()`/`send()`/`ShmipcWrite()` 等函数
- ltrace 会显著降低程序性能（约 2-10 倍），不要用于精确性能测试

---

## 3. 方式二：perf + 火焰图

perf 可以同时追踪用户态和内核态，是最全面的性能分析工具。

### 3.1 非劫持路径

```bash
# ===== Terminal 1: 启动 qperf 服务端 =====
qperf

# ===== Terminal 2: 启动 perf record =====
mkdir -p ~/shmipc_perf
cd ~/shmipc_perf
sudo perf record -F 999 -a -g -o perf_normal.data -- sleep 15

# ===== Terminal 3: 启动 qperf 客户端 =====
qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat
```

等待 15 秒后 perf 自动停止。

### 3.2 劫持路径

```bash
# ===== Terminal 1: 启动 qperf 服务端 =====
LD_PRELOAD=./libshmipc_opt.so qperf

# ===== Terminal 2: 启动 perf record =====
mkdir -p ~/shmipc_perf
cd ~/shmipc_perf
sudo perf record -F 999 -a -g -o perf_preload.data -- sleep 15

# ===== Terminal 3: 启动 qperf 客户端 =====
LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat
```

### 3.3 生成火焰图

```bash
cd ~/shmipc_perf

# 非劫持版本
sudo perf script -i perf_normal.data > perf_normal.perf
~/FlameGraph/stackcollapse-perf.pl perf_normal.perf > perf_normal.folded
~/FlameGraph/flamegraph.pl --title "Normal TCP" --colors=java perf_normal.folded > normal.svg

# 劫持版本
sudo perf script -i perf_preload.data > perf_preload.perf
~/FlameGraph/stackcollapse-perf.pl perf_preload.perf > perf_preload.folded
~/FlameGraph/flamegraph.pl --title "Preload SHM" --colors=java perf_preload.folded > preload.svg

# 生成对比火焰图（红蓝对比）
~/FlameGraph/difffolded.pl perf_normal.folded perf_preload.folded > diff.folded
~/FlameGraph/flamegraph.pl --title "Normal vs Preload" --colors=java diff.folded > diff.svg
```

### 3.4 查看文本报告（不用火焰图）

```bash
cd ~/shmipc_perf

# 非劫持：Top 函数
sudo perf report --stdio -g none -i perf_normal.data | head -60

# 劫持：Top 函数
sudo perf report --stdio -g none -i perf_preload.data | head -60

# 劫持：带调用关系
sudo perf report --stdio -g graph -i perf_preload.data | head -80

# 只看 ShmipcWrite 相关
sudo perf report --stdio -g graph -i perf_preload.data | grep -A 20 "ShmipcWrite"

# 只看 memcpy/memmove 相关
sudo perf report --stdio -g graph -i perf_preload.data | grep -A 10 "memmove\|memcpy"
```

### 3.5 perf 采样特定进程

如果系统上还有其他负载，可以只追踪 qperf 进程：

```bash
# 先启动 qperf server，获取 PID
LD_PRELOAD=./libshmipc_opt.so qperf &
SERVER_PID=$!

# 追踪特定 PID
sudo perf record -F 999 -g -p $SERVER_PID -o perf_server.data -- sleep 15

# 启动客户端
LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw
```

### 3.6 perf 注意事项

- `-F 999`：采样频率 999Hz，越高越精确但开销越大
- `-a`：追踪所有 CPU（不加则只追踪当前 CPU）
- `-g`：记录调用栈
- 需要 root 权限或设置 `perf_event_paranoid=1`
- 火焰图中 Go 函数名可能显示为 `runtime.*`，需要带调试符号编译

---

## 4. 方式三：shmipc 内置追踪

这是最精确的方式，直接在代码内部打点，记录 Reserve/memcpy/Flush 各阶段耗时。

### 4.1 编译追踪版

```bash
cd /path/to/shmipc-go/shmipc-preload
make -f Makefile.trace
```

### 4.2 运行追踪

```bash
# ===== Terminal 1: 启动 qperf 服务端（带追踪）=====
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf

# ===== Terminal 2: 启动 qperf 客户端（带追踪）=====
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat
```

### 4.3 查看追踪日志

```bash
# 实时查看
tail -f /tmp/shmipc_trace.log

# 只看 WRITE
grep "WRITE" /tmp/shmipc_trace.log | head -20

# 只看 READ
grep "READ" /tmp/shmipc_trace.log | head -20

# 只看连接建立
grep -E "INIT|CLIENT_CONN|SERVER_CONN|OPEN_STREAM|ACCEPT_STREAM" /tmp/shmipc_trace.log
```

### 4.4 分析追踪日志

```bash
# 提取 WRITE 各阶段耗时
grep "WRITE" /tmp/shmipc_trace.log | \
    awk -F't_reduce=' '{print $2}' | \
    awk -F' ' '{print $1}' | \
    awk '{sum+=$1; count++} END {print "Reserve avg:", sum/count, "ms"}'

grep "WRITE" /tmp/shmipc_trace.log | \
    awk -F't_copy=' '{print $2}' | \
    awk -F' ' '{print $1}' | \
    awk '{sum+=$1; count++} END {print "Memcpy avg:", sum/count, "ms"}'

grep "WRITE" /tmp/shmipc_trace.log | \
    awk -F't_flush=' '{print $2}' | \
    awk -F' ' '{print $1}' | \
    awk '{sum+=$1; count++} END {print "Flush avg:", sum/count, "ms"}'

grep "WRITE" /tmp/shmipc_trace.log | \
    awk -F't_total=' '{print $2}' | \
    awk -F' ' '{print $1}' | \
    awk '{sum+=$1; count++} END {print "Total avg:", sum/count, "ms"}'
```

### 4.5 一键分析脚本

将以下内容保存为 `analyze_trace.sh`：

```bash
#!/bin/bash
LOG=/tmp/shmipc_trace.log

if [ ! -f "$LOG" ]; then
    echo "Trace log not found: $LOG"
    echo "Run with: SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf ..."
    exit 1
fi

echo "=========================================="
echo "  shmipc Trace Analysis Report"
echo "=========================================="
echo ""

echo "--- Connection Events ---"
grep -E "INIT|CLIENT_CONN|SERVER_CONN|OPEN_STREAM|ACCEPT_STREAM|CLOSE" "$LOG" | head -20
echo ""

echo "--- WRITE Statistics ---"
write_count=$(grep -c "WRITE" "$LOG")
echo "Total WRITE calls: $write_count"

if [ "$write_count" -gt 0 ]; then
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

    echo ""
    echo "  Per-stage percentage:"
    reserve_avg=$(grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    copy_avg=$(grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    flush_avg=$(grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    total_avg=$(grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

    if [ "$(echo "$total_avg > 0" | bc -l)" = "1" ]; then
        printf "    Reserve: %.1f%%\n" "$(echo "$reserve_avg / $total_avg * 100" | bc -l)"
        printf "    Memcpy:  %.1f%%\n" "$(echo "$copy_avg / $total_avg * 100" | bc -l)"
        printf "    Flush:   %.1f%%\n" "$(echo "$flush_avg / $total_avg * 100" | bc -l)"
    fi

    echo ""
    echo "  Data size distribution:"
    grep "WRITE" "$LOG" | awk -F'size=' '{split($2,a," "); print a[1]}' | \
        sort -n | uniq -c | sort -rn | head -10
fi

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

    if [ "$(echo "$rtotal_avg > 0" | bc -l)" = "1" ]; then
        printf "    Read:    %.1f%%\n" "$(echo "$read_avg / $rtotal_avg * 100" | bc -l)"
        printf "    Memcpy:  %.1f%%\n" "$(echo "$rcopy_avg / $rtotal_avg * 100" | bc -l)"
        printf "    Release: %.1f%%\n" "$(echo "$release_avg / $rtotal_avg * 100" | bc -l)"
    fi
fi

echo ""
echo "=========================================="
```

使用方式：

```bash
chmod +x analyze_trace.sh
./analyze_trace.sh
```

---

## 5. 对比实验：劫持 vs 非劫持

### 5.1 完整对比流程

```bash
cd /path/to/shmipc-go/shmipc-preload
mkdir -p ~/shmipc_compare

# ===== 实验1：正常 TCP =====
# Terminal 1
qperf &
sleep 2

# Terminal 2
sudo perf record -F 999 -a -g -o ~/shmipc_compare/normal.data -- sleep 15 &

# Terminal 3
qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat 2>&1 | tee ~/shmipc_compare/normal_result.txt

# 等待 perf 结束
wait

# ===== 实验2：preload 劫持 =====
# Terminal 1
LD_PRELOAD=./libshmipc_opt.so qperf &
sleep 2

# Terminal 2
sudo perf record -F 999 -a -g -o ~/shmipc_compare/preload.data -- sleep 15 &

# Terminal 3
LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat 2>&1 | tee ~/shmipc_compare/preload_result.txt

# 等待 perf 结束
wait

# ===== 实验3：preload + 内置追踪 =====
# Terminal 1
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf &
sleep 2

# Terminal 2
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat 2>&1 | tee ~/shmipc_compare/trace_result.txt

# 查看追踪日志
cp /tmp/shmipc_trace.log ~/shmipc_compare/trace.log

# ===== 生成火焰图 =====
cd ~/shmipc_compare

sudo perf script -i normal.data > normal.perf
~/FlameGraph/stackcollapse-perf.pl normal.perf > normal.folded
~/FlameGraph/flamegraph.pl --title "Normal TCP" --colors=java normal.folded > normal.svg

sudo perf script -i preload.data > preload.perf
~/FlameGraph/stackcollapse-perf.pl preload.perf > preload.folded
~/FlameGraph/flamegraph.pl --title "Preload SHM" --colors=java preload.folded > preload.svg

# 对比火焰图
~/FlameGraph/difffolded.pl normal.folded preload.folded > diff.folded
~/FlameGraph/flamegraph.pl --title "Normal vs Preload" diff.folded > diff.svg
```

### 5.2 小消息 vs 大消息对比

```bash
# 小消息 (1KB)
qperf 127.0.0.1 -msg_size 1024 -t 10 tcp_lat

# 中等消息 (64KB)
qperf 127.0.0.1 -msg_size 65536 -t 10 tcp_bw tcp_lat

# 大消息 (512KB)
qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat

# 超大消息 (1MB)
qperf 127.0.0.1 -msg_size 1048576 -t 10 tcp_bw tcp_lat
```

---

## 6. 预期结果

### 6.1 ltrace 预期输出

**非劫持路径**：
```
write(3, "AAAA...", 524288) = 524288 <0.350>
recv(3, "AAAA...", 524288) = 524288 <0.280>
write(3, "AAAA...", 524288) = 524288 <0.340>
recv(3, "AAAA...", 524288) = 524288 <0.270>
...
```
- 只看到 `write`/`recv` 系统调用
- 每次调用耗时约 0.2-0.5ms

**劫持路径**：
```
ShmipcWrite(1, 0x7f..., 524288) = 524288 <0.180>
ShmipcRead(1, 0x7f..., 524288) = 524288 <0.150>
ShmipcWrite(1, 0x7f..., 524288) = 524288 <0.170>
ShmipcRead(1, 0x7f..., 524288) = 524288 <0.140>
...
```
- 看到 `ShmipcWrite`/`ShmipcRead` 替代了 `write`/`recv`
- 不走内核系统调用（ltrace 看不到内核函数）

### 6.2 perf 火焰图预期

**非劫持路径火焰图**：
```
                    ┌─────────────────────────────────┐
                    │         tcp_sendmsg              │  ← 内核 TCP 发送（最宽 = 热点）
                    └─────────────────────────────────┘
              ┌───────────┐   ┌───────────────────────┐
              │copy_from_  │   │    tcp_recvmsg        │  ← 内核 TCP 接收
              │user        │   └───────────────────────┘
              └───────────┘
        ┌─────┐  ┌──────┐
        │write│  │ recv  │  ← 系统调用入口
        └─────┘  └──────┘
```

**劫持路径火焰图**：
```
                    ┌─────────────────────────────────┐
                    │      runtime.memmove             │  ← memcpy（qperf buf → SHM）
                    └─────────────────────────────────┘
              ┌───────────┐   ┌───────────────────────┐
              │ShmipcWrite│   │    ShmipcRead          │  ← CGO 函数
              └───────────┘   └───────────────────────┘
        ┌─────┐  ┌──────┐
        │write│  │ recv  │  ← preload 劫持入口
        └─────┘  └──────┘
```

**关键差异**：
| 对比项 | 非劫持 | 劫持 |
|--------|--------|------|
| 最宽的顶层函数 | `tcp_sendmsg` | `runtime.memmove` |
| 是否有 `ShmipcWrite` | 无 | 有 |
| 是否有 `tcp_sendmsg` | 有 | 无（如果完全劫持） |
| `copy_from_user` | 有（内核拷贝） | 无 |
| `runtime.memmove` | 无 | 有（用户态拷贝） |

### 6.3 shmipc 内置追踪预期输出

**追踪日志原始输出**：
```
[1700000000.123456] === shmipc Trace Started === PID=12345
[1700000000.234567] INIT
[1700000000.345678] CLIENT_CONN fd=3 path=
[1700000000.456789] OPEN_STREAM fd=3 sid=1
[1700000001.000001] WRITE sid=1 size=524288 t_reduce=0.012 t_copy=0.085 t_flush=0.025 t_total=0.135
[1700000001.000150] WRITE sid=1 size=524288 t_reduce=0.008 t_copy=0.078 t_flush=0.020 t_total=0.118
[1700000001.000300] READ sid=1 size=524288 copied=524288 t_read=0.015 t_copy=0.080 t_release=0.005 t_total=0.110
[1700000001.000450] WRITE sid=1 size=524288 t_reduce=0.010 t_copy=0.082 t_flush=0.022 t_total=0.125
...
```

**分析脚本预期输出**：
```
==========================================
  shmipc Trace Analysis Report
==========================================

--- Connection Events ---
[1700000000.123456] === shmipc Trace Started === PID=12345
[1700000000.234567] INIT
[1700000000.345678] CLIENT_CONN fd=3 path=
[1700000000.456789] OPEN_STREAM fd=3 sid=1

--- WRITE Statistics ---
Total WRITE calls: 15000

  Per-stage average (ms):
    Reserve (get shm buffer): 0.0100
    Memcpy  (data -> shm):   0.0800
    Flush   (notify peer):   0.0220
    Total:                  0.1200

  Per-stage percentage:
    Reserve: 8.3%
    Memcpy:  66.7%
    Flush:   18.3%

  Data size distribution:
    15000 524288

--- READ Statistics ---
Total READ calls: 15000

  Per-stage average (ms):
    Read    (from shm):       0.0150
    Memcpy  (shm -> buf):     0.0780
    Release (recycle buf):    0.0050
    Total:                    0.1050

  Per-stage percentage:
    Read:    14.3%
    Memcpy:  74.3%
    Release: 4.8%

==========================================
```

### 6.4 不同消息大小的预期耗时占比

**小消息 (1KB)**：
```
WRITE 阶段占比:
  Reserve:  25%  ← CGO 开销占比大
  Memcpy:   30%  ← 数据小，拷贝快
  Flush:    35%  ← 通知开销相对固定
  其他:     10%  ← 锁、查找等

READ 阶段占比:
  Read:     30%
  Memcpy:   25%
  Release:  15%
  其他:     30%
```

**大消息 (512KB)**：
```
WRITE 阶段占比:
  Reserve:   5%  ← CGO 开销占比小
  Memcpy:   75%  ← 数据大，拷贝是主要开销 ★
  Flush:    15%  ← 通知开销
  其他:      5%

READ 阶段占比:
  Read:     10%
  Memcpy:   80%  ← 数据大，拷贝是主要开销 ★
  Release:   3%
  其他:      7%
```

**超大消息 (1MB)**：
```
WRITE 阶段占比:
  Reserve:   2%
  Memcpy:   85%  ← 拷贝绝对主导 ★★★
  Flush:    10%
  其他:      3%
```

### 6.5 预期结论

1. **小消息**：CGO 调用开销（Reserve + Flush）占比大，memcpy 占比小，preload 可能提升性能
2. **大消息**：memcpy 占比绝对主导（75%+），这是无法避免的拷贝，preload 方案反而可能因为 CGO 开销导致劣化
3. **核心瓶颈**：大消息场景下，`copy(reserved, data[:n])` 这行代码消耗了 75%+ 的时间
4. **优化方向**：如果要改善大消息性能，必须减少 memcpy 次数或让应用直接写入共享内存

---

## 附录：快速命令参考

```bash
# ===== ltrace 快速 =====
ltrace -T -c LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 -msg_size 524288 -t 5 tcp_bw

# ===== perf 快速 =====
sudo perf record -F 999 -a -g -- sleep 15
sudo perf report --stdio -g none | head -60

# ===== 火焰图快速 =====
sudo perf script | ~/FlameGraph/stackcollapse-perf.pl | ~/FlameGraph/flamegraph.pl > out.svg

# ===== 内置追踪快速 =====
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw
grep "WRITE" /tmp/shmipc_trace.log | head -20
```
