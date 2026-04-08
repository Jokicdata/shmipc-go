/*
 * shmipc-bridge - Go CGO 桥接层 (优化版)
 *
 * 关键优化：
 * 1. 零拷贝写：使用 shmipc.Reserve 直接获取 shm buffer
 * 2. 批量操作：支持 writev/readv 减少 flush 次数
 *
 * 编译方式：
 *   go build -buildmode=c-shared -o libshmipc_go_opt.so shmipc_bridge_opt.go
 */

package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"
import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"unsafe"

	"github.com/cloudwego/shmipc-go"
)

var (
	mu       sync.RWMutex
	sessions = make(map[int]*shmipc.Session)
	streams  = make(map[int]*shmipc.Stream)
	config   *shmipc.Config
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
	session, exists := sessions[int(fd)]
	mu.Unlock()

	if !exists {
		return C.int(-1)
	}

	stream, err := session.OpenStream()
	if err != nil {
		return C.int(-2)
	}

	streamID := int(stream.StreamID())

	mu.Lock()
	streams[streamID] = stream
	mu.Unlock()

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

	streamID := int(stream.StreamID())

	mu.Lock()
	streams[streamID] = stream
	mu.Unlock()

	return C.int(streamID)
}

//export ShmipcWrite
// 优化版本：使用 Reserve API 直接获取 shm buffer，减少一次拷贝
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists || stream == nil {
		return C.long(-1)
	}

	n := int(length)
	if n == 0 {
		return C.long(0)
	}

	writer := stream.BufferWriter()

	reserved, err := writer.Reserve(n)
	if err != nil {
		return C.long(-2)
	}

	copy(reserved, (*[1 << 30]byte)(data)[:n])

	err = stream.Flush(false)
	if err != nil {
		return C.long(-3)
	}

	return C.long(n)
}

//export ShmipcWriteVectored
// 优化版本：批量写，减少 flush 次数
func ShmipcWriteVectored(streamID C.int, iovec *C.struct_iovec, iovcnt C.int) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists || stream == nil {
		return C.long(-1)
	}

	if iovcnt <= 0 || iovec == nil {
		return C.long(0)
	}

	writer := stream.BufferWriter()
	totalWritten := 0

	for i := 0; i < int(iovcnt); i++ {
		iov := (*C.struct_iovec)(unsafe.Pointer(uintptr(unsafe.Pointer(iovec)) + uintptr(i)*unsafe.Sizeof(C.struct_iovec{})))
		if iov == nil {
			continue
		}

		if iov.iov_len == 0 || iov.iov_base == nil {
			continue
		}

		n := int(iov.iov_len)
		data := (*[1 << 30]byte)(unsafe.Pointer(iov.iov_base))[:n]

		written, err := writer.WriteBytes(data)
		if err != nil {
			break
		}
		totalWritten += written

		if written < n {
			break
		}
	}

	if totalWritten > 0 {
		if err := stream.Flush(false); err != nil {
			return C.long(-2)
		}
	}

	return C.long(totalWritten)
}

//export ShmipcRead
// 优化版本：直接读取数据
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists || stream == nil {
		return C.long(-1)
	}

	n := int(length)
	if n == 0 {
		return C.long(0)
	}

	reader := stream.BufferReader()
	buf, err := reader.ReadBytes(n)
	if err != nil {
		return C.long(-2)
	}

	copied := copy((*[1 << 30]byte)(data)[:len(buf)], buf)

	stream.ReleaseReadAndReuse()

	return C.long(copied)
}

//export ShmipcReadVectored
// 优化版本：批量读
func ShmipcReadVectored(streamID C.int, iovec *C.struct_iovec, iovcnt C.int) C.long {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists || stream == nil {
		return C.long(-1)
	}

	if iovcnt <= 0 || iovec == nil {
		return C.long(0)
	}

	reader := stream.BufferReader()
	totalRead := 0

	for i := 0; i < int(iovcnt); i++ {
		iov := (*C.struct_iovec)(unsafe.Pointer(uintptr(unsafe.Pointer(iovec)) + uintptr(i)*unsafe.Sizeof(C.struct_iovec{})))
		if iov == nil {
			continue
		}

		if iov.iov_len == 0 || iov.iov_base == nil {
			continue
		}

		n := int(iov.iov_len)
		dest := (*[1 << 30]byte)(unsafe.Pointer(iov.iov_base))[:n]

		buf, err := reader.ReadBytes(n)
		if err != nil {
			break
		}

		copied := copy(dest, buf)
		totalRead += copied

		if len(buf) < n {
			break
		}
	}

	stream.ReleaseReadAndReuse()

	return C.long(totalRead)
}

//export ShmipcCloseStream
func ShmipcCloseStream(streamID C.int) C.int {
	mu.Lock()
	stream, exists := streams[int(streamID)]
	if exists {
		delete(streams, int(streamID))
	}
	mu.Unlock()

	if !exists {
		return C.int(-1)
	}

	err := stream.Close()
	if err != nil {
		return C.int(-2)
	}

	return C.int(0)
}

//export ShmipcCloseSession
func ShmipcCloseSession(fd C.int) C.int {
	mu.Lock()
	session, exists := sessions[int(fd)]
	if exists {
		delete(sessions, int(fd))
	}
	mu.Unlock()

	if !exists {
		return C.int(-1)
	}

	err := session.Close()
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
	}

	mu.RLock()
	defer mu.RUnlock()

	s := Stats{
		TotalConnections:  uint64(len(sessions)),
		ShmipcConnections: uint64(len(sessions)),
	}

	buf := make([]byte, 56)
	binary.LittleEndian.PutUint64(buf[0:8], s.TotalConnections)
	binary.LittleEndian.PutUint64(buf[8:16], s.ShmipcConnections)
	binary.LittleEndian.PutUint64(buf[16:24], s.SocketConnections)
	binary.LittleEndian.PutUint64(buf[24:32], s.TotalBytesSent)
	binary.LittleEndian.PutUint64(buf[32:40], s.TotalBytesRecv)
	binary.LittleEndian.PutUint64(buf[40:48], s.ShmipcBytesSent)
	binary.LittleEndian.PutUint64(buf[48:56], s.ShmipcBytesRecv)

	copy((*[56]byte)(stats)[:], buf)

	return C.int(0)
}

//export ShmipcFlush
// 显式 flush，用于批量写完后刷新
func ShmipcFlush(streamID C.int) C.int {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists || stream == nil {
		return C.int(-1)
	}

	err := stream.Flush(false)
	if err != nil {
		return C.int(-2)
	}

	return C.int(0)
}

func main() {
	fmt.Println("shmipc-bridge-opt: This is a shared library")
	fmt.Println("Usage: LD_PRELOAD=./libshmipc_opt.so <your-program>")
}
