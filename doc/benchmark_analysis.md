# Shmipc 性能测试流程分析

## 概述

本文档详细分析了 `bench_test.go` 中的性能测试流程，包括 Shmipc 和原生 Unix Domain Socket (UDS) 的客户端和服务端实现，以及两者的详细对比。

## 测试架构

### 测试配置函数

```go
func benchmarkConfig() *Config {
    c := DefaultConfig()
    c.QueueCap = 65535
    c.ConnectionWriteTimeout = time.Second
    c.ShareMemoryBufferCap = 256 << 20  // 256MB
    c.MemMapType = MemMapTypeMemFd
    return c
}
```

### 测试数据大小

```go
dataSizes = map[string]int{
    "64B":   64,
    "512B":  512,
    "1KB":   1 << 10,
    "4KB":   4 << 10,
    "16KB":  16 << 10,
    "64KB":  64 << 10,
    "256KB": 256 << 10,
    "512KB": 512 << 10,
    "1MB":   1 << 20,
    "4MB":   4 << 20,
}
```

## Shmipc 测试流程

### 1. 测试入口函数

```go
func BenchmarkParallelPingPongByShmipc64B(b *testing.B) {
    benchmarkParallelPingPongByShmipc(b, "64B")
}
```

### 2. 核心测试函数

```go
func benchmarkParallelPingPongByShmipc(b *testing.B, bodySize string) {
    // 步骤1: 创建客户端和服务端Session
    client, server := newBenchmarkClientServer(uint32(likelySizes[bodySize]))
    defer func() {
        client.Close()
        server.Close()
    }()

    b.SetBytes(int64(likelySizes[bodySize] + likelySizes[bodySize]))
    b.ReportAllocs()
    b.ResetTimer()
    
    // 步骤2: 并行执行测试
    b.RunParallel(func(pb *testing.PB) {
        hasNext := pb.Next()
        doneCh := make(chan struct{})
        if hasNext {
            // 服务端goroutine
            go func() {
                defer close(doneCh)
                stream, err := server.AcceptStream()
                if err != nil {
                    b.Fatalf("accept error:%s", err.Error())
                    return
                }
                defer stream.Close()
                for {
                    if !mustRead(stream, likelySizes[bodySize], b) {
                        return
                    }
                    stream.BufferReader().ReleasePreviousRead()
                    mustWrite(stream, bodySize, b)
                }
            }()
            
            // 客户端
            stream, err := client.OpenStream()
            if err != nil {
                b.Fatalf("err: %v", err)
            }
            for ; hasNext; hasNext = pb.Next() {
                mustWrite(stream, bodySize, b)
                mustRead(stream, likelySizes[bodySize], b)
                stream.ReleaseReadAndReuse()
            }
            stream.Close()
            <-doneCh
        }
    })
}
```

### 3. Shmipc 客户端和服务端创建

```go
func newBenchmarkClientServer(likelySize uint32) (client, server *Session) {
    config := benchmarkConfig()
    if likelySize >= 4<<20 {
        config.ShareMemoryBufferCap = 512 << 20
    }
    config.BufferSliceSizes = []*SizePercentPair{
        {likelySize, 100},
    }
    config.ShareMemoryPathPrefix += strconv.Itoa(int(rand.Int63()))
    addr := &net.UnixAddr{Name: "/dev/shm/shmipc.sock", Net: "unix"}
    
    serverStartNotifyCh := make(chan struct{})
    
    // 服务端启动
    go func() {
        ln, err := net.ListenUnix("unix", addr)
        if err != nil {
            panic("create listener failed:" + err.Error())
        }
        serverStartNotifyCh <- struct{}{}
        conn, err := ln.Accept()
        if err != nil {
            panic("accept conn failed:" + err.Error())
        }
        defer ln.Close()
        server, err = Server(conn, config)
        if err != nil {
            panic("create shmipc server failed:" + err.Error())
        }
        serverStartNotifyCh <- struct{}{}
    }()
    
    <-serverStartNotifyCh
    
    // 客户端连接
    conn, err := net.DialUnix("unix", nil, addr)
    if err != nil {
        panic("dial uds failed:" + err.Error())
    }
    client, err = newSession(config, conn, true)
    if err != nil {
        panic("create ipc client failed:" + err.Error())
    }
    <-serverStartNotifyCh
    return
}
```

### 4. Shmipc 写入数据

```go
func mustWrite(s *Stream, bodySize string, b *testing.B) {
    request := pingpong{
        Data: make([]byte, dataSizes[bodySize]),
    }
    
    // 零拷贝写入：直接预留共享内存空间

    reserve, err := s.BufferWriter().Reserve(likelySizes[bodySize])
    if err != nil {
        panic(err)
    }

    buf := bytes.NewBuffer(reserve)
    buf.Reset()
    encoder := json.NewEncoder(buf)
    err = encoder.Encode(request)
    if err != nil {
        panic(err)
    }

    // 刷新数据到对端
    for {
        err := s.Flush(false)
        if err == ErrQueueFull {
            time.Sleep(time.Microsecond)
            continue
        }
        if err != nil {
            panic("must write err:" + err.Error())
        }
        return
    }
}
```

### 5. Shmipc 读取数据

```go
func mustRead(s *Stream, size int, b *testing.B) bool {
    // 零拷贝读取：直接从共享内存读取
    _, err := s.BufferReader().ReadBytes(size)
    if err == ErrStreamClosed || err == ErrEndOfStream {
        return false
    } else if err != nil {
        panic(fmt.Sprintf("err: %s", err.Error()))
    }
    return true
}
```

## 原生 Unix Domain Socket 测试流程

### 1. 测试入口函数

```go
func BenchmarkParallelPingPongByUds64B(b *testing.B) {
    benchmarkParallelPingPongByUds(b, "64B")
}
```

### 2. 核心测试函数

```go
func benchmarkParallelPingPongByUds(b *testing.B, bodySize string) {
    addr := &net.UnixAddr{Name: fmt.Sprintf("/dev/shm/uds_%d.sock", time.Now().UnixNano()), Net: "unix"}
    defer syscall.Unlink(addr.Name)

    serverStartNotifyCh := make(chan struct{})

    // 服务端启动
    go func() {
        ln, err := net.ListenUnix("unix", addr)
        if err != nil {
            panic("create listener failed:" + err.Error())
        }
        time.AfterFunc(time.Millisecond*10, func() {
            close(serverStartNotifyCh)
        })
        defer ln.Close()
        for {
            conn, err := ln.Accept()
            if err != nil {
                panic("accept conn failed:" + err.Error())
            }
            go func(conn net.Conn) {
                defer conn.Close()
                for {
                    readBuffer := make([]byte, likelySizes[bodySize])
                    writeBuffer := make([]byte, likelySizes[bodySize])
                    request := pingpong{
                        Data: make([]byte, dataSizes[bodySize]),
                    }
                    buf := bytes.NewBuffer(writeBuffer)
                    buf.Reset()
                    encoder := json.NewEncoder(buf)
                    err = encoder.Encode(request)
                    if err != nil {
                        panic(err)
                    }

                    // 读取数据
                    if !udsMustRead(conn, readBuffer, likelySizes[bodySize]) {
                        return
                    }
                    // 写入数据
                    udsMustWrite(conn, writeBuffer)
                }
            }(conn)
        }
    }()

    b.SetBytes(int64(likelySizes[bodySize] + likelySizes[bodySize]))
    b.ReportAllocs()
    b.ResetTimer()
    <-serverStartNotifyCh
    
    // 客户端测试
    b.RunParallel(func(pb *testing.PB) {
        clientConn, err := net.DialUnix("unix", nil, addr)
        if err != nil {
            panic("create uds connection failed:" + err.Error())
        }
        defer clientConn.Close()
        for pb.Next() {
            readBuffer := make([]byte, likelySizes[bodySize])
            writeBuffer := make([]byte, likelySizes[bodySize])

            request := pingpong{
                Data: make([]byte, dataSizes[bodySize]),
            }
            buf := bytes.NewBuffer(writeBuffer)
            buf.Reset()
            encoder := json.NewEncoder(buf)
            err = encoder.Encode(request)
            if err != nil {
                panic(err)
            }

            // 写入数据
            udsMustWrite(clientConn, writeBuffer)
            // 读取数据
            udsMustRead(clientConn, readBuffer, likelySizes[bodySize])
        }
    })
}
```

### 3. UDS 写入数据

```go
func udsMustWrite(conn net.Conn, buf []byte) {
    var wrote int
    for {
        n, err := conn.Write(buf[wrote:])
        if err != nil {
            panic("uds client conn write failed:")
        }
        wrote += n
        if wrote == len(buf) {
            break
        }
    }
}
```

### 4. UDS 读取数据

```go
func udsMustRead(conn net.Conn, buf []byte, expectedSize int) bool {
    start := 0
    for start < expectedSize {
        n, err := conn.Read(buf[start:])
        if err == io.EOF {
            return false
        }
        if err != nil {
            return false
        }
        start += n
    }
    return true
}
```

## 性能对比分析

### Shmipc 优势

1. **零拷贝传输**：数据直接写入共享内存，避免用户态和内核态之间的数据拷贝
2. **批量IO**：通过队列机制实现批量处理，减少系统调用
3. **内存预分配**：通过 BufferManager 预分配共享内存块，减少动态内存分配

### 原生 UDS 特点

1. **简单直接**：通过标准的 socket API 进行通信
2. **内核缓冲**：数据需要经过内核缓冲区，涉及数据拷贝
3. **系统调用频繁**：每次读写都需要系统调用

### 性能测试结果

根据 README.md 中的测试结果：

| 数据包大小 | Shmipc 吞吐量 | UDS 吞吐量 | 性能提升 |
|-----------|---------------|-------------|----------|
| 64B       | 25.84 MB/s    | 36.21 MB/s  | -28.7%   |
| 512B      | 159.51 MB/s   | 170.72 MB/s | -6.6%    |
| 1KB       | 240.69 MB/s   | 255.66 MB/s | -5.9%    |
| 4KB       | 660.78 MB/s   | 343.44 MB/s | +92.4%   |
| 16KB      | 1278.49 MB/s  | 382.59 MB/s | +234.2%  |
| 64KB      | 1799.79 MB/s  | 807.23 MB/s | +123.0%  |
| 256KB     | 2010.89 MB/s  | 1343.84 MB/s| +49.6%   |
| 512KB     | 2463.51 MB/s  | 1567.33 MB/s| +57.2%   |
| 1MB       | 2593.39 MB/s  | 1064.65 MB/s| +143.6%  |
| 4MB       | 2686.46 MB/s  | 1897.90 MB/s| +41.6%   |

**结论**：
- 小包场景（< 1KB）：UDS 性能略优，因为 Shmipc 的协议开销相对较大
- 大包场景（>= 4KB）：Shmipc 性能显著提升，零拷贝优势明显
- 超大包场景（>= 256KB）：Shmipc 性能优势达到 50% 以上