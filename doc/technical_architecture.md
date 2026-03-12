# Shmipc 技术架构深度分析

## 概述

Shmipc 是一个基于共享内存的高性能进程间通信库，通过零拷贝技术和批量 IO 机制，在大 IO 场景下显著提升性能。本文档详细分析其技术架构和实现原理。

## 核心架构组件

### 1. Session 层

#### Session 结构体

```go
type Session struct {
    nextStreamID uint32           // 下一个流ID
    config       *Config          // 配置
    logger       *logger          // 日志
    dispatcher   dispatcher      // 事件分发器
    connFd       int             // 连接文件描述符
    netConn      net.Conn        // 网络连接（用于地址获取）
    eventConn    eventConn       // 事件连接
    streams      map[uint32]*Stream  // 流映射表
    streamLock   sync.RWMutex     // 流锁
    acceptCh     chan *Stream      // 接收通道
    sendCh       chan sendReady    // 发送通道
    shutdown     uint32           // 关闭标志
    isClient     bool             // 是否客户端
    bufferManager *bufferManager  // 缓冲区管理器
    queueManager  *queueManager   // 队列管理器
    communicationVersion uint8     // 通信协议版本
}
```

#### Session 初始化方法

```go
func newSession(config *Config, conn net.Conn, isClient bool) (*Session, error) {
    // 1. 验证配置
    if err := VerifyConfig(config); err != nil {
        return nil, fmt.Errorf("VerifyConfig failed: %s", err.Error())
    }

    // 2. 获取连接文件描述符
    fd, err := getConnDupFd(conn)
    if err != nil {
        return nil, fmt.Errorf("could get fd from conn,reason=%s", err.Error())
    }
    defer conn.Close()

    // 3. 初始化 Session 结构体
    s := &Session{
        config:                config,
        dispatcher:            defaultDispatcher,
        connFd:                int(fd.Fd()),
        netConn:               conn,
        logger:                newSessionLogger(isClient, config.LogOutput),
        streams:               make(map[uint32]*Stream, 4096),
        sendCh:                make(chan sendReady, 4096),
        isClient:              isClient,
        communicationVersion:  protoVersion,
    }

    // 4. 客户端模式设置
    if isClient {
        s.nextStreamID = 1  // 客户端使用奇数ID
    } else {
        s.nextStreamID = 2  // 服务端使用偶数ID
        s.acceptCh = make(chan *Stream, 1024)
    }

    // 5. 初始化内存管理器
    if err := s.initMemManager(); err != nil {
        return nil, fmt.Errorf("create share memory buffer manager failed ,error=%w", err)
    }

    // 6. 初始化协议
    if err := s.initProtocol(); err != nil {
        return nil, err
    }

    // 7. 设置事件连接
    s.eventConn = s.dispatcher.newConnection(fd)
    if err := s.eventConn.setCallback(s); err != nil {
        return nil, err
    }

    // 8. 启动后台goroutine
    go s.send()      // 发送goroutine
    go s.monitorLoop() // 监控goroutine

    return s, nil
}
```

### 2. Stream 层

#### Stream 结构体

```go
type Stream struct {
    id              uint32             // 流ID
    state           uint32             // 流状态
    session         *Session           // 所属会话
    recvBuf         *linkedBuffer      // 接收缓冲区
    sendBuf         *linkedBuffer      // 发送缓冲区
    pendingData     *pendingData       // 待处理数据
    recvNotifyCh    chan struct{}      // 接收通知通道
    closeNotifyCh   chan struct{}      // 关闭通知通道
    readDeadline    time.Time          // 读取超时
    writeDeadline   time.Time          // 写入超时
    inFallbackState bool               // 是否处于降级状态
    callback        *StreamCallbacks    // 回调函数
}
```

#### Stream 创建方法

```go
func newStream(session *Session, id uint32) *Stream {
    s := &Stream{
        id:            id,
        session:       session,
        state:         uint32(streamOpened),
        recvBuf:       newEmptyLinkedBuffer(session.bufferManager),
        sendBuf:       newEmptyLinkedBuffer(session.bufferManager),
        pendingData:   new(pendingData),
        recvNotifyCh:  make(chan struct{}, 1),
        closeNotifyCh: make(chan struct{}),
    }
    s.recvBuf.bindStream(s)
    s.sendBuf.bindStream(s)
    s.pendingData.stream = s
    return s
}
```

### 3. Buffer 层

#### linkedBuffer 结构体

```go
type linkedBuffer struct {
    recycleMux    sync.Mutex          // 回收锁
    sliceList     *sliceList         // 切片链表
    bufferManager *bufferManager     // 缓冲区管理器
    stream        *Stream            // 所属流
    pinnedList    *sliceList         // 固定列表
    currentPinned bool               // 当前是否固定
    endStream     bool               // 流结束标志
    isFromShm     bool             // 是否来自共享内存
    len           int                // 长度
}
```

#### 零拷贝写入接口

```go
func (l *linkedBuffer) Reserve(size int) ([]byte, error) {
    // 1. 尝试使用当前切片
    if l.sliceList.writeSlice == nil {
        l.alloc(uint32(size))
        l.sliceList.writeSlice = l.sliceList.front()
    }
    ret, err := l.sliceList.writeSlice.reserve(size)
    if err == nil {
        l.len += size
        return ret, err
    }

    // 2. 尝试使用下一个切片
    if e := l.sliceList.writeSlice.next(); e != nil {
        ret, err = e.reserve(size)
        if err == nil {
            l.sliceList.writeSlice = e
            l.len += size
            return ret, err
        }
    }

    // 3. 分配新切片
    buf, err := l.bufferManager.allocShmBuffer(uint32(size))
    if err == nil {
        l.sliceList.pushBack(buf)
    } else {
        // 降级到普通内存
        allocSize := size
        if allocSize < defaultSingleBufferSize {
            allocSize = defaultSingleBufferSize
        }
        l.sliceList.pushBack(newBufferSlice(nil, make([]byte, allocSize), 0, false))
        l.isFromShm = false
    }
    l.sliceList.writeSlice = l.sliceList.back()
    l.len += size
    return l.sliceList.writeSlice.reserve(size)
}
```

#### 零拷贝读取接口

```go
func (l *linkedBuffer) ReadBytes(size int) (result []byte, err error) {
    if size <= 0 {
        return
    }
    
    // 1. 检查数据是否足够
    if l.len < size {
        if err = l.stream.readMore(size); err != nil {
            return nil, err
        }
    }

    // 2. 快速路径：单个切片包含所需数据
    if l.sliceList.front().size() == 0 {
        l.readNextSlice()
    }

    if l.sliceList.front().size() >= size {
        l.currentPinned = true
        l.len -= size
        return l.sliceList.front().read(size)
    }

    // 3. 慢速路径：跨多个切片
    l.len -= size
    result = dirtmake.Bytes(0, size)

    for size > 0 {
        readData, _ := l.sliceList.front().read(size)
        result = append(result, readData...)
        if len(readData) != size {
            l.readNextSlice()
        }
        size -= len(readData)
    }
    return
}
```

### 4. 共享内存管理

#### BufferManager 结构体

```go
type bufferManager struct {
    lists        []*bufferList      // 缓冲区列表
    mem          []byte            // 共享内存
    minSliceSize uint32           // 最小切片大小
    maxSliceSize uint32           // 最大切片大小
    path         string            // 共享内存路径
    refCount     int32            // 引用计数
    mmapMapType  MemMapType       // 内存映射类型
    memFd        int               // 内存文件描述符
}
```

#### BufferList 结构体

```go
type bufferList struct {
    size         *int32            // 空闲缓冲区数量
    cap          *uint32           // 容量
    head         *uint32           // 头指针
    tail         *uint32           // 尾指针
    capPerBuffer *uint32           // 单个缓冲区容量
    counter      *int32            // 计数器
    bufferRegion            []byte  // 缓冲区区域
    bufferRegionOffsetInShm uint32  // 缓冲区在共享内存中的偏移
    offsetInShm uint32            // 在共享内存中的偏移
}
```

#### 共享内存分配

```go
func (b *bufferManager) allocShmBuffer(size uint32) (*bufferSlice, error) {
    if size <= b.maxSliceSize {
        for i := range b.lists {
            if size <= *b.lists[i].capPerBuffer {
                buf, err := b.lists[i].pop()
                if err != nil {
                    continue
                }
                return buf, nil
            }
        }
    }
    return nil, ErrNoMoreBuffer
}
```

#### 共享内存回收

```go
func (b *bufferManager) recycleBuffer(slice *bufferSlice) {
    if slice == nil {
        return
    }
    if slice.isFromShm {
        for i := range b.lists {
            if slice.cap == *b.lists[i].capPerBuffer {
                b.lists[i].push(slice)
                break
            }
        }
    }
    putBackBufferSlice(slice)
}
```

### 5. 队列管理

#### Queue 结构体

```go
type queue struct {
    sync.Mutex
    head               *int64  // 消费者写入，生产者读取
    tail               *int64  // 生产者写入，消费者读取
    workingFlag        *uint32 // 工作标志
    cap                int64   // 容量
    queueBytesOnMemory []byte  // 队列内存
}
```

#### 队列元素

```go
type queueElement struct {
    seqID          uint32  // 流ID
    offsetInShmBuf uint32  // 在共享内存缓冲区中的偏移
    status         uint32  // 状态
}
```

#### 队列写入

```go
func (q *queue) put(e queueElement) error {
    q.Lock()
    tail := atomic.LoadInt64(q.tail)
    if tail-atomic.LoadInt64(q.head) >= q.cap {
        q.Unlock()
        return ErrQueueFull
    }
    queueOffset := (tail % q.cap) * queueElementLen
    *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset])) = e.seqID
    *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset+4])) = e.offsetInShmBuf
    *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset+8])) = e.status
    atomic.AddInt64(q.tail, 1)
    q.Unlock()
    return nil
}
```

#### 队列读取

```go
func (q *queue) pop() (e queueElement, err error) {
    head := atomic.LoadInt64(q.head)
    if head >= atomic.LoadInt64(q.tail) {
        err = errQueueEmpty
        return
    }
    queueOffset := (head % q.cap) * queueElementLen
    e.seqID = *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset]))
    e.offsetInShmBuf = *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset+4]))
    e.status = *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset+8]))
    atomic.AddInt64(q.head, 1)
    return
}
```

## 协议初始化流程

### V3 协议客户端初始化

```go
func (p *protocolInitializerV3) clientInit() error {
    var err error
    memType := p.session.config.MemMapType
    switch memType {
    case MemMapTypeDevShmFile:
        err = sendShareMemoryByFilePath(p.session)
    case MemMapTypeMemFd:
        err = sendMemFdToPeer(p.session)
    default:
        err = fmt.Errorf("unknown memory type:%d", memType)
    }

    if err != nil {
        return err
    }
    _, err = waitEventHeader(p.session.connFd, typeAckShareMemory)

    return err
}
```

### V3 协议服务端初始化

```go
func (p *protocolInitializerV3) serverInit() error {
    // 1. 交换版本
    if err := handleExchangeVersion(p.session, p.firstEvent); err != nil {
        return errors.New("protocolInitializerV3 exchangeVersion failed, reason:" + err.Error())
    }

    // 2. 接收并映射共享内存
    h, err := blockReadEventHeader(p.session.connFd)
    if err != nil {
        return errors.New("protocolInitializerV3 blockReadEventHeader failed,reason:" + err.Error())
    }
    switch h.MsgType() {
    case typeShareMemoryByFilePath:
        err = handleShareMemoryByFilePath(p.session, h)
    case typeShareMemoryByMemfd:
        err = handleShareMemoryByMemFd(p.session, h)
    default:
        return fmt.Errorf("expect event type is typeShareMemoryByFilePath or typeShareMemoryByMemfd but:%d %s",
            h.MsgType(), h.MsgType().String())
    }

    if err != nil {
        return err
    }

    // 3. 确认共享内存
    respHeader := header(make([]byte, headerSize))
    respHeader.encode(headerSize, p.session.communicationVersion, typeAckShareMemory)
    protocolTrace(respHeader, nil, true)
    return blockWriteFull(p.session.connFd, respHeader)
}
```

## 数据传输流程

### 客户端发送数据

```go
func (s *Stream) Flush(endStream bool) error {
    if s.sendBuf.Len() == 0 {
        return nil
    }
    
    // 1. 更新统计信息
    atomic.AddUint64(&s.session.stats.outFlowBytes, uint64(s.sendBuf.Len()))
    
    // 2. 检查流状态
    state := s.getStreamState()
    if state != uint32(streamOpened) {
        s.sendBuf.recycle()
        return ErrStreamClosed
    }
    
    // 3. 完成写入缓冲区
    s.sendBuf.done(endStream)
    defer s.sendBuf.clean()
    
    // 4. 检查是否需要降级
    if !s.sendBuf.isFromShareMemory() {
        s.inFallbackState = true
    }
    if s.inFallbackState {
        return s.writeFallback(s.state, ErrNoMoreBuffer)
    }
    
    // 5. 将数据元信息放入发送队列
    buf := s.sendBuf
    err := s.session.sendQueue().put(queueElement{
        seqID:          s.id,
        offsetInShmBuf: buf.rootBufOffset(),
        status:         state,
    })
    
    // 6. 处理队列满情况
    if err == ErrQueueFull {
        atomic.AddUint64(&s.session.stats.queueFullErrorCount, 1)
        var writeDeadlineCh <-chan time.Time
        if !s.writeDeadline.IsZero() {
            writeDeadlineCh = time.NewTimer(s.writeDeadline.Sub(time.Now())).C
        }
        // 重试10次
        for i := 0; err == ErrQueueFull && i < 10; i++ {
            retryTimer := time.NewTimer(10 * time.Millisecond)
            select {
            case <-retryTimer.C:
                err = s.session.sendQueue().put(queueElement{
                    seqID:          s.id,
                    offsetInShmBuf: buf.rootBufOffset(),
                    status:         state,
                })
            case <-writeDeadlineCh:
                err = ErrTimeout
            case <-s.closeNotifyCh:
                err = ErrStreamClosed
            }
        }
    }
    
    if err != nil {
        buf.recycle()
        return err
    }
    
    // 7. 唤醒对端
    return s.session.wakeUpPeer()
}
```

### 服务端接收数据

```go
func handlePolling(s *Session, hdr header, buf []byte) (int, bool, error) {
    atomic.AddUint64(&s.stats.recvPollingEventCount, 1)
    consumedCount := 0
    var retErr error
    
    // 1. 批量处理队列中的元素
    for {
        for ele, err := s.queueManager.recvQueue.pop(); err == nil; ele, err = s.queueManager.recvQueue.pop() {
            consumedCount++
            state := streamState(ele.status & 0xff)
            stream := s.getStream(ele.seqID, state)
            
            // 2. 处理流不存在的情况
            if stream == nil && state == streamOpened {
                slice, err := s.bufferManager.readBufferSlice(ele.offsetInShmBuf)
                if err != nil {
                    return headerSize, false, err
                }
                s.bufferManager.recycleBuffers(slice)
                continue
            }
            
            if stream == nil {
                continue
            }
            
            // 3. 处理流消息
            retErr = s.handleStreamMessage(stream, bufferSliceWrapper{offset: ele.offsetInShmBuf}, state)
        }

        runtime.Gosched()
        
        // 4. 标记工作状态
        if s.queueManager.recvQueue.markNotWorking() {
            break
        }
    }
    
    return headerSize, false, retErr
}
```

## 与原生 Socket 对比

### 原生 Socket 通信流程

#### 客户端发送数据

```go
// 原生 Socket 写入
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

**系统调用流程**：
1. 应用程序调用 `conn.Write()`
2. 数据从用户态缓冲区拷贝到内核态发送缓冲区
3. 内核协议栈处理数据
4. 数据从内核态拷贝到接收进程的内核态接收缓冲区
5. 接收进程通过系统调用将数据从内核态拷贝到用户态

#### 服务端接收数据

```go
// 原生 Socket 读取
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

### Shmipc 通信流程

#### 客户端发送数据

```go
// Shmipc 零拷贝写入
func mustWrite(s *Stream, bodySize string, b *testing.B) {
    request := pingpong{
        Data: make([]byte, dataSizes[bodySize]),
    }
    
    // 1. 直接预留共享内存空间（零拷贝）
    reserve, err := s.BufferWriter().Reserve(likelySizes[bodySize])
    if err != nil {
        panic(err)
    }

    // 2. 直接在共享内存中序列化数据
    buf := bytes.NewBuffer(reserve)
    buf.Reset()
    encoder := json.NewEncoder(buf)
    err = encoder.Encode.encode(request)
    if err != nil {
        panic(err)
    }

    // 3. 刷新数据到对端
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

**零拷贝流程**：
1. 应用程序调用 `BufferWriter().Reserve()` 直接预留共享内存空间
2. 数据直接写入共享内存（无拷贝）
3. 将数据元信息放入共享内存队列
4. 通过 Unix Domain Socket 发送通知消息
5. 对端收到通知后，直接从共享内存读取数据（无拷贝）

#### 服务端接收数据

```go
// Shmipc 零拷贝读取
func mustRead(s *Stream, size int, b *testing.B) bool {
    // 直接从共享内存读取（零拷贝）
    _, err := s.BufferReader().ReadBytes(size)
    if err == ErrStreamClosed || err == ErrEndOfStream {
        return false
    } else if err != nil {
        panic(fmt.Sprintf("err: %s", err.Error()))
    }
    return true
}
```

### 关键差异对比

| 特性 | 原生 Socket | Shmipc |
|------|-------------|---------|
| **数据拷贝次数** | 4次（用户态→内核态×2） | 0次（直接共享内存） |
| **系统调用频率** | 每次读写都需要系统调用 | 批量处理，减少系统调用 |
| **内存分配** | 动态分配用户态缓冲区 | 预分配共享内存池 |
| **同步机制** | 内核锁 | 无锁队列 + 原子操作 |
| **大包性能** | 受限于内核缓冲区大小 | 受限于共享内存大小 |
| **小包性能** | 相对较好 | 协议开销相对较大 |

### 性能优化技术

#### 1. 零拷贝技术

```go
// 直接预留共享内存空间
reserve, err := s.BufferWriter().Reserve(size)

// 直接在预留空间中操作数据
copy(reserve, data)

// 对端直接读取共享内存
data, err := s.BufferReader().ReadBytes(size)
```

#### 2. 批量 IO 处理

```go
// 批量处理队列中的元素
for {
    for ele, err := s.queueManager.recvQueue.pop(); err == nil; ele, err = s.queueManager.recvQueue.pop() {
        // 处理多个元素
        consumedCount++
        retErr = s.handleStreamMessage(stream, bufferSliceWrapper{offset: ele.offsetInShmBuf}, state)
    }
    
    // 一次系统调用处理多个元素
    if s.queueManager.recvQueue.markNotWorking() {
        break
    }
}
```

#### 3. 内存池技术

```go
// 预分配共享内存池
func createBufferManager(listSizePercent []*SizePercentPair, path string, mem []byte, offset uint32) (*bufferManager, error) {
    // 根据配置预分配不同大小的缓冲区
    for _, pair := range listSizePercent {
        bufferNum := uint32(bufferRegionCap*uint64(pair.Percent)/100) / (pair.Size + bufferHeaderSize)
        freeList, err := createFreeBufferList(bufferNum, pair.Size, mem, hadUsedOffset)
        if err != nil {
            return nil, err
        }
        freeBufferLists = append(freeBufferLists, freeList)
    }
    return ret, nil
}
```

#### 4. 无锁队列

```go
// 无锁队列写入
func (q *queue) put(e queueElement) error {
    q.Lock()
    tail := atomic.LoadInt64(q.tail)
    if tail-atomic.LoadInt64(q.head) >= q.cap {
        q.Unlock()
        return ErrQueueFull
    }
    // 直接写入共享内存
    queueOffset := (tail % q.cap) * queueElementLen
    *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset])) = e.seqID
    *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset+4])) = e.offsetInShmBuf
    *(*uint32)(unsafe.Pointer(&q.queueBytesOnMemory[queueOffset+8])) = e.status
    atomic.AddInt64(q.tail, 1)
    q.Unlock()
    return nil
}
```

## 总结

Shmipc 通过以下关键技术实现了高性能进程间通信：

1. **零拷贝技术**：数据直接在共享内存中传输，避免用户态和内核态之间的数据拷贝
2. **批量 IO 处理**：通过队列机制实现批量处理，减少系统调用次数
3. **内存池管理**：预分配共享内存池，减少动态内存分配开销
4. **无锁队列**：使用原子操作实现无锁队列，提高并发性能
5. **智能降级**：当共享内存不足时，自动降级到传统 socket 通信

这些技术使得 Shmipc 在大包场景下性能显著优于原生 Unix Domain Socket，特别适合 IO 密集型和高吞吐量的应用场景。