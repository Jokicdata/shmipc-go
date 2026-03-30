/*
 * shmipc-bridge - Go CGO 桥接层
 * 
 * 功能：将 shmipc-go 核心库的功能导出为 C 可调用的接口
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

	session, err := shmipc.NewClientSession(shmConfig, conn)
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

	buf := C.GoBytes(data, C.int(length))

	writer := stream.BufferWriter()
	n, err := writer.WriteBytes(buf)
	if err != nil {
		return C.long(-2)
	}

	err = stream.Flush(false)
	if err != nil {
		return C.long(-3)
	}

	return C.long(n)
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
	buf, err := reader.ReadBytes(int(length))
	if err != nil {
		return C.long(-2)
	}

	copy((*[1 << 30]byte)(data)[:len(buf)], buf)
	stream.ReleaseReadAndReuse()

	return C.long(len(buf))
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

func main() {
	fmt.Println("shmipc-bridge: This is a shared library")
	fmt.Println("Usage: LD_PRELOAD=./libshmipc.so <your-program>")
}
