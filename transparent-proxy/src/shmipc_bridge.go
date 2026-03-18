/*
 * Copyright 2023 CloudWeGo Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
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
	sessionManager *shmipc.SessionManager
	sessions       = make(map[int]*shmipc.Session)
	streams        = make(map[int]*shmipc.Stream)
	mu             sync.RWMutex
	config         *Config
)

type Config struct {
	Mode           int
	LogLevel       int
	ShmBufferSize  uint32
	QueueCapacity  uint32
	ShmPathPrefix  string
	EnableFallback bool
	EnableStats    bool
}

func init() {
	loadConfig()
}

func loadConfig() {
	config = &Config{
		Mode:          0, // SHMIPC_MODE_AUTO
		LogLevel:      1, // SHMIPC_LOG_ERROR
		ShmBufferSize: 32 * 1024 * 1024,
		QueueCapacity: 8192,
		ShmPathPrefix: "/dev/shm/shmipc_transparent",
		EnableFallback: true,
		EnableStats:   true,
	}

	if mode := os.Getenv("SHMIPC_MODE"); mode != "" {
		switch mode {
		case "auto":
			config.Mode = 0
		case "force_shmipc":
			config.Mode = 1
		case "force_socket":
			config.Mode = 2
		}
	}

	if level := os.Getenv("SHMIPC_LOG_LEVEL"); level != "" {
		if l, err := strconv.Atoi(level); err == nil {
			config.LogLevel = l
		}
	}

	if size := os.Getenv("SHMIPC_BUFFER_SIZE"); size != "" {
		if s, err := strconv.ParseUint(size, 10, 32); err == nil {
			config.ShmBufferSize = uint32(s)
		}
	}

	if prefix := os.Getenv("SHMIPC_PATH_PREFIX"); prefix != "" {
		config.ShmPathPrefix = prefix
	}
}

func getShmipcConfig() *shmipc.Config {
	c := shmipc.DefaultConfig()
	c.QueueCap = config.QueueCapacity
	c.ShareMemoryBufferCap = config.ShmBufferSize
	c.ShareMemoryPathPrefix = config.ShmPathPrefix
	c.MemMapType = shmipc.MemMapTypeMemFd
	return c
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

	conn, err := net.FileConn(os.NewFile(uintptr(fd), "unix"))
	if err != nil {
		return C.int(-2)
	}

	shmConfig := getShmipcConfig()
	shmConfig.ShareMemoryPathPrefix = goPath + "_client"

	session, err := shmipc.NewClientSession(shmConfig, conn)
	if err != nil {
		conn.Close()
		return C.int(-3)
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
	conn, err := net.FileConn(file)
	if err != nil {
		return C.int(-2)
	}

	shmConfig := getShmipcConfig()
	shmConfig.ShareMemoryPathPrefix = goPath + "_server"

	session, err := shmipc.Server(conn, shmConfig)
	if err != nil {
		conn.Close()
		return C.int(-3)
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
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.int) C.ssize_t {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists {
		return C.ssize_t(-1)
	}

	buf := C.GoBytes(data, length)

	writer := stream.BufferWriter()
	_, err := writer.WriteBytes(buf)
	if err != nil {
		return C.ssize_t(-2)
	}

	err = stream.Flush(false)
	if err != nil {
		return C.ssize_t(-3)
	}

	return C.ssize_t(length)
}

//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.int) C.ssize_t {
	mu.RLock()
	stream, exists := streams[int(streamID)]
	mu.RUnlock()

	if !exists {
		return C.ssize_t(-1)
	}

	reader := stream.BufferReader()
	buf, err := reader.ReadBytes(int(length))
	if err != nil {
		return C.ssize_t(-2)
	}

	copy((*[1 << 30]byte)(data)[:len(buf)], buf)
	stream.ReleaseReadAndReuse()

	return C.ssize_t(len(buf))
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
	type ShmipcStats struct {
		TotalConnections     uint64
		ShmipcConnections    uint64
		FallbackConnections  uint64
		TotalBytesSent       uint64
		TotalBytesRecv       uint64
		ShmipcBytesSent      uint64
		ShmipcBytesRecv      uint64
		FallbackBytesSent    uint64
		FallbackBytesRecv    uint64
	}

	mu.RLock()
	defer mu.RUnlock()

	s := ShmipcStats{
		TotalConnections:    uint64(len(sessions)),
		ShmipcConnections:   uint64(len(sessions)),
		ShmipcBytesSent:     0,
		ShmipcBytesRecv:     0,
	}

	buf := make([]byte, 72)
	binary.LittleEndian.PutUint64(buf[0:8], s.TotalConnections)
	binary.LittleEndian.PutUint64(buf[8:16], s.ShmipcConnections)
	binary.LittleEndian.PutUint64(buf[16:24], s.FallbackConnections)
	binary.LittleEndian.PutUint64(buf[24:32], s.TotalBytesSent)
	binary.LittleEndian.PutUint64(buf[32:40], s.TotalBytesRecv)
	binary.LittleEndian.PutUint64(buf[40:48], s.ShmipcBytesSent)
	binary.LittleEndian.PutUint64(buf[48:56], s.ShmipcBytesRecv)
	binary.LittleEndian.PutUint64(buf[56:64], s.FallbackBytesSent)
	binary.LittleEndian.PutUint64(buf[64:72], s.FallbackBytesRecv)

	copy((*[72]byte)(stats)[:], buf)

	return C.int(0)
}

func main() {
	fmt.Println("shmipc-transparent: This is a shared library, not an executable")
	fmt.Println("Usage: LD_PRELOAD=/path/to/libshmipc_transparent.so <your-program>")
}
