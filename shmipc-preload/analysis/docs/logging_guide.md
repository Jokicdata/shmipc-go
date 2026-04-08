# shmipc-preload 日志打点分析方案

## 一、概述

本文档描述如何在 shmipc-preload 中添加精确的日志打点，用于分析各函数的耗时分布。

## 二、打点位置

### 2.1 C 层打点位置

| 函数 | 打点位置 | 目的 |
|------|----------|------|
| `socket()` | 入口/出口 | 分析 socket 创建开销 |
| `connect()` | 入口/出口 | 分析连接建立开销 |
| `accept()` | 入口/出口 | 分析接受连接开销 |
| `send()/write()` | 入口/出口 | 分析发送开销 |
| `recv()/read()` | 入口/出口 | 分析接收开销 |

### 2.2 Go 层打点位置

| 函数 | 打点位置 | 目的 |
|------|----------|------|
| `ShmipcWrite()` | 入口/出口 | 分析写入总开销 |
| `C.GoBytes()` | 调用前后 | 分析内存拷贝开销 |
| `stream.BufferWriter().WriteBytes()` | 调用前后 | 分析共享内存写入开销 |
| `stream.Flush()` | 调用前后 | 分析刷新开销 |
| `ShmipcRead()` | 入口/出口 | 分析读取总开销 |
| `stream.BufferReader().ReadBytes()` | 调用前后 | 分析共享内存读取开销 |
| `copy()` | 调用前后 | 分析内存拷贝开销 |

## 三、打点实现

### 3.1 C 层打点实现

在 `shmipc_preload.c` 中添加：

```c
#include <time.h>

typedef struct {
    uint64_t total_ns;
    uint64_t count;
    uint64_t min_ns;
    uint64_t max_ns;
} timing_stats_t;

static timing_stats_t g_timing_stats[16];

static inline uint64_t get_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

#define TIMING_START(id) \
    uint64_t _start_##id = get_ns()

#define TIMING_END(id) \
    do { \
        uint64_t _end = get_ns(); \
        uint64_t _elapsed = _end - _start_##id; \
        timing_stats_t *_s = &g_timing_stats[id]; \
        _s->total_ns += _elapsed; \
        _s->count++; \
        if (_s->min_ns == 0 || _elapsed < _s->min_ns) _s->min_ns = _elapsed; \
        if (_elapsed > _s->max_ns) _s->max_ns = _elapsed; \
    } while(0)

enum {
    TIMING_SOCKET = 0,
    TIMING_CONNECT,
    TIMING_ACCEPT,
    TIMING_SEND,
    TIMING_RECV,
    TIMING_WRITE,
    TIMING_READ,
    TIMING_SHMIPC_WRITE,
    TIMING_SHMIPC_READ,
};

ssize_t write(int fd, const void *buf, size_t count) {
    init_real_funcs();
    
    TIMING_START(WRITE);
    
    fd_info_t *info = get_fd_info(fd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        TIMING_START(SHMIPC_WRITE);
        long ret = ShmipcWrite(info->stream_id, buf, (long)count);
        TIMING_END(SHMIPC_WRITE);
        
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            TIMING_END(WRITE);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_write(fd, buf, count);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
    }
    TIMING_END(WRITE);
    return ret;
}
```

### 3.2 Go 层打点实现

在 `shmipc_bridge.go` 中添加：

```go
import (
    "time"
    "sync/atomic"
)

type TimingStats struct {
    TotalNs   uint64
    Count     uint64
    MinNs     uint64
    MaxNs     uint64
}

var (
    timingWriteTotal     TimingStats
    timingGoBytes        TimingStats
    timingWriteBytes     TimingStats
    timingFlush          TimingStats
    timingReadTotal      TimingStats
    timingReadBytes      TimingStats
    timingCopy           TimingStats
)

func recordTiming(stats *TimingStats, elapsed uint64) {
    atomic.AddUint64(&stats.TotalNs, elapsed)
    atomic.AddUint64(&stats.Count, 1)
    
    for {
        oldMin := atomic.LoadUint64(&stats.MinNs)
        if oldMin != 0 && elapsed >= oldMin {
            break
        }
        if atomic.CompareAndSwapUint64(&stats.MinNs, oldMin, elapsed) {
            break
        }
    }
    
    for {
        oldMax := atomic.LoadUint64(&stats.MaxNs)
        if elapsed <= oldMax {
            break
        }
        if atomic.CompareAndSwapUint64(&stats.MaxNs, oldMax, elapsed) {
            break
        }
    }
}

//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    startTotal := time.Now()
    
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    startGoBytes := time.Now()
    buf := C.GoBytes(data, C.int(length))
    elapsedGoBytes := time.Since(startGoBytes).Nanoseconds()
    recordTiming(&timingGoBytes, uint64(elapsedGoBytes))

    writer := stream.BufferWriter()
    
    startWriteBytes := time.Now()
    n, err := writer.WriteBytes(buf)
    elapsedWriteBytes := time.Since(startWriteBytes).Nanoseconds()
    recordTiming(&timingWriteBytes, uint64(elapsedWriteBytes))
    
    if err != nil {
        return C.long(-2)
    }

    startFlush := time.Now()
    err = stream.Flush(false)
    elapsedFlush := time.Since(startFlush).Nanoseconds()
    recordTiming(&timingFlush, uint64(elapsedFlush))
    
    if err != nil {
        return C.long(-3)
    }

    elapsedTotal := time.Since(startTotal).Nanoseconds()
    recordTiming(&timingWriteTotal, uint64(elapsedTotal))

    return C.long(n)
}

//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    startTotal := time.Now()
    
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    startReadBytes := time.Now()
    reader := stream.BufferReader()
    buf, err := reader.ReadBytes(int(length))
    elapsedReadBytes := time.Since(startReadBytes).Nanoseconds()
    recordTiming(&timingReadBytes, uint64(elapsedReadBytes))
    
    if err != nil {
        return C.long(-2)
    }

    startCopy := time.Now()
    copy((*[1 << 30]byte)(data)[:len(buf)], buf)
    elapsedCopy := time.Since(startCopy).Nanoseconds()
    recordTiming(&timingCopy, uint64(elapsedCopy))
    
    stream.ReleaseReadAndReuse()

    elapsedTotal := time.Since(startTotal).Nanoseconds()
    recordTiming(&timingReadTotal, uint64(elapsedTotal))

    return C.long(len(buf))
}

//export ShmipcGetTimingStats
func ShmipcGetTimingStats(stats unsafe.Pointer) C.int {
    type CTimingStats struct {
        WriteTotalNs   uint64
        WriteCount     uint64
        WriteMinNs     uint64
        WriteMaxNs     uint64
        GoBytesNs      uint64
        GoBytesCount   uint64
        WriteBytesNs   uint64
        WriteBytesCnt  uint64
        FlushNs        uint64
        FlushCount     uint64
        ReadTotalNs    uint64
        ReadCount      uint64
        ReadMinNs      uint64
        ReadMaxNs      uint64
        ReadBytesNs    uint64
        ReadBytesCnt   uint64
        CopyNs         uint64
        CopyCount      uint64
    }
    
    s := CTimingStats{
        WriteTotalNs:  atomic.LoadUint64(&timingWriteTotal.TotalNs),
        WriteCount:    atomic.LoadUint64(&timingWriteTotal.Count),
        WriteMinNs:    atomic.LoadUint64(&timingWriteTotal.MinNs),
        WriteMaxNs:    atomic.LoadUint64(&timingWriteTotal.MaxNs),
        GoBytesNs:     atomic.LoadUint64(&timingGoBytes.TotalNs),
        GoBytesCount:  atomic.LoadUint64(&timingGoBytes.Count),
        WriteBytesNs:  atomic.LoadUint64(&timingWriteBytes.TotalNs),
        WriteBytesCnt: atomic.LoadUint64(&timingWriteBytes.Count),
        FlushNs:       atomic.LoadUint64(&timingFlush.TotalNs),
        FlushCount:    atomic.LoadUint64(&timingFlush.Count),
        ReadTotalNs:   atomic.LoadUint64(&timingReadTotal.TotalNs),
        ReadCount:     atomic.LoadUint64(&timingReadTotal.Count),
        ReadMinNs:     atomic.LoadUint64(&timingReadTotal.MinNs),
        ReadMaxNs:     atomic.LoadUint64(&timingReadTotal.MaxNs),
        ReadBytesNs:   atomic.LoadUint64(&timingReadBytes.TotalNs),
        ReadBytesCnt:  atomic.LoadUint64(&timingReadBytes.Count),
        CopyNs:        atomic.LoadUint64(&timingCopy.TotalNs),
        CopyCount:     atomic.LoadUint64(&timingCopy.Count),
    }
    
    copy((*[unsafe.Sizeof(s)]byte)(stats)[:], (*[unsafe.Sizeof(s)]byte)(unsafe.Pointer(&s))[:])
    
    return C.int(0)
}
```

## 四、分析脚本

### 4.1 实时监控脚本

```bash
#!/bin/bash
# monitor_timing.sh - 实时监控打点数据

INTERVAL=${1:-1}

echo "时间,写入总耗时(us),写入次数,写入平均(us),GoBytes耗时(us),GoBytes次数,共享内存写入耗时(us),刷新耗时(us),读取总耗时(us),读取次数,读取平均(us),共享内存读取耗时(us),拷贝耗时(us)"

while true; do
    # 这里需要调用 ShmipcGetTimingStats 获取数据
    # 可以通过一个简单的 C 程序或 Go 程序来获取
    
    # 示例输出格式
    echo "$(date +%H:%M:%S),1000,100,10,500,100,300,200,800,100,8,400,400"
    
    sleep $INTERVAL
done
```

### 4.2 数据分析脚本

```python
#!/usr/bin/env python3
# analyze_timing.py - 分析打点数据

import csv
import sys
from collections import defaultdict

def analyze_timing(csv_file):
    data = []
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            data.append(row)
    
    if not data:
        print("没有数据")
        return
    
    print("=" * 60)
    print("  性能分析报告")
    print("=" * 60)
    
    # 分析写入耗时
    write_times = [float(d['写入总耗时(us)']) for d in data]
    write_counts = [int(d['写入次数']) for d in data]
    
    print("\n[写入分析]")
    print(f"  总耗时: {sum(write_times):.2f} us")
    print(f"  总次数: {sum(write_counts)}")
    print(f"  平均耗时: {sum(write_times)/sum(write_counts):.2f} us")
    
    # 分析内存拷贝耗时
    gobyes_times = [float(d['GoBytes耗时(us)']) for d in data]
    copy_times = [float(d['拷贝耗时(us)']) for d in data]
    
    print("\n[内存拷贝分析]")
    print(f"  C.GoBytes() 总耗时: {sum(gobyes_times):.2f} us")
    print(f"  copy() 总耗时: {sum(copy_times):.2f} us")
    print(f"  内存拷贝占比: {(sum(gobyes_times) + sum(copy_times)) / sum(write_times) * 100:.2f}%")
    
    # 分析共享内存操作耗时
    shm_write_times = [float(d['共享内存写入耗时(us)']) for d in data]
    shm_read_times = [float(d['共享内存读取耗时(us)']) for d in data]
    
    print("\n[共享内存操作分析]")
    print(f"  共享内存写入总耗时: {sum(shm_write_times):.2f} us")
    print(f"  共享内存读取总耗时: {sum(shm_read_times):.2f} us")
    
    # 瓶颈分析
    print("\n[瓶颈分析]")
    total_time = sum(write_times)
    mem_copy_time = sum(gobyes_times) + sum(copy_times)
    shm_time = sum(shm_write_times) + sum(shm_read_times)
    
    print(f"  内存拷贝占比: {mem_copy_time / total_time * 100:.2f}%")
    print(f"  共享内存操作占比: {shm_time / total_time * 100:.2f}%")
    
    if mem_copy_time / total_time > 0.3:
        print("\n  ⚠️  内存拷贝是主要瓶颈！")
        print("  建议：优化 C.GoBytes() 和 copy() 调用")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("用法: python3 analyze_timing.py <timing.csv>")
        sys.exit(1)
    
    analyze_timing(sys.argv[1])
```

## 五、预期输出示例

```
========================================
  性能分析报告
========================================

[写入分析]
  总耗时: 1000000.00 us
  总次数: 1000
  平均耗时: 1000.00 us

[内存拷贝分析]
  C.GoBytes() 总耗时: 400000.00 us
  copy() 总耗时: 300000.00 us
  内存拷贝占比: 70.00%

[共享内存操作分析]
  共享内存写入总耗时: 200000.00 us
  共享内存读取总耗时: 100000.00 us

[瓶颈分析]
  内存拷贝占比: 70.00%
  共享内存操作占比: 30.00%

  ⚠️  内存拷贝是主要瓶颈！
  建议：优化 C.GoBytes() 和 copy() 调用
```

## 六、注意事项

1. **性能开销**：打点本身会有约 50-100ns 的开销，建议仅在分析时启用
2. **线程安全**：使用原子操作确保多线程环境下的数据正确性
3. **内存开销**：统计数据结构占用内存很小，可以忽略不计
4. **编译选项**：可以通过编译选项控制是否启用打点

```c
#ifdef ENABLE_TIMING
#define TIMING_START(id) ...
#define TIMING_END(id) ...
#else
#define TIMING_START(id)
#define TIMING_END(id)
#endif
```
