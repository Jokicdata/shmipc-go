# eBPF 性能分析工具使用指南

## 一、eBPF 简介

eBPF (extended Berkeley Packet Filter) 是 Linux 内核提供的一种强大的追踪和分析框架，可以在内核和用户态动态注入代码，实现低开销的观测。

## 二、工具安装

### 2.1 bpftrace 安装

```bash
# Ubuntu
sudo apt-get install -y bpftrace

# CentOS/RHEL
sudo yum install -y bpftrace

# 从源码编译
git clone https://github.com/iovisor/bpftrace
cd bpftrace
mkdir build && cd build
cmake ..
make && sudo make install
```

### 2.2 bcc 工具集安装

```bash
# Ubuntu
sudo apt-get install -y bpfcc-tools linux-headers-$(uname -r)

# CentOS/RHEL
sudo yum install -y bcc-tools
```

## 三、bpftrace 基础

### 3.1 基本语法

```bash
# 单行命令
sudo bpftrace -e 'probe { action }'

# 脚本文件
sudo bpftrace script.bt
```

### 3.2 常用探针类型

| 探针类型 | 说明 | 示例 |
|----------|------|------|
| `kprobe` | 内核函数入口 | `kprobe:do_sys_open` |
| `kretprobe` | 内核函数返回 | `kretprobe:do_sys_open` |
| `uprobe` | 用户态函数入口 | `uprobe:/lib/x86_64-linux-gnu/libc.so.6:malloc` |
| `uretprobe` | 用户态函数返回 | `uretprobe:/lib/x86_64-linux-gnu/libc.so.6:malloc` |
| `tracepoint` | 内核跟踪点 | `tracepoint:syscalls:sys_enter_open` |
| `usdt` | 用户态静态跟踪点 | `usdt:/path/to/binary:provider:name` |

### 3.3 内置变量

| 变量 | 说明 |
|------|------|
| `pid` | 进程 ID |
| `tid` | 线程 ID |
| `uid` | 用户 ID |
| `gid` | 组 ID |
| `comm` | 进程名 |
| `nsecs` | 纳秒时间戳 |
| `retval` | 返回值（仅 kretprobe/uretprobe） |
| `arg0-argN` | 函数参数 |

## 四、shmipc-preload 分析场景

### 4.1 追踪 ShmipcWrite 耗时

```bash
#!/usr/bin/bpftrace
# trace_shmipc_write.bt

uprobe:/usr/local/lib/libshmipc_go.so:ShmipcWrite
{
    @start[tid] = nsecs;
}

uretprobe:/usr/local/lib/libshmipc_go.so:ShmipcWrite
/@start[tid]/
{
    @ns[comm] = hist(nsecs - @start[tid]);
    delete(@start[tid]);
}

interval:s:5
{
    print(@ns);
    clear(@ns);
}
```

### 4.2 追踪内存拷贝

```bash
#!/usr/bin/bpftrace
# trace_memcpy.bt

uprobe:libc.so.6:memcpy
{
    @start[tid] = nsecs;
    @memcpy_size[tid] = arg2;
}

uretprobe:libc.so.6:memcpy
/@start[tid]/
{
    @memcpy_ns = hist(nsecs - @start[tid]);
    @memcpy_size_hist = hist(@memcpy_size[tid]);
    delete(@start[tid]);
    delete(@memcpy_size[tid]);
}

interval:s:5
{
    printf("\n=== memcpy 耗时分布 ===\n");
    print(@memcpy_ns);
    printf("\n=== memcpy 大小分布 ===\n");
    print(@memcpy_size_hist);
}
```

### 4.3 追踪 CGO 调用

```bash
#!/usr/bin/bpftrace
# trace_cgo.bt

BEGIN
{
    printf("追踪 CGO 调用...\n");
}

uprobe:/usr/local/lib/libshmipc_go.so:Shmipc*
{
    @cgo_calls[comm, probe] = count();
}

interval:s:5
{
    print(@cgo_calls);
    clear(@cgo_calls);
}
```

### 4.4 追踪系统调用

```bash
#!/usr/bin/bpftrace
# trace_syscalls.bt

tracepoint:syscalls:sys_enter_*
/pid == $1/
{
    @syscalls[probe] = count();
}

tracepoint:syscalls:sys_exit_*
/pid == $1/
{
    @syscall_ns[probe] = hist(nsecs - @start[tid]);
}

interval:s:10
{
    printf("\n=== 系统调用统计 ===\n");
    print(@syscalls);
    clear(@syscalls);
}
```

### 4.5 追踪共享内存操作

```bash
#!/usr/bin/bpftrace
# trace_shm.bt

BEGIN
{
    printf("追踪共享内存操作...\n");
}

kprobe:memfd_create
{
    printf("[%s] memfd_create: name=%s\n", comm, str(arg0));
}

kprobe:mmap
{
    printf("[%s] mmap: addr=%x, len=%d, prot=%d, flags=%d\n",
           comm, arg0, arg1, arg2, arg3);
}

kprobe:munmap
{
    printf("[%s] munmap: addr=%x, len=%d\n", comm, arg0, arg1);
}
```

## 五、高级分析脚本

### 5.1 完整性能分析

```bash
#!/usr/bin/bpftrace
# full_analysis.bt

BEGIN
{
    printf("========================================\n");
    printf("  shmipc-preload 完整性能分析\n");
    printf("========================================\n");
}

/* 追踪 ShmipcWrite */
uprobe:/usr/local/lib/libshmipc_go.so:ShmipcWrite
{
    @write_start[tid] = nsecs;
}

uretprobe:/usr/local/lib/libshmipc_go.so:ShmipcWrite
/@write_start[tid]/
{
    $elapsed = nsecs - @write_start[tid];
    @write_ns = hist($elapsed);
    @write_total = sum($elapsed);
    @write_count = count();
    delete(@write_start[tid]);
}

/* 追踪 ShmipcRead */
uprobe:/usr/local/lib/libshmipc_go.so:ShmipcRead
{
    @read_start[tid] = nsecs;
}

uretprobe:/usr/local/lib/libshmipc_go.so:ShmipcRead
/@read_start[tid]/
{
    $elapsed = nsecs - @read_start[tid];
    @read_ns = hist($elapsed);
    @read_total = sum($elapsed);
    @read_count = count();
    delete(@read_start[tid]);
}

/* 追踪 memcpy */
uprobe:libc.so.6:memcpy
{
    @memcpy_start[tid] = nsecs;
    @memcpy_size[tid] = arg2;
}

uretprobe:libc.so.6:memcpy
/@memcpy_start[tid]/
{
    $elapsed = nsecs - @memcpy_start[tid];
    @memcpy_ns = hist($elapsed);
    @memcpy_total = sum($elapsed);
    @memcpy_count = count();
    delete(@memcpy_start[tid]);
    delete(@memcpy_size[tid]);
}

/* 追踪内核系统调用 */
tracepoint:syscalls:sys_enter_write
/pid == $1/
{
    @sys_write_start[tid] = nsecs;
}

tracepoint:syscalls:sys_exit_write
/@sys_write_start[tid]/
{
    $elapsed = nsecs - @sys_write_start[tid];
    @sys_write_ns = hist($elapsed);
    delete(@sys_write_start[tid]);
}

tracepoint:syscalls:sys_enter_read
/pid == $1/
{
    @sys_read_start[tid] = nsecs;
}

tracepoint:syscalls:sys_exit_read
/@sys_read_start[tid]/
{
    $elapsed = nsecs - @sys_read_start[tid];
    @sys_read_ns = hist($elapsed);
    delete(@sys_read_start[tid]);
}

/* 定期输出 */
interval:s:10
{
    printf("\n========================================\n");
    printf("  性能统计 (每 10 秒)\n");
    printf("========================================\n");
    
    printf("\n[ShmipcWrite 耗时分布]\n");
    print(@write_ns);
    
    printf("\n[ShmipcRead 耗时分布]\n");
    print(@read_ns);
    
    printf("\n[memcpy 耗时分布]\n");
    print(@memcpy_ns);
    
    printf("\n[系统调用 write 耗时分布]\n");
    print(@sys_write_ns);
    
    printf("\n[系统调用 read 耗时分布]\n");
    print(@sys_read_ns);
}

/* 结束时输出汇总 */
END
{
    printf("\n========================================\n");
    printf("  最终汇总\n");
    printf("========================================\n");
    
    printf("\n[ShmipcWrite]\n");
    printf("  总耗时: %d ns\n", @write_total);
    printf("  调用次数: %d\n", @write_count);
    printf("  平均耗时: %d ns\n", @write_total / @write_count);
    
    printf("\n[ShmipcRead]\n");
    printf("  总耗时: %d ns\n", @read_total);
    printf("  调用次数: %d\n", @read_count);
    printf("  平均耗时: %d ns\n", @read_total / @read_count);
    
    printf("\n[memcpy]\n");
    printf("  总耗时: %d ns\n", @memcpy_total);
    printf("  调用次数: %d\n", @memcpy_count);
    printf("  平均耗时: %d ns\n", @memcpy_total / @memcpy_count);
    
    printf("\n[瓶颈分析]\n");
    $total = @write_total + @read_total;
    printf("  memcpy 占比: %.2f%%\n", (@memcpy_total * 100.0) / $total);
}
```

### 5.2 使用方法

```bash
# 启动测试程序
LD_PRELOAD=./libshmipc.so qperf &
QPERF_PID=$!

# 运行 eBPF 追踪
sudo bpftrace -e 'pid:$1' full_analysis.bt $QPERF_PID

# 或者使用脚本
sudo bpftrace full_analysis.bt -p $QPERF_PID
```

## 六、bcc 工具集

### 6.1 常用工具

```bash
# 追踪函数调用
sudo /usr/share/bcc/tools/trace 'r::ShmipcWrite "%d ns", retval'

# 追踪内存分配
sudo /usr/share/bcc/tools/memleak -p <pid>

# 追踪文件 I/O
sudo /usr/share/bcc/tools/filetop

# 追踪 TCP 连接
sudo /usr/share/bcc/tools/tcpconnect

# 追踪系统调用
sudo /usr/share/bcc/tools/syscount -p <pid>
```

### 6.2 自定义 Python 脚本

```python
#!/usr/bin/python3
# trace_shmipc.py

from bcc import BPF
import time

prog = """
#include <uapi/linux/ptrace.h>

BPF_HASH(start, u32);
BPF_HISTOGRAM(dist);

int trace_write_entry(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid();
    u64 ts = bpf_ktime_get_ns();
    start.update(&pid, &ts);
    return 0;
}

int trace_write_return(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid();
    u64 *tsp = start.lookup(&pid);
    
    if (tsp != 0) {
        u64 delta = bpf_ktime_get_ns() - *tsp;
        dist.increment(bpf_log2l(delta / 1000));
        start.delete(&pid);
    }
    return 0;
}
"""

b = BPF(text=prog)

b.attach_uprobe(name="/usr/local/lib/libshmipc_go.so", sym="ShmipcWrite", fn_name="trace_write_entry")
b.attach_uretprobe(name="/usr/local/lib/libshmipc_go.so", sym="ShmipcWrite", fn_name="trace_write_return")

print("Tracing ShmipcWrite... Hit Ctrl-C to end.")

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("\n")

b["dist"].print_log2_hist("usecs")
```

## 七、注意事项

1. **权限要求**：需要 root 权限运行
2. **内核版本**：建议 Linux 4.9+ 以获得完整功能
3. **性能开销**：eBPF 开销很低，通常 < 5%
4. **符号信息**：确保目标库有符号信息（未 strip）

## 八、参考资源

- [bpftrace 参考指南](https://github.com/iovisor/bpftrace/blob/master/docs/reference_guide.md)
- [BCC 工具集](https://github.com/iovisor/bcc)
- [eBPF 官方文档](https://ebpf.io/)
