# ftrace 内核追踪工具使用指南

## 一、ftrace 简介

ftrace 是 Linux 内核内置的追踪框架，可以追踪内核函数调用、调度事件、中断等，开销极低。

## 二、基本使用

### 2.1 ftrace 目录结构

```bash
# ftrace 控制目录
cd /sys/kernel/debug/tracing

# 主要文件
available_tracers    # 可用的追踪器
current_tracer       # 当前使用的追踪器
trace                # 追踪输出
tracing_on           # 开关 (0/1)
set_ftrace_filter    # 追踪函数过滤
set_ftrace_notrace   # 排除函数过滤
options/             # 各种选项
```

### 2.2 可用追踪器

```bash
# 查看可用追踪器
cat available_tracers

# 常用追踪器：
# - function: 函数调用追踪
# - function_graph: 函数调用图
# - wakeup: 唤醒延迟追踪
# - irqsoff: 中断关闭时间追踪
# - preemptoff: 抢占关闭时间追踪
# - nop: 无追踪（默认）
```

### 2.3 基本操作

```bash
# 启用追踪
echo 1 > tracing_on

# 停止追踪
echo 0 > tracing_on

# 清空追踪缓冲
echo > trace

# 查看追踪结果
cat trace
```

## 三、函数追踪

### 3.1 追踪所有函数

```bash
# 设置追踪器
echo function > current_tracer

# 开始追踪
echo 1 > tracing_on

# 运行测试...

# 停止追踪
echo 0 > tracing_on

# 查看结果
cat trace
```

### 3.2 追踪特定函数

```bash
# 只追踪 socket 相关函数
echo "SyS_socket" > set_ftrace_filter
echo "SyS_bind" >> set_ftrace_filter
echo "SyS_listen" >> set_ftrace_filter
echo "SyS_accept4" >> set_ftrace_filter
echo "SyS_connect" >> set_ftrace_filter
echo "SyS_sendto" >> set_ftrace_filter
echo "SyS_recvfrom" >> set_ftrace_filter

# 启用追踪
echo function > current_tracer
echo 1 > tracing_on
```

### 3.3 追踪函数调用图

```bash
# 设置函数调用图追踪器
echo function_graph > current_tracer

# 启用选项
echo 1 > options/funcgraph-abstime    # 显示绝对时间
echo 1 > options/funcgraph-cpu        # 显示 CPU
echo 1 > options/funcgraph-proc       # 显示进程名
echo 1 > options/funcgraph-duration   # 显示耗时
echo 1 > options/funcgraph-overhead   # 显示开销标记

# 开始追踪
echo 1 > tracing_on
```

### 3.4 追踪特定进程

```bash
# 设置要追踪的 PID
echo <pid> > set_ftrace_pid

# 启用追踪
echo function > current_tracer
echo 1 > tracing_on
```

## 四、shmipc-preload 分析场景

### 4.1 追踪 socket 系统调用

```bash
#!/bin/bash
# trace_socket.sh

TRACING=/sys/kernel/debug/tracing

# 设置追踪函数
cat > $TRACING/set_ftrace_filter << 'EOF'
SyS_socket
SyS_bind
SyS_listen
SyS_accept4
SyS_connect
SyS_sendto
SyS_recvfrom
SyS_write
SyS_read
SyS_close
sock_sendmsg
sock_recvmsg
tcp_sendmsg
tcp_recvmsg
unix_stream_sendmsg
unix_stream_recvmsg
EOF

# 设置追踪器
echo function_graph > $TRACING/current_tracer
echo 1 > $TRACING/options/funcgraph-abstime
echo 1 > $TRACING/options/funcgraph-duration

# 清空并开始
echo > $TRACING/trace
echo 1 > $TRACING/tracing_on

echo "追踪已启动，按 Ctrl+C 停止..."

# 等待
trap "echo 0 > $TRACING/tracing_on; cat $TRACING/trace > trace_socket.log; echo '结果保存到 trace_socket.log'" INT

sleep infinity
```

### 4.2 追踪内存操作

```bash
#!/bin/bash
# trace_memory.sh

TRACING=/sys/kernel/debug/tracing

# 设置追踪函数
cat > $TRACING/set_ftrace_filter << 'EOF'
__memcpy
__memmove
copy_to_user
copy_from_user
copy_page
clear_page
get_user_pages_fast
EOF

echo function_graph > $TRACING/current_tracer
echo 1 > $TRACING/options/funcgraph-duration

echo > $TRACING/trace
echo 1 > $TRACING/tracing_on

echo "追踪内存操作，按 Ctrl+C 停止..."

trap "echo 0 > $TRACING/tracing_on; cat $TRACING/trace > trace_memory.log" INT

sleep infinity
```

### 4.3 追踪共享内存操作

```bash
#!/bin/bash
# trace_shm.sh

TRACING=/sys/kernel/debug/tracing

cat > $TRACING/set_ftrace_filter << 'EOF'
memfd_create
shmget
shmat
shmdt
shmctl
mmap
munmap
mprotect
EOF

echo function_graph > $TRACING/current_tracer

echo > $TRACING/trace
echo 1 > $TRACING/tracing_on

echo "追踪共享内存操作，按 Ctrl+C 停止..."

trap "echo 0 > $TRACING/tracing_on; cat $TRACING/trace > trace_shm.log" INT

sleep infinity
```

### 4.4 追踪调度延迟

```bash
#!/bin/bash
# trace_latency.sh

TRACING=/sys/kernel/debug/tracing

# 使用 wakeup 追踪器分析唤醒延迟
echo wakeup > $TRACING/current_tracer

echo > $TRACING/trace
echo 1 > $TRACING/tracing_on

echo "追踪调度延迟，按 Ctrl+C 停止..."

trap "echo 0 > $TRACING/tracing_on; cat $TRACING/trace > trace_latency.log" INT

sleep infinity
```

## 五、输出分析

### 5.1 function_graph 输出格式

```
# tracer: function_graph
#
# CPU  TASK/PID         DURATION                  FUNCTION CALLS
# |     |    |           |   |                     |   |   |   |
  0)   qperf-1234    |   1.234 us   |  SyS_write();
  0)   qperf-1234    |               |  SyS_sendto() {
  0)   qperf-1234    |   0.123 us    |    sock_sendmsg();
  0)   qperf-1234    |               |    tcp_sendmsg() {
  0)   qperf-1234    |   5.678 us    |      copy_from_user();
  0)   qperf-1234    |   8.901 us    |    }
  0)   qperf-1234    | + 10.234 us   |  }
```

### 5.2 分析脚本

```python
#!/usr/bin/env python3
# analyze_ftrace.py

import re
import sys
from collections import defaultdict

def parse_ftrace(filename):
    functions = []
    
    with open(filename, 'r') as f:
        for line in f:
            # 匹配函数调用行
            match = re.match(r'\s+\d+\)\s+\S+-\d+\s+\|\s+([\d.]+)\s+us\s+\|\s+(\S+)\(', line)
            if match:
                duration = float(match.group(1))
                func_name = match.group(2)
                functions.append((func_name, duration))
    
    return functions

def analyze_functions(functions):
    stats = defaultdict(lambda: {'count': 0, 'total': 0, 'min': float('inf'), 'max': 0})
    
    for func, duration in functions:
        stats[func]['count'] += 1
        stats[func]['total'] += duration
        stats[func]['min'] = min(stats[func]['min'], duration)
        stats[func]['max'] = max(stats[func]['max'], duration)
    
    return stats

def print_report(stats):
    print("=" * 80)
    print("  ftrace 分析报告")
    print("=" * 80)
    print()
    
    print(f"{'函数名':<40} {'调用次数':>10} {'平均(us)':>10} {'最小(us)':>10} {'最大(us)':>10}")
    print("-" * 80)
    
    # 按总耗时排序
    sorted_funcs = sorted(stats.items(), key=lambda x: x[1]['total'], reverse=True)
    
    for func, data in sorted_funcs[:20]:
        avg = data['total'] / data['count']
        print(f"{func:<40} {data['count']:>10} {avg:>10.2f} {data['min']:>10.2f} {data['max']:>10.2f}")
    
    print()
    print("=" * 80)
    print("  瓶颈分析")
    print("=" * 80)
    
    # 分析内存操作
    mem_funcs = ['copy_from_user', 'copy_to_user', '__memcpy', '__memmove']
    mem_total = sum(stats[f]['total'] for f in mem_funcs if f in stats)
    
    # 分析 socket 操作
    sock_funcs = ['sock_sendmsg', 'sock_recvmsg', 'tcp_sendmsg', 'tcp_recvmsg']
    sock_total = sum(stats[f]['total'] for f in sock_funcs if f in stats)
    
    total = sum(data['total'] for data in stats.values())
    
    print(f"内存操作总耗时: {mem_total:.2f} us ({mem_total/total*100:.1f}%)")
    print(f"Socket 操作总耗时: {sock_total:.2f} us ({sock_total/total*100:.1f}%)")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("用法: python3 analyze_ftrace.py <trace.log>")
        sys.exit(1)
    
    functions = parse_ftrace(sys.argv[1])
    stats = analyze_functions(functions)
    print_report(stats)
```

## 六、高级用法

### 6.1 追踪条件

```bash
# 只追踪特定条件
echo 'common_pid == 1234' > events/syscalls/filter

# 追踪特定 CPU
echo 1 > per_cpu/cpu0/trace
```

### 6.2 事件追踪

```bash
# 启用系统调用事件
echo 1 > events/syscalls/enable

# 启用特定事件
echo 1 > events/syscalls/sys_enter_write/enable
echo 1 > events/syscalls/sys_exit_write/enable

# 查看事件格式
cat events/syscalls/sys_enter_write/format
```

### 6.3 触发器

```bash
# 当函数被调用时打印堆栈
echo 'SyS_write:stacktrace' > set_ftrace_filter

# 当函数被调用时记录快照
echo 'SyS_write:snapshot' > set_ftrace_filter
```

## 七、注意事项

1. **权限要求**：需要 root 权限访问 `/sys/kernel/debug/tracing`
2. **性能开销**：function_graph 追踪开销约 10-20%，function 追踪开销约 5%
3. **缓冲区大小**：默认缓冲区可能不够，可以增大
   ```bash
   echo 10240 > buffer_size_kb
   ```
4. **清理**：使用后记得清理设置
   ```bash
   echo 0 > tracing_on
   echo nop > current_tracer
   echo > set_ftrace_filter
   ```

## 八、参考资源

- [ftrace 官方文档](https://www.kernel.org/doc/Documentation/trace/ftrace.txt)
- [ftrace 使用指南](https://jvns.ca/blog/2017/03/19/getting-started-with-ftrace/)
- [Linux Tracing Systems](https://blog.0x972.info/?d=2015/11/10/10/00/00)
