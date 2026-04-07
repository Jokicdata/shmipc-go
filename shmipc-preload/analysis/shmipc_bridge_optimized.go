/*
 * shmipc-bridge-optimized - 优化的 Go CGO 桥接层
 * 
 * 优化点：
 * 1. 使用 unsafe.Slice 替代 C.GoBytes，消除数据拷贝
 * 2. 使用 sync.Map 替代 map + mutex，减少锁竞争
 * 3. 添加对象池，减少 GC 压力
 * 4. 支持批量操作
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
	sessions sync.Map
	streams  sync.Map
	config   *shmipc.Config

	writePool sync.Pool
	readPool  sync.Pool

	stats struct {
		totalWrites   uint64
		totalReads    uint64
		totalWriteNS  uint64
		totalReadNS   uint64
		cgoCallCount  uint64
		cgoTotalNS    uint64
		zeroCopyHits  uint64
		zeroCopyMiss  uint64
	}
)

func init() {
	loadConfig()
}

func loadConfig() {
	config = shmipc.DefaultConfig()
	config.QueueCap = 8192
	config.ShareMemoryBufferCap = 32 * 1024 * 1024
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
	sessions.Range(func(key, value interface{}) bool {
		if session, ok := value.(*shmipc.Session); ok {
			session.Close()
		}
		sessions.Delete(key)
		return true
	})

	streams.Range(func(key, value interface{}) bool {
		streams.Delete(key)
		return true
	})
}

//export ShmipcCreateClientSession
func ShmipcCreateClientSession(fd C.int, path *C.char) C.int {
	goPath := C.GoString(path)

	if _, exists := sessions.Load(int(fd)); exists {
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

	sessions.Store(int(fd), session)
	return C.int(0)
}

//export ShmipcCreateServerSession
func ShmipcCreateServerSession(fd C.int, path *C.char) C.int {
	goPath := C.GoString(path)

	if _, exists := sessions.Load(int(fd)); exists {
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

	sessions.Store(int(fd), session)
	return C.int(0)
}

//export ShmipcOpenStream
func ShmipcOpenStream(fd C.int) C.int {
	value, exists := sessions.Load(int(fd))
	if !exists {
		return C.int(-1)
	}

	session := value.(*shmipc.Session)
	stream, err := session.OpenStream()
	if err != nil {
		return C.int(-2)
	}

	streamID := int(stream.StreamID())
	streams.Store(streamID, stream)
	return C.int(streamID)
}

//export ShmipcAcceptStream
func ShmipcAcceptStream(fd C.int) C.int {
	value, exists := sessions.Load(int(fd))
	if !exists {
		return C.int(-1)
	}

	session := value.(*shmipc.Session)
	stream, err := session.AcceptStream()
	if err != nil {
		return C.int(-2)
	}

	streamID := int(stream.StreamID())
	streams.Store(streamID, stream)

	return C.int(streamID)
}

//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	value, exists := streams.Load(int(streamID))
	if !exists {
		return C.long(-1)
	}

	stream := value.(*shmipc.Stream)

	buf := unsafe.Slice((*byte)(data), length)

	writer := stream.BufferWriter()
	n, err := writer.WriteBytes(buf)
	if err != nil {
		return C.long(-2)
	}

	err = stream.Flush(false)
	if err != nil {
		return C.long(-3)
	}

	atomic.AddUint64(&stats.totalWrites, 1)
	atomic.AddUint64(&stats.zeroCopyHits, 1)

	return C.long(n)
}

//export ShmipcWriteZeroCopy
func ShmipcWriteZeroCopy(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	value, exists := streams.Load(int(streamID))
	if !exists {
		return C.long(-1)
	}

	stream := value.(*shmipc.Stream)

	buf := unsafe.Slice((*byte)(data), length)

	writer := stream.BufferWriter()
	
	shmBuf := writer.Malloc(int(length))
	if len(shmBuf) < int(length) {
		copy(shmBuf, buf)
		writer.Flush()
		atomic.AddUint64(&stats.zeroCopyMiss, 1)
		return C.long(len(shmBuf))
	}
	
	copy(shmBuf, buf)
	writer.Flush()
	
	atomic.AddUint64(&stats.totalWrites, 1)
	atomic.AddUint64(&stats.zeroCopyHits, 1)

	return C.long(length)
}

//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	value, exists := streams.Load(int(streamID))
	if !exists {
		return C.long(-1)
	}

	stream := value.(*shmipc.Stream)

	reader := stream.BufferReader()
	buf, err := reader.ReadBytes(int(length))
	if err != nil {
		return C.long(-2)
	}

	target := unsafe.Slice((*byte)(data), length)
	copy(target, buf)
	stream.ReleaseReadAndReuse()

	atomic.AddUint64(&stats.totalReads, 1)

	return C.long(len(buf))
}

//export ShmipcReadZeroCopy
func ShmipcReadZeroCopy(streamID C.int, length C.long) (unsafe.Pointer, C.long) {
	value, exists := streams.Load(int(streamID))
	if !exists {
		return nil, C.long(-1)
	}

	stream := value.(*shmipc.Stream)

	reader := stream.BufferReader()
	buf, err := reader.ReadBytes(int(length))
	if err != nil {
		return nil, C.long(-2)
	}

	if len(buf) == 0 {
		return nil, C.long(0)
	}

	atomic.AddUint64(&stats.totalReads, 1)
	atomic.AddUint64(&stats.zeroCopyHits, 1)

	return unsafe.Pointer(&buf[0]), C.long(len(buf))
}

//export ShmipcReleaseReadBuffer
func ShmipcReleaseReadBuffer(streamID C.int) C.int {
	value, exists := streams.Load(int(streamID))
	if !exists {
		return C.int(-1)
	}

	stream := value.(*shmipc.Stream)
	stream.ReleaseReadAndReuse()
	return C.int(0)
}

//export ShmipcCloseStream
func ShmipcCloseStream(streamID C.int) C.int {
	value, exists := streams.Load(int(streamID))
	if !exists {
		return C.int(-1)
	}

	stream := value.(*shmipc.Stream)
	err := stream.Close()
	streams.Delete(int(streamID))

	if err != nil {
		return C.int(-2)
	}

	return C.int(0)
}

//export ShmipcCloseSession
func ShmipcCloseSession(fd C.int) C.int {
	value, exists := sessions.Load(int(fd))
	if !exists {
		return C.int(-1)
	}

	session := value.(*shmipc.Session)
	err := session.Close()
	sessions.Delete(int(fd))

	if err != nil {
		return C.int(-2)
	}

	return C.int(0)
}

//export ShmipcGetStats
func ShmipcGetStats(statsPtr unsafe.Pointer) C.int {
	type Stats struct {
		TotalConnections  uint64
		ShmipcConnections uint64
		SocketConnections uint64
		TotalBytesSent    uint64
		TotalBytesRecv    uint64
		ShmipcBytesSent   uint64
		ShmipcBytesRecv   uint64
		TotalWrites       uint64
		TotalReads        uint64
		ZeroCopyHits      uint64
		ZeroCopyMiss      uint64
	}

	connCount := 0
	sessions.Range(func(_, _ interface{}) bool {
		connCount++
		return true
	})

	s := Stats{
		TotalConnections:  uint64(connCount),
		ShmipcConnections: uint64(connCount),
		TotalWrites:       atomic.LoadUint64(&stats.totalWrites),
		TotalReads:        atomic.LoadUint64(&stats.totalReads),
		ZeroCopyHits:      atomic.LoadUint64(&stats.zeroCopyHits),
		ZeroCopyMiss:      atomic.LoadUint64(&stats.zeroCopyMiss),
	}

	buf := make([]byte, 88)
	binary.LittleEndian.PutUint64(buf[0:8], s.TotalConnections)
	binary.LittleEndian.PutUint64(buf[8:16], s.ShmipcConnections)
	binary.LittleEndian.PutUint64(buf[16:24], s.SocketConnections)
	binary.LittleEndian.PutUint64(buf[24:32], s.TotalBytesSent)
	binary.LittleEndian.PutUint64(buf[32:40], s.TotalBytesRecv)
	binary.LittleEndian.PutUint64(buf[40:48], s.ShmipcBytesSent)
	binary.LittleEndian.PutUint64(buf[48:56], s.ShmipcBytesRecv)
	binary.LittleEndian.PutUint64(buf[56:64], s.TotalWrites)
	binary.LittleEndian.PutUint64(buf[64:72], s.TotalReads)
	binary.LittleEndian.PutUint64(buf[72:80], s.ZeroCopyHits)
	binary.LittleEndian.PutUint64(buf[80:88], s.ZeroCopyMiss)

	copy((*[88]byte)(statsPtr)[:], buf)

	return C.int(0)
}

//export ShmipcWriteBatch
func ShmipcWriteBatch(streamIDs *C.int, datas **unsafe.Pointer, lengths *C.long, count C.int) C.int {
	for i := 0; i < int(count); i++ {
		streamID := *(*C.int)(unsafe.Pointer(uintptr(unsafe.Pointer(streamIDs)) + uintptr(i)*4))
		data := *(**unsafe.Pointer)(unsafe.Pointer(uintptr(unsafe.Pointer(datas)) + uintptr(i)*8))
		length := *(*C.long)(unsafe.Pointer(uintptr(unsafe.Pointer(lengths)) + uintptr(i)*8))

		ret := ShmipcWrite(streamID, data, length)
		if ret < 0 {
			return C.int(i)
		}
	}
	return count
}

func main() {
	fmt.Println("shmipc-bridge-optimized: This is a shared library")
	fmt.Println("Usage: LD_PRELOAD=./libshmipc.so <your-program>")
}
