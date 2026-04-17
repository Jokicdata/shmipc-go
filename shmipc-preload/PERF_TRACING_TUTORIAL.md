# shmipc Preload 全链路性能分析教程

本文档提供一键脚本和手动方式，完整追踪 qperf 从启动到结束的全过程调用及耗时占比。

---

## 目录

1. [一键脚本（推荐）](#1-一键脚本推荐)
2. [手动操作](#2-手动操作)
3. [脚本输出结果示例](#3-脚本输出结果示例)
4. [预期结果解读](#4-预期结果解读)

---

## 1. 一键脚本（推荐）

### 1.1 脚本清单

| 脚本 | 功能 | 输出 |
|------|------|------|
| `run_flamegraph.sh` | 一键生成火焰图 | SVG 火焰图 + 文本报告 |
| `run_trace.sh` | 一键全链路追踪 | shmipc/strace/ltrace/perf 综合报告 |
| `analyze_trace.sh` | 分析 shmipc 内置追踪日志 | 各阶段耗时占比 |

### 1.2 run_flamegraph.sh — 一键火焰图

```bash
# 给脚本执行权限
chmod +x run_flamegraph.sh

# 默认：preload 模式，512KB 消息
sudo ./run_flamegraph.sh

# 正常 TCP 模式
sudo ./run_flamegraph.sh --normal

# 两种都跑，生成对比火焰图
sudo ./run_flamegraph.sh --compare

# 自定义消息大小
sudo ./run_flamegraph.sh --msg-size 1024     # 1KB
sudo ./run_flamegraph.sh --msg-size 65536    # 64KB
sudo ./run_flamegraph.sh --msg-size 524288   # 512KB

# 自定义采样时长
sudo ./run_flamegraph.sh --duration 30
```

**输出文件**（在 `flamegraph_output_YYYYMMDD_HHMMSS/` 目录下）：
- `normal.svg` — 正常 TCP 火焰图
- `preload.svg` — preload 劫持火焰图
- `diff.svg` — 对比火焰图（红色=preload 更慢，蓝色=更快）
- `normal_report.txt` / `preload_report.txt` — perf 文本报告
- `*_qperf_result.txt` — qperf 测试结果

### 1.3 run_trace.sh — 一键全链路追踪

```bash
# 给脚本执行权限
chmod +x run_trace.sh

# 默认：preload 模式，512KB，使用所有追踪工具
sudo ./run_trace.sh

# 正常 TCP 模式
sudo ./run_trace.sh --normal

# 只用 shmipc 内置追踪 + strace
sudo ./run_trace.sh --tools shmipc,strace

# 只用 shmipc 内置追踪（最精确，开销最小）
sudo ./run_trace.sh --tools shmipc

# 自定义消息大小
sudo ./run_trace.sh --msg-size 1024
```

**输出文件**（在 `trace_output_YYYYMMDD_HHMMSS/` 目录下）：
- `shmipc_trace.log` — shmipc 内置追踪日志（Reserve/memcpy/Flush 各阶段耗时）
- `strace_client.log` — 客户端系统调用追踪
- `ltrace_client.log` — 客户端动态库函数追踪
- `perf_stat.log` — 性能计数器
- `qperf_result.txt` — qperf 测试结果
- `trace_report.txt` — 汇总分析报告（最重要！）

### 1.4 analyze_trace.sh — 分析追踪日志

```bash
# 先运行追踪版 qperf 生成日志
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf &
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw

# 然后分析
chmod +x analyze_trace.sh
./analyze_trace.sh
```

---

## 2. 手动操作

### 2.1 环境准备

```bash
# 安装工具
sudo apt-get install -y ltrace strace perf-tools-unstable linux-tools-common linux-tools-generic

# 下载 FlameGraph
git clone --depth 1 https://github.com/brendangregg/FlameGraph.git ~/FlameGraph

# 编译 shmipc
cd /path/to/shmipc-go/shmipc-preload
make opt              # 优化版
make -f Makefile.trace  # 追踪版

# 设置 perf 权限
sudo sysctl -w kernel.perf_event_paranoid=1
```

### 2.2 shmipc 内置追踪（手动）

```bash
# 服务端
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf

# 客户端
SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat

# 查看日志
tail -f /tmp/shmipc_trace.log
```

### 2.3 strace 追踪系统调用（手动）

```bash
# 服务端
LD_PRELOAD=./libshmipc_opt.so qperf

# 客户端（带 strace）
strace -T -tt -o /tmp/strace_client.log \
    -e trace=write,read,send,recv,epoll_wait,socket,connect \
    LD_PRELOAD=./libshmipc_opt.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw

# 分析
grep 'write(' /tmp/strace_client.log | head -20
```

### 2.4 ltrace 追踪动态库函数（手动）

```bash
# 服务端
LD_PRELOAD=./libshmipc_opt.so qperf

# 客户端（带 ltrace）
ltrace -T -tt -o /tmp/ltrace_client.log \
    -e write+read+send+recv+ShmipcWrite+ShmipcRead \
    LD_PRELOAD=./libshmipc_opt.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw

# 分析
grep 'ShmipcWrite' /tmp/ltrace_client.log | head -20
```

### 2.5 perf 火焰图（手动）

```bash
# 服务端
LD_PRELOAD=./libshmipc_opt.so qperf &

# perf record
sudo perf record -F 999 -a -g -- sleep 15

# 客户端
LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw tcp_lat

# 生成火焰图
sudo perf script | ~/FlameGraph/stackcollapse-perf.pl | ~/FlameGraph/flamegraph.pl > out.svg
```

---

## 3. 脚本输出结果示例

### 3.1 run_trace.sh 输出示例

```
==========================================
  shmipc Full Trace Analysis
==========================================

Mode:       preload
Msg size:   524288 bytes (512 KB)
Duration:   15 seconds
Tools:      shmipc,strace,ltrace,perf
Output:     /path/to/trace_output_20260417_143022

[1/5] Building shmipc...
  Built: libshmipc_trace.so
  Built: libshmipc_opt.so

[2/5] Starting qperf server...
  Server PID: 23456

[3/5] Starting qperf client with tracing...
  strace: ON -> strace_client.log
  ltrace: ON -> ltrace_client.log
  Client PID: 23499

[4/5] Waiting for test to complete (up to 15s)...
  Client finished.
  perf stat finished.
  shmipc trace captured.
  strace server captured.

[5/5] Generating analysis report...

==========================================
  Results
==========================================

==========================================
  shmipc Full Trace Analysis Report
==========================================

Test config:
  Mode:       preload
  Msg size:   524288 bytes (512 KB)
  Duration:   15 seconds
  Timestamp:  20260417_143022

==========================================
  1. qperf Result
==========================================

tcp_bw:
    bw  =  2.5 GB/sec
tcp_lat:
    latency  =  85.2 us

==========================================
  2. shmipc Built-in Trace
==========================================

--- Connection Events ---
[1713340222.123456] === shmipc Trace Started === PID=23499
[1713340222.234567] INIT
[1713340222.345678] CLIENT_CONN fd=3 path=
[1713340222.456789] OPEN_STREAM fd=3 sid=1

--- WRITE Statistics (total: 12500 calls) ---

  Per-stage average (ms):
    Reserve (get shm buffer): 0.0085
    Memcpy  (data -> shm):   0.0780
    Flush   (notify peer):   0.0210
    Total:                  0.1150

  Per-stage percentage:
    Reserve: 7.4%
    Memcpy:  67.8%
    Flush:   18.3%

  Data size distribution:
    12500 524288

--- READ Statistics (total: 12500 calls) ---

  Per-stage average (ms):
    Read    (from shm):       0.0120
    Memcpy  (shm -> buf):     0.0750
    Release (recycle buf):    0.0040
    Total:                    0.0980

  Per-stage percentage:
    Read:    12.2%
    Memcpy:  76.5%
    Release: 4.1%

==========================================
  3. strace Analysis (System Calls)
==========================================

--- Top System Calls by Count ---
   8500 write
   8200 read
   4100 epoll_wait
   2100 send
   2000 recv
    100 socket
     50 connect
     50 close

--- Top System Calls by Total Time ---
    12.543200   4100 epoll_wait
     2.890000   8500 write
     2.650000   8200 read
     0.540000   2100 send
     0.520000   2000 recv

--- write() Call Samples (first 10) ---
14:30:25.123456 write(3, "\0\0\0\0\0\0\0\0"..., 524288) = 524288 <0.000120>
14:30:25.123580 write(3, "\0\0\0\0\0\0\0\0"..., 524288) = 524288 <0.000115>
14:30:25.123700 write(3, "\0\0\0\0\0\0\0\0"..., 524288) = 524288 <0.000118>

--- read() Call Samples (first 10) ---
14:30:25.123900 read(3, "\0\0\0\0\0\0\0\0"..., 524288) = 524288 <0.000098>
14:30:25.124010 read(3, "\0\0\0\0\0\0\0\0"..., 524288) = 524288 <0.000095>

--- epoll_wait Call Samples (first 5) ---
14:30:25.123001 epoll_wait(4, [{EPOLLIN, {u32=3, u64=3}}], 512, -1) = 1 <0.000350>
14:30:25.123400 epoll_wait(4, [{EPOLLIN, {u32=3, u64=3}}], 512, -1) = 1 <0.000280>

==========================================
  4. ltrace Analysis (Library Calls)
==========================================

--- Top Library Calls by Count ---
   8500 write
   8200 read
   4100 __libc_start_main
   2100 ShmipcWrite
   2000 ShmipcRead

--- ShmipcWrite Call Samples (first 10) ---
14:30:25.123456 ShmipcWrite(1, 0x7f0000100000, 524288, 0) = 524288 <0.000115>
14:30:25.123580 ShmipcWrite(1, 0x7f0000100000, 524288, 0) = 524288 <0.000112>

--- ShmipcRead Call Samples (first 10) ---
14:30:25.123900 ShmipcRead(1, 0x7f8800200000, 524288, 0) = 524288 <0.000098>

--- write() Call Samples (first 10) ---
14:30:25.123456 write(3, 0x7f0000100000, 524288) = 524288 <0.000001>
14:30:25.123580 write(3, 0x7f0000100000, 524288) = 524288 <0.000001>

==========================================
  5. perf stat (Performance Counters)
==========================================

 Performance counter stats for 'system wide':

      15,023.45 msec  cpu-clock                 #    1.000 CPUs utilized
         2,345,678  context-switches             #  156.123 /sec
            12,345  cpu-migrations               #    0.821 /sec
         1,234,567  page-faults                  #   82.123 /sec
    45,678,901,234  cycles                       #    3.041 GHz
     8,765,432,100  instructions                 #    0.19  insn per cycle
     2,345,678,900  cache-references             #  156.123 M/sec
       123,456,789  cache-misses                 #    5.26% of all cache refs

       15.023456789 seconds time elapsed

==========================================
  Summary
==========================================

  Output directory: /path/to/trace_output_20260417_143022

  Files:
    shmipc_trace.log                          1234567 bytes
    strace_client.log                          2345678 bytes
    ltrace_client.log                           345678 bytes
    perf_stat.log                                 5678 bytes
    qperf_result.txt                                89 bytes
    trace_report.txt                             56789 bytes
```

### 3.2 run_flamegraph.sh 输出示例

```
==========================================
  shmipc FlameGraph Analysis
==========================================

Mode:       compare
Msg size:   524288 bytes (512 KB)
Duration:   15 seconds
Output:     /path/to/flamegraph_output_20260417_143500

[1/6] Building shmipc optimized version...
  Build OK: libshmipc_opt.so

--- Running: normal mode ---
  Server PID: 24001
  Starting perf record (15s)...
  Starting qperf client (msg_size=524288)...
  Waiting for perf to finish...
  Generating flamegraph...
  Generating text report...
  Done: normal.svg

--- Running: preload mode ---
  Server PID: 24200
  Starting perf record (15s)...
  Starting qperf client (msg_size=524288)...
  Waiting for perf to finish...
  Generating flamegraph...
  Generating text report...
  Done: preload.svg

[3/6] Generating diff flamegraph...
  Done: diff.svg

[4/6] Generating summary report...
[5/6] qperf results:

--- normal_qperf_result.txt ---
tcp_bw:
    bw  =  3.2 GB/sec
tcp_lat:
    latency  =  62.5 us

--- preload_qperf_result.txt ---
tcp_bw:
    bw  =  2.5 GB/sec
tcp_lat:
    latency  =  85.2 us

[6/6] All done!

==========================================
  Results
==========================================

Output directory: /path/to/flamegraph_output_20260417_143500

Files:
    normal.svg                                 456789 bytes
    preload.svg                                567890 bytes
    diff.svg                                   678901 bytes
    normal_report.txt                           12345 bytes
    preload_report.txt                          23456 bytes
    normal_qperf_result.txt                         89 bytes
    preload_qperf_result.txt                        89 bytes
    summary.txt                                  3456 bytes

View flamegraphs:
  /path/to/flamegraph_output_20260417_143500/normal.svg
  /path/to/flamegraph_output_20260417_143500/preload.svg
  /path/to/flamegraph_output_20260417_143500/diff.svg
```

### 3.3 analyze_trace.sh 输出示例

```
==========================================
  shmipc Trace Analysis Report
==========================================

--- Connection Events ---
[1713340222.123456] === shmipc Trace Started === PID=23499
[1713340222.234567] INIT
[1713340222.345678] CLIENT_CONN fd=3 path=
[1713340222.456789] OPEN_STREAM fd=3 sid=1

--- WRITE Statistics ---
Total WRITE calls: 12500

  Per-stage average (ms):
    Reserve (get shm buffer): 0.0085
    Memcpy  (data -> shm):   0.0780
    Flush   (notify peer):   0.0210
    Total:                  0.1150

  Per-stage percentage:
    Reserve: 7.4%
    Memcpy:  67.8%
    Flush:   18.3%

  Data size distribution:
    12500 524288

--- READ Statistics ---
Total READ calls: 12500

  Per-stage average (ms):
    Read    (from shm):       0.0120
    Memcpy  (shm -> buf):     0.0750
    Release (recycle buf):    0.0040
    Total:                    0.0980

  Per-stage percentage:
    Read:    12.2%
    Memcpy:  76.5%
    Release: 4.1%

==========================================
```

---

## 4. 预期结果解读

### 4.1 关键发现

从追踪结果中，你应该能看到：

**WRITE 路径**（qperf → 共享内存）：
```
ShmipcWrite 总耗时 = Reserve(7.4%) + Memcpy(67.8%) + Flush(18.3%)
                                    ↑
                               这是瓶颈！
                     copy(reserved, data[:n])
                     qperf 堆内存 → 共享内存的 memcpy
```

**READ 路径**（共享内存 → qperf）：
```
ShmipcRead 总耗时 = Read(12.2%) + Memcpy(76.5%) + Release(4.1%)
                                      ↑
                                 这是瓶颈！
                       copy(data[:n], buf)
                       共享内存 → qperf 堆内存的 memcpy
```

### 4.2 不同消息大小的预期占比

| 消息大小 | Memcpy 占比(WRITE) | Memcpy 占比(READ) | 说明 |
|----------|-------------------|-------------------|------|
| 1KB | ~30% | ~25% | CGO 开销占比大，memcpy 不是瓶颈 |
| 64KB | ~55% | ~60% | memcpy 开始成为主要开销 |
| 512KB | ~68% | ~77% | memcpy 绝对主导 ★ |
| 1MB | ~80% | ~85% | memcpy 几乎是全部开销 ★★★ |

### 4.3 火焰图解读

**正常 TCP 火焰图**：
- 最宽的顶层函数：`tcp_sendmsg`（内核 TCP 发送）
- 能看到 `copy_from_user`（内核将用户态数据拷贝到 SKB）

**preload 劫持火焰图**：
- 最宽的顶层函数：`runtime.memmove`（Go 的 memcpy）
- 能看到 `ShmipcWrite` → `Reserve` → `copy` → `Flush` 的调用链
- **看不到** `tcp_sendmsg`（数据不走内核协议栈）

**对比火焰图**：
- 红色部分：preload 路径比正常路径多的开销（memcpy + CGO）
- 蓝色部分：preload 路径比正常路径少的开销（内核协议栈）

### 4.4 strace 关键发现

**preload 模式下 strace 应该看到**：
- `write()` 调用仍然存在（因为 preload 劫持了 write，但 strace 在更底层）
- 但 `write()` 的耗时极短（<1us），因为只是 CGO 调用入口
- `epoll_wait` 是等待对端通知的主要系统调用
- **不应该看到** `sendto` 等网络发送系统调用（数据走共享内存）

### 4.5 ltrace 关键发现

**preload 模式下 ltrace 应该看到**：
- `ShmipcWrite` 替代了真正的 `write` 系统调用
- `ShmipcRead` 替代了真正的 `read` 系统调用
- `write()` 和 `read()` 仍然出现，但耗时极短（CGO 入口）
- 可以确认劫持是否生效

---

## 附录：快速命令参考

```bash
# ===== 一键火焰图 =====
sudo ./run_flamegraph.sh --compare --msg-size 524288

# ===== 一键全链路追踪 =====
sudo ./run_trace.sh --msg-size 524288

# ===== 只用 shmipc 内置追踪（最精确）=====
sudo ./run_trace.sh --tools shmipc --msg-size 524288

# ===== 分析已有日志 =====
./analyze_trace.sh

# ===== 手动 strace =====
strace -T -tt -e trace=write,read,send,recv,epoll_wait \
    LD_PRELOAD=./libshmipc_opt.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw

# ===== 手动 ltrace =====
ltrace -T -tt -e write+read+send+recv+ShmipcWrite+ShmipcRead \
    LD_PRELOAD=./libshmipc_opt.so \
    qperf 127.0.0.1 -msg_size 524288 -t 10 tcp_bw
```
