/*
 * shmipc-bridge - Go CGO 桥接层（优化版）
 * 
 * 功能：将 shmipc-go 核心库的功能导出为 C 可调用的接口
 * 
 * 优化内容：
 *   1. 使用 Reserve() API 消除 CGO 数据拷贝
 *   2. 增大默认共享内存缓冲区
 *   3. 添加批量 IO 接口
 *   4. 添加性能统计接口
 * 
 * 编译方式：
 *   go build -buildmode=c-shared -o libshmipc_go.so shmipc_bridge.go
 */

package main

import "C"
import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/cloudwego/shmipc-go"
)

var (
	mu       sync.RWMutex
	sessions = make(map[int]*shmipc.Session)
	streams  = make(map[int]*shmipc.Stream)
	config   *shmipc.Config

	perfStats struct {
		totalWrites     uint64
		totalReads      uint64
		totalWriteBytes uint64
		totalReadBytes  uint64
		cgoCopyBytes    uint64
		reserveHits     uint64
		reserveMisses   uint64
	}
)

func init() {
	loadConfig()
}

func loadConfig() {
	config = shmipc.DefaultConfig()
	config.QueueCap = 8192
	config.ShareMemoryBufferCap = 256 * 1024 * 1024
	config.MemMapType = shmipc.MemMapTypeMemFd

	if cap := os.Getenv("SHMIPC_QUEUE_CAP"); cap != "" {
		if c, err := strconv.ParseUint(cap, 10, 32); err == nil {
			config.QueueCap = uint32(c)
		}
	}

	if size := os.Getenv("SHMIPC_BUFFER_SIZE"); size != "" {
		if s, err := strconv.ParseUint(size, 10, 32); err == nil {
			config.ShareMemoryBufferCap = uint32(s)
		}
	}

	if batch := os.Getenv("SHMIPC_BATCH_SIZE"); batch != "" {
		if b, err := strconv.ParseUint(batch, 10, 32); err == nil {
			_ = b
		}
	}

	logLevel := os.Getenv("SHMIPC_LOG_LEVEL")
	if logLevel != "" {
		fmt.Printf("[shmipc-bridge] Config: BufferSize=%dMB, QueueCap=%d\n",
			config.ShareMemoryBufferCap/(1024*1024), config.QueueCap)
	}
}

func getShmipcConfig(path string) *shmipc.Config {
	c := *config
	c.ShareMemoryPathPrefix = path
	return &c
}

//export ShmipcInit
func ShmipcInit() C.int {
	return C.int(0)
}

//export ShmipcCleanup
func ShmipcCleanup() {
	mu.Lock()
	defer mu.Unlock()

	for _, session := range sessions {
		session.Close()
	}
	sessions = make(map[int]*shmipc.Session)
	streams = make(map[int]*shmipc.Stream)
}

//export ShmipcCreateClientSession
func ShmipcCreateClientSession(fd C.int, path *C.char) C.int {
	goPath := C.GoString(path)

	mu.Lock()
	defer mu.Unlock()

	if _, exists := sessions[int(fd)]; exists {
		return C.int(-1)
	}

	file := os.NewFile(uintptr(fd), "unix")
	if file == nil {
		return C.int(-2)
	}

	conn, err := net.FileConn(file)
	if err != nil {
		return C.int(-3)
	}

	shmConfig := getShmipcConfig(goPath + "_client")

	session, err := shmipc.Client(conn, shmConfig)
	if err != nil {
		conn.Close()
		return C.int(-4)
	}

	sessions[int(fd)] = session
	return C.int(0)
}

//export ShmipcCreateServerSession
func ShmipcCreateServerSession(fd C.int, path *C.char) C.int {
	goPath := C.GoString(path)

	mu.Lock()
	defer mu.Unlock()

	if _, exists := sessions[int(fd)]; exists {
		return C.int(-1)
	}

	file := os.NewFile(uintptr(fd), "unix")
	if file == nil {
		return C.int(-2)
	}

	conn, err := net.FileConn(file)
	if err != nil {
		return C.int(-3)
	}

	shmConfig := getShmipcConfig(goPath + "_server")

	session, err := shmipc.Server(conn, shmConfig)
	if err != nil {
		conn.Close()
		return C.int(-4)
	}

	sessions[int(fd)] = session
	return C.int(0)
}

//export ShmipcOpenStream
func ShmipcOpenStream(fd C.int) C.int {
	mu.Lock()
	defer mu.Unlock()

	session, exists := sessions[int(fd)]
	if !exists {
		return C.int(-1)
	}

	stream, err := session.OpenStream()
	if err != nil {
		return C.int(-2)
	}

	streamID := int(stream.StreamID())
	streams[streamID] = stream
	return C.int(streamID)
}

//export ShmipcAcceptStream
func ShmipcAcceptStream(fd C.int) C.int {
	mu.Lock()
	session, exists := sessions[int(fd)]
	mu.Unlock()

	if !exists {
		return C.int(-1)
	}

	stream, err := session.AcceptStream()
	if err != nil {
		return C.int(-2)
	}

	mu.Lock()
	streamID := int(stream.StreamID())
	streams[streamID] = stream
	mu.Unlock()

	return C.int(streamID)
}

//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists {
		return C.long(-1)
	}

	writer := stream.BufferWriter()

	buf, err := writer.Reserve(int(length))
	if err != nil {
		atomic.AddUint64(&perfStats.reserveMisses, 1)
		fallbackBuf := C.GoBytes(data, C.int(length))
		n, err := writer.WriteBytes(fallbackBuf)
		if err != nil {
			return C.long(-2)
		}
		atomic.AddUint64(&perfStats.cgoCopyBytes, uint64(n))
		err = stream.Flush(false)
		if err != nil {
			return C.long(-3)
		}
		atomic.AddUint64(&perfStats.totalWrites, 1)
		atomic.AddUint64(&perfStats.totalWriteBytes, uint64(n))
		return C.long(n)
	}

	atomic.AddUint64(&perfStats.reserveHits, 1)

	copy(buf, (*[1 << 30]byte)(data)[:length])

	err = stream.Flush(false)
	if err != nil {
		return C.long(-3)
	}

	atomic.AddUint64(&perfStats.totalWrites, 1)
	atomic.AddUint64(&perfStats.totalWriteBytes, uint64(length))

	return C.long(length)
}

//export ShmipcWriteBatch
func ShmipcWriteBatch(streamID C.int, iov unsafe.Pointer, iovcnt C.int) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists {
		return C.long(-1)
	}

	type iovec struct {
		iov_base unsafe.Pointer
		iov_len  C.size_t
	}

	goIOV := (*[1 << 20]iovec)(iov)[:iovcnt:iovcnt]
	writer := stream.BufferWriter()
	totalLen := 0

	for i := 0; i < int(iovcnt); i++ {
		dataLen := goIOV[i].iov_len
		if dataLen == 0 {
			continue
		}

		buf, err := writer.Reserve(int(dataLen))
		if err != nil {
			cbuf := C.GoBytes(goIOV[i].iov_base, C.int(dataLen))
			writer.WriteBytes(cbuf)
			atomic.AddUint64(&perfStats.cgoCopyBytes, uint64(dataLen))
		} else {
			copy(buf, (*[1 << 30]byte)(goIOV[i].iov_base)[:dataLen])
			atomic.AddUint64(&perfStats.reserveHits, 1)
		}
		totalLen += int(dataLen)
	}

	err := stream.Flush(false)
	if err != nil {
		return C.long(-3)
	}

	atomic.AddUint64(&perfStats.totalWrites, 1)
	atomic.AddUint64(&perfStats.totalWriteBytes, uint64(totalLen))

	return C.long(totalLen)
}

//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists {
		return C.long(-1)
	}

	reader := stream.BufferReader()

	buf, err := reader.Peek(int(length))
	if err != nil {
		return C.long(-2)
	}

	copy((*[1 << 30]byte)(data)[:len(buf)], buf)

	reader.Discard(len(buf))
	stream.ReleaseReadAndReuse()

	atomic.AddUint64(&perfStats.totalReads, 1)
	atomic.AddUint64(&perfStats.totalReadBytes, uint64(len(buf)))

	return C.long(len(buf))
}

//export ShmipcReadBatch
func ShmipcReadBatch(streamID C.int, iov unsafe.Pointer, iovcnt C.int) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists {
		return C.long(-1)
	}

	type iovec struct {
		iov_base unsafe.Pointer
		iov_len  C.size_t
	}

	goIOV := (*[1 << 20]iovec)(iov)[:iovcnt:iovcnt]
	reader := stream.BufferReader()
	totalLen := 0

	for i := 0; i < int(iovcnt); i++ {
		dataLen := goIOV[i].iov_len
		if dataLen == 0 {
			continue
		}

		buf, err := reader.Peek(int(dataLen))
		if err != nil {
			break
		}

		copy((*[1 << 30]byte)(goIOV[i].iov_base)[:len(buf)], buf)
		reader.Discard(len(buf))
		totalLen += len(buf)
	}

	stream.ReleaseReadAndReuse()

	atomic.AddUint64(&perfStats.totalReads, 1)
	atomic.AddUint64(&perfStats.totalReadBytes, uint64(totalLen))

	return C.long(totalLen)
}

//export ShmipcCloseStream
func ShmipcCloseStream(streamID C.int) C.int {
	mu.Lock()
	defer mu.Unlock()

	stream, exists := streams[int(streamID)]
	if !exists {
		return C.int(-1)
	}

	err := stream.Close()
	delete(streams, int(streamID))

	if err != nil {
		return C.int(-2)
	}

	return C.int(0)
}

//export ShmipcCloseSession
func ShmipcCloseSession(fd C.int) C.int {
	mu.Lock()
	defer mu.Unlock()

	session, exists := sessions[int(fd)]
	if !exists {
		return C.int(-1)
	}

	err := session.Close()
	delete(sessions, int(fd))

	if err != nil {
		return C.int(-2)
	}

	return C.int(0)
}

//export ShmipcGetStats
func ShmipcGetStats(stats unsafe.Pointer) C.int {
	type Stats struct {
		TotalConnections    uint64
		ShmipcConnections   uint64
		SocketConnections   uint64
		TotalBytesSent      uint64
		TotalBytesRecv      uint64
		ShmipcBytesSent     uint64
		ShmipcBytesRecv     uint64
		TotalWrites         uint64
		TotalReads          uint64
		TotalWriteBytes     uint64
		TotalReadBytes      uint64
		CgoCopyBytes        uint64
		ReserveHits         uint64
		ReserveMisses       uint64
	}

	mu.RLock()
	defer mu.RUnlock()

	s := Stats{
		TotalConnections:  uint64(len(sessions)),
		ShmipcConnections: uint64(len(sessions)),
		TotalWrites:       atomic.LoadUint64(&perfStats.totalWrites),
		TotalReads:        atomic.LoadUint64(&perfStats.totalReads),
		TotalWriteBytes:   atomic.LoadUint64(&perfStats.totalWriteBytes),
		TotalReadBytes:    atomic.LoadUint64(&perfStats.totalReadBytes),
		CgoCopyBytes:      atomic.LoadUint64(&perfStats.cgoCopyBytes),
		ReserveHits:       atomic.LoadUint64(&perfStats.reserveHits),
		ReserveMisses:     atomic.LoadUint64(&perfStats.reserveMisses),
	}

	buf := make([]byte, 120)
	binary.LittleEndian.PutUint64(buf[0:8], s.TotalConnections)
	binary.LittleEndian.PutUint64(buf[8:16], s.ShmipcConnections)
	binary.LittleEndian.PutUint64(buf[16:24], s.SocketConnections)
	binary.LittleEndian.PutUint64(buf[24:32], s.TotalBytesSent)
	binary.LittleEndian.PutUint64(buf[32:40], s.TotalBytesRecv)
	binary.LittleEndian.PutUint64(buf[40:48], s.ShmipcBytesSent)
	binary.LittleEndian.PutUint64(buf[48:56], s.ShmipcBytesRecv)
	binary.LittleEndian.PutUint64(buf[56:64], s.TotalWrites)
	binary.LittleEndian.PutUint64(buf[64:72], s.TotalReads)
	binary.LittleEndian.PutUint64(buf[72:80], s.TotalWriteBytes)
	binary.LittleEndian.PutUint64(buf[80:88], s.TotalReadBytes)
	binary.LittleEndian.PutUint64(buf[88:96], s.CgoCopyBytes)
	binary.LittleEndian.PutUint64(buf[96:104], s.ReserveHits)
	binary.LittleEndian.PutUint64(buf[104:112], s.ReserveMisses)

	copy((*[120]byte)(stats)[:], buf)

	return C.int(0)
}

//export ShmipcPrintStats
func ShmipcPrintStats() {
	totalWrites := atomic.LoadUint64(&perfStats.totalWrites)
	totalReads := atomic.LoadUint64(&perfStats.totalReads)
	totalWriteBytes := atomic.LoadUint64(&perfStats.totalWriteBytes)
	totalReadBytes := atomic.LoadUint64(&perfStats.totalReadBytes)
	cgoCopyBytes := atomic.LoadUint64(&perfStats.cgoCopyBytes)
	reserveHits := atomic.LoadUint64(&perfStats.reserveHits)
	reserveMisses := atomic.LoadUint64(&perfStats.reserveMisses)

	fmt.Printf("\n=== shmipc-bridge Performance Stats ===\n")
	fmt.Printf("Total Writes:      %d\n", totalWrites)
	fmt.Printf("Total Reads:       %d\n", totalReads)
	fmt.Printf("Total Write Bytes: %d (%.2f MB)\n", totalWriteBytes, float64(totalWriteBytes)/(1024*1024))
	fmt.Printf("Total Read Bytes:  %d (%.2f MB)\n", totalReadBytes, float64(totalReadBytes)/(1024*1024))
	fmt.Printf("CGO Copy Bytes:    %d (%.2f MB)\n", cgoCopyBytes, float64(cgoCopyBytes)/(1024*1024))
	fmt.Printf("Reserve Hits:      %d (%.2f%%)\n", reserveHits, float64(reserveHits)/float64(reserveHits+reserveMisses+1)*100)
	fmt.Printf("Reserve Misses:    %d\n", reserveMisses)
	fmt.Printf("======================================\n\n")
}

func main() {
	fmt.Println("shmipc-bridge: This is a shared library")
	fmt.Println("Usage: LD_PRELOAD=./libshmipc.so <your-program>")
	fmt.Println("\nOptimizations enabled:")
	fmt.Println("  - Zero-copy write using Reserve() API")
	fmt.Println("  - Zero-copy read using Peek() API")
	fmt.Println("  - Large buffer size: 256MB (configurable via SHMIPC_BUFFER_SIZE)")
	fmt.Println("  - Batch I/O support (ShmipcWriteBatch/ShmipcReadBatch)")
}
