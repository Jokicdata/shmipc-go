/*
 * shmipc-bridge - Go CGO 桥接层 (带性能追踪版)
 *
 * 使用方式：
 *   1. 编译：make -f Makefile.trace
 *   2. 运行：SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf ...
 *   3. 查看：tail -f /tmp/shmipc_trace.log
 */

package main

/*
#include <stdlib.h>
#include <stdint.h>
#include <sys/uio.h>
#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

static double get_ts() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}
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
	mu            sync.RWMutex
	sessions      = make(map[int]*shmipc.Session)
	streams       = make(map[int]*shmipc.Stream)
	config        *shmipc.Config
	traceEnabled  = os.Getenv("SHMIPC_TRACE") == "1"
	traceFD       C.int = -1
)

func init() {
	loadConfig()
	if traceEnabled {
		initTrace()
	}
}

func initTrace() {
	fd, err := os.OpenFile("/tmp/shmipc_trace.log", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to open trace file: %v\n", err)
		return
	}
	traceFD = C.int(fd.Fd())
	writeTrace("=== shmipc Trace Started === PID=%d", os.Getpid())
}

func writeTrace(format string, args ...interface{}) {
	if traceFD < 0 {
		return
	}
	msg := fmt.Sprintf("[%.6f] %s\n", C.get_ts(), fmt.Sprintf(format, args...))
	C.write(traceFD, unsafe.Pointer(C.CString(msg)), C.size_t(len(msg)))
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
	writeTrace("INIT")
	return C.int(0)
}

//export ShmipcCleanup
func ShmipcCleanup() {
	writeTrace("CLEANUP")

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
	writeTrace("CLIENT_CONN fd=%d path=%s", fd, goPath)

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
	writeTrace("SERVER_CONN fd=%d path=%s", fd, goPath)

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

	writeTrace("OPEN_STREAM fd=%d sid=%d", fd, streamID)
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

	writeTrace("ACCEPT_STREAM fd=%d sid=%d", fd, streamID)
	return C.int(streamID)
}

//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	t0 := C.get_ts()

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

	t1 := C.get_ts()
	reserved, err := writer.Reserve(n)
	t2 := C.get_ts()

	if err != nil {
		return C.long(-2)
	}

	t3 := C.get_ts()
	copy(reserved, (*[1 << 30]byte)(data)[:n])
	t4 := C.get_ts()

	t5 := C.get_ts()
	err = stream.Flush(false)
	t6 := C.get_ts()

	if err != nil {
		return C.long(-3)
	}

	t7 := C.get_ts()
	writeTrace("WRITE sid=%d size=%d t_reduce=%.3f t_copy=%.3f t_flush=%.3f t_total=%.3f",
		streamID, n,
		(t2-t1)*1000,    // Reserve (get shm buffer)
		(t4-t3)*1000,    // Memcpy
		(t6-t5)*1000,    // Flush
		(t7-t0)*1000)    // Total

	return C.long(n)
}

//export ShmipcWriteVectored
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
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
	t0 := C.get_ts()

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

	t1 := C.get_ts()
	buf, err := reader.ReadBytes(n)
	t2 := C.get_ts()

	if err != nil {
		return C.long(-2)
	}

	t3 := C.get_ts()
	copied := copy((*[1 << 30]byte)(data)[:len(buf)], buf)
	t4 := C.get_ts()

	t5 := C.get_ts()
	stream.ReleaseReadAndReuse()
	t6 := C.get_ts()

	t7 := C.get_ts()
	writeTrace("READ sid=%d size=%d copied=%d t_read=%.3f t_copy=%.3f t_release=%.3f t_total=%.3f",
		streamID, n, copied,
		(t2-t1)*1000,    // Read from shm
		(t4-t3)*1000,    // Copy to C
		(t6-t5)*1000,    // Release
		(t7-t0)*1000)    // Total

	return C.long(copied)
}

//export ShmipcReadVectored
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
	writeTrace("CLOSE_STREAM sid=%d", streamID)

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
	writeTrace("CLOSE_SESSION fd=%d", fd)

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

func main() {
	fmt.Println("shmipc-bridge: This is a shared library")
	fmt.Println("Usage: LD_PRELOAD=./libshmipc_trace.so <your-program>")
	fmt.Println("Trace: SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so <program>")
	fmt.Println("View:  tail -f /tmp/shmipc_trace.log")
}
