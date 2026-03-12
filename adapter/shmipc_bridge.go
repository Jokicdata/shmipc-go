/*
 * Shmipc Go Bridge - C to Go Interface
 * 
 * This file provides CGO bridge functions that allow C code to call
 * Go shmipc functions for transparent socket interception.
 * 
 * Build: go build -buildmode=c-shared -o libshmipc_go.so
 */

package main

/*
#cgo CFLAGS: -I.
#cgo LDFLAGS: -lpthread
#include <stdlib.h>
#include <string.h>

// Go function declarations
extern int shmipc_c_init(const char* config);
extern int shmipc_c_server(const char* path, void** handle);
extern int shmipc_c_client(const char* path, void** handle);
extern int shmipc_c_accept(void* handle, void** stream_handle);
extern int shmipc_c_connect(void* handle, void** stream_handle);
extern long shmipc_c_send(void* stream_handle, const void* data, long len);
extern long shmipc_c_recv(void* stream_handle, void* data, long len);
extern int shmipc_c_close(void* handle);
*/
import "C"

import (
	"fmt"
	"net"
	"os"
	"sync"
	"unsafe"

	shmipc "github.com/cloudwego/shmipc-go"
)

var (
	initialized   bool
	initMutex     sync.Mutex
	connections   = make(map[unsafe.Pointer]*shmipcConn)
	connMutex     sync.RWMutex
	streams       = make(map[unsafe.Pointer]*shmipc.Stream)
	streamMutex   sync.RWMutex
	defaultConfig *shmipc.Config
)

type shmipcConn struct {
	session   *shmipc.Session
	isServer  bool
	path      string
	listener  *shmipc.Listener
}

//export shmipc_go_init
func shmipc_go_init(config *C.char) C.int {
	initMutex.Lock()
	defer initMutex.Unlock()

	if initialized {
		return 0
	}

	configStr := C.GoString(config)
	if configStr == "" {
		defaultConfig = shmipc.DefaultConfig()
		defaultConfig.QueueCap = 65535
		defaultConfig.ShareMemoryBufferCap = 256 << 20
		defaultConfig.MemMapType = shmipc.MemMapTypeMemFd
	} else {
		// Parse config from JSON string (simplified)
		defaultConfig = shmipc.DefaultConfig()
	}

	initialized = true
	fmt.Fprintf(os.Stderr, "[shmipc-go] Initialized with config: %s\n", configStr)
	return 0
}

//export shmipc_go_server
func shmipc_go_server(path *C.char, handle **C.void) C.int {
	pathStr := C.GoString(path)

	initMutex.Lock()
	if !initialized {
		initMutex.Unlock()
		return -1
	}
	initMutex.Unlock()

	// Create listener
	listenerConfig := &shmipc.ListenerConfig{
		Config:     defaultConfig,
		Network:    "unix",
		ListenPath: pathStr,
	}

	callback := &shmipcCallback{}
	listener, err := shmipc.NewListener(callback, listenerConfig)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to create listener: %v\n", err)
		return -1
	}

	// Start listener in background
	go listener.Run()

	// Create connection wrapper
	conn := &shmipcConn{
		isServer: true,
		path:     pathStr,
		listener:  listener,
	}

	connPtr := unsafe.Pointer(conn)
	connMutex.Lock()
	connections[connPtr] = conn
	connMutex.Unlock()

	*handle = connPtr
	fmt.Fprintf(os.Stderr, "[shmipc-go] Server created for path: %s\n", pathStr)
	return 0
}

//export shmipc_go_client
func shmipc_go_client(path *C.char, handle **C.void) C.int {
	pathStr := C.GoString(path)

	initMutex.Lock()
	if !initialized {
		initMutex.Unlock()
		return -1
	}
	initMutex.Unlock()

	// Connect to server
	addr := &net.UnixAddr{Name: pathStr, Net: "unix"}
	conn, err := net.DialUnix("unix", nil, addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to dial: %v\n", err)
		return -1
	}

	session, err := shmipc.NewSession(defaultConfig, conn, true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to create session: %v\n", err)
		conn.Close()
		return -1
	}

	// Open stream
	stream, err := session.OpenStream()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to open stream: %v\n", err)
		session.Close()
		return -1
	}

	// Create connection wrapper
	conn := &shmipcConn{
		isServer: false,
		path:     pathStr,
		session:   session,
	}

	connPtr := unsafe.Pointer(conn)
	connMutex.Lock()
	connections[connPtr] = conn
	streamMutex.Lock()
	streams[connPtr] = stream
	streamMutex.Unlock()

	*handle = connPtr
	fmt.Fprintf(os.Stderr, "[shmipc-go] Client created for path: %s\n", pathStr)
	return 0
}

//export shmipc_go_accept
func shmipc_go_accept(handle unsafe.Pointer, streamHandle **C.void) C.int {
	connMutex.RLock()
	conn, ok := connections[handle]
	connMutex.RUnlock()

	if !ok || !conn.isServer {
		return -1
	}

	// Wait for stream from listener
	stream, err := conn.listener.AcceptStream()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to accept stream: %v\n", err)
		return -1
	}

	// Store stream
	streamPtr := unsafe.Pointer(stream)
	streamMutex.Lock()
	streams[streamPtr] = stream
	streamMutex.Unlock()

	*streamHandle = streamPtr
	fmt.Fprintf(os.Stderr, "[shmipc-go] Stream accepted\n")
	return 0
}

//export shmipc_go_connect
func shmipc_go_connect(handle unsafe.Pointer, streamHandle **C.void) C.int {
	// For client, the handle is already the stream handle
	*streamHandle = handle
	return 0
}

//export shmipc_go_send
func shmipc_go_send(streamHandle unsafe.Pointer, data unsafe.Pointer, length C.long) C.long {
	streamMutex.RLock()
	stream, ok := streams[streamHandle]
	streamMutex.RUnlock()

	if !ok {
		return -1
	}

	// Convert C pointer to Go slice
	dataSlice := (*[1 << 30]byte)(data)[:length:length]

	// Write data using zero-copy
	writer := stream.BufferWriter()
	_, err := writer.WriteBytes(dataSlice)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to write: %v\n", err)
		return -1
	}

	// Flush data
	err = stream.Flush(false)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to flush: %v\n", err)
		return -1
	}

	return C.long(length)
}

//export shmipc_go_recv
func shmipc_go_recv(streamHandle unsafe.Pointer, data unsafe.Pointer, length C.long) C.long {
	streamMutex.RLock()
	stream, ok := streams[streamHandle]
	streamMutex.RUnlock()

	if !ok {
		return -1
	}

	// Read data using zero-copy
	reader := stream.BufferReader()
	readData, err := reader.ReadBytes(int(length))
	if err != nil {
		if err == shmipc.ErrEndOfStream || err == shmipc.ErrStreamClosed {
			return 0
		}
		fmt.Fprintf(os.Stderr, "[shmipc-go] Failed to read: %v\n", err)
		return -1
	}

	// Copy data to C buffer
	dataSlice := (*[1 << 30]byte)(data)[:length:length]
	copy(dataSlice, readData)

	// Release read buffer
	reader.ReleasePreviousRead()

	return C.long(len(readData))
}

//export shmipc_go_close
func shmipc_go_close(handle unsafe.Pointer) C.int {
	// Check if it's a stream
	streamMutex.RLock()
	stream, ok := streams[handle]
	streamMutex.RUnlock()

	if ok {
		stream.Close()
		streamMutex.Lock()
		delete(streams, handle)
		streamMutex.Unlock()
		return 0
	}

	// Check if it's a connection
	connMutex.RLock()
	conn, ok := connections[handle]
	connMutex.RUnlock()

	if ok {
		if conn.session != nil {
			conn.session.Close()
		}
		if conn.listener != nil {
			conn.listener.Close()
		}
		connMutex.Lock()
		delete(connections, handle)
		connMutex.Unlock()
		return 0
	}

	return -1
}

// shmipcCallback implements shmipc.ListenCallback
type shmipcCallback struct{}

func (c *shmipcCallback) OnNewStream(s *shmipc.Stream) {
	fmt.Fprintf(os.Stderr, "[shmipc-go] New stream accepted\n")
}

func (c *shmipcCallback) OnShutdown(reason string) {
	fmt.Fprintf(os.Stderr, "[shmipc-go] Listener shutdown: %s\n", reason)
}

func main() {
	// This is a shared library, main() won't be called
}