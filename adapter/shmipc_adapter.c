/*
 * Shmipc Adapter - Socket Function Interception
 * 
 * This library intercepts standard socket functions and redirects them
 * to use shmipc for high-performance IPC.
 * 
 * Compile: gcc -shared -fPIC -o libshmipc_adapter.so shmipc_adapter.c -I../../
 * Usage: LD_PRELOAD=./libshmipc_adapter.so qperf ...
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>

#define SHMIPC_ENABLED_ENV "SHMIPC_ENABLED"
#define SHMIPC_CONFIG_ENV "SHMIPC_CONFIG"
#define MAX_PATH_LEN 256

/* Original function pointers */
static int (*real_socket)(int, int, int) = NULL;
static int (*real_connect)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*real_bind)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*real_listen)(int, int) = NULL;
static int (*real_accept)(int, struct sockaddr *, socklen_t *) = NULL;
static int (*real_accept4)(int, struct sockaddr *, socklen_t *, int) = NULL;
static int (*real_close)(int) = NULL;
static ssize_t (*real_send)(int, const void *, size_t, int) = NULL;
static ssize_t (*real_recv)(int, void *, size_t, int) = NULL;
static ssize_t (*real_write)(int, const void *, size_t) = NULL;
static ssize_t (*real_read)(int, void *, size_t) = NULL;

/* Shmipc connection tracking */
typedef struct {
    int fd;
    int is_shmipc;
    int is_server;
    char path[MAX_PATH_LEN];
    void* shmipc_handle;
} shmipc_conn_t;

#define MAX_CONNS 1024
static shmipc_conn_t connections[MAX_CONNS];
static pthread_mutex_t conn_lock = PTHREAD_MUTEX_INITIALIZER;

/* Shmipc Go bridge functions (implemented in Go) */
extern int shmipc_go_init(const char* config);
extern int shmipc_go_server(const char* path, void** handle);
extern int shmipc_go_client(const char* path, void** handle);
extern int shmipc_go_accept(void* handle, void** stream_handle);
extern int shmipc_go_connect(void* handle, void** stream_handle);
extern ssize_t shmipc_go_send(void* stream_handle, const void* data, size_t len);
extern ssize_t shmipc_go_recv(void* stream_handle, void* data, size_t len);
extern int shmipc_go_close(void* handle);

/* Initialize real function pointers */
static void init_real_functions(void) {
    if (!real_socket) {
        real_socket = dlsym(RTLD_NEXT, "socket");
        real_connect = dlsym(RTLD_NEXT, "connect");
        real_bind = dlsym(RTLD_NEXT, "bind");
        real_listen = dlsym(RTLD_NEXT, "listen");
        real_accept = dlsym(RTLD_NEXT, "accept");
        real_accept4 = dlsym(RTLD_NEXT, "accept4");
        real_close = dlsym(RTLD_NEXT, "close");
        real_send = dlsym(RTLD_NEXT, "send");
        real_recv = dlsym(RTLD_NEXT, "recv");
        real_write = dlsym(RTLD_NEXT, "write");
        real_read = dlsym(RTLD_NEXT, "read");
    }
}

/* Check if shmipc is enabled */
static int is_shmipc_enabled(void) {
    const char* env = getenv(SHMIPC_ENABLED_ENV);
    return (env && (strcmp(env, "1") == 0 || strcmp(env, "true") == 0 || 
                     strcmp(env, "yes") == 0));
}

/* Initialize shmipc */
static int init_shmipc(void) {
    static int initialized = 0;
    static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
    
    if (initialized) {
        return 0;
    }
    
    pthread_mutex_lock(&init_lock);
    if (!initialized) {
        const char* config = getenv(SHMIPC_CONFIG_ENV);
);
        if (!config) {
            config = "";
        }
        
        if (shmipc_go_init(config) == 0) {
            initialized = 1;
            fprintf(stderr, "[shmipc] Initialized successfully\n");
        } else {
            fprintf(stderr, "[shmipc] Initialization failed\n");
        }
    }
    pthread_mutex_unlock(&init_lock);
    
    return initialized ? 0 : -1;
}

/* Find connection by fd */
static shmipc_conn_t* find_conn(int fd) {
    for (int i = 0; i < MAX_CONNS; i++) {
        if (connections[i].fd == fd && connections[i].is_shmipc) {
            return &connections[i];
        }
    }
    return NULL;
}

/* Add connection */
static int add_conn(int fd, int is_server, const char* path, void* handle) {
    pthread_mutex_lock(&conn_lock);
    for (int i = 0; i < MAX_CONNS; i++) {
        if (connections[i].fd == -1) {
            connections[i].fd = fd;
            connections[i].is_shmipc = 1;
            connections[i].is_server = is_server;
            connections[i].shmipc_handle = handle;
            if (path) {
                strncpy(connections[i].path, path, MAX_PATH_LEN - 1);
                connections[i].path[MAX_PATH_LEN - 1] = '\0';
            }
            pthread_mutex_unlock(&conn_lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&conn_lock);
    return -1;
}

/* Remove connection */
static void remove_conn(int fd) {
    pthread_mutex_lock(&conn_lock);
    for (int i = 0; i < MAX_CONNS; i++) {
        if (connections[i].fd == fd) {
            connections[i].fd = -1;
            connections[i].is_shmipc = 0;
            connections[i].is_server = 0;
            connections[i].shmipc_handle = NULL;
            connections[i].path[0] = '\0';
            break;
        }
    }
    pthread_mutex_unlock(&conn_lock);
}

/* Check if address is Unix domain socket */
static int is_unix_socket(const struct sockaddr* addr) {
    if (!addr) return 0;
    return (addr->sa_family == AF_UNIX);
}

/* Check if address is localhost TCP */
static int is_localhost_tcp(const struct sockaddr* addr) {
    if (!addr) return 0;
    
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in* addr_in = (const struct sockaddr_in*)addr;
        return (ntohl(addr_in->sin_addr.s_addr) == INADDR_LOOPBACK);
    } else if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6* addr_in6 = (const struct sockaddr_in6*)addr;
        const uint8_t* addr_bytes = addr_in6->sin6_addr.s6_addr;
        return (addr_bytes[0] == 0 && addr_bytes[1] == 0 && 
                addr_bytes[2] == 0 && addr_bytes[3] == 0 &&
                addr_bytes[4] == 0 && addr_bytes[5] == 0 && 
                addr_bytes[6] == 0 && addr_bytes[7] == 0 &&
                addr_bytes[8] == 0 && addr_bytes[9] == 0 && 
                addr_bytes[10] == 0 && addr_bytes[11] == 0 &&
                addr_bytes[12] == 0 && addr_bytes[13] == 0 && 
                addr_bytes[14] == 0 && addr_bytes[15] == 1);
    }
    return 0;
}

/* Constructor */
__attribute__((constructor))
static void shmipc_adapter_init(void) {
    init_real_functions();
    
    /* Initialize connection tracking */
    pthread_mutex_lock(&conn_lock);
    for (int i = 0; i < MAX_CONNS; i++) {
        connections[i].fd = -1;
        connections[i].is_shmipc = 0;
    }
    pthread_mutex_unlock(&conn_lock);
    
    if (is_shmipc_enabled()) {
        fprintf(stderr, "[shmipc] Adapter loaded, shmipc enabled\n");
        init_shmipc();
    } else {
        fprintf(stderr, "[shmipc] Adapter loaded, shmipc disabled (set %s=1 to enable)\n", 
                SHMIPC_ENABLED_ENV);
    }
}

/* Destructor */
__attribute__((destructor))
static void shmipc_adapter_fini(void) {
    fprintf(stderr, "[shmipc] Adapter unloaded\n");
}

/* ========== Intercepted Functions ========== */

int socket(int domain, int type, int protocol) {
    init_real_functions();
    
    /* Always use real socket for fd allocation */
    int fd = real_socket(domain, type, protocol);
    if (fd < 0) {
        return fd;
    }
    
    return fd;
}

int connect(int sockfd, const struct sockaddr* addr, socklen_t addrlen) {
    init_real_functions();
    
    if (!is_shmipc_enabled()) {
        return real_connect(sockfd, addr, addrlen);
    }
    
    /* Check if we should intercept this connection */
    int intercept = 0;
    char path[MAX_PATH_LEN] = {0};
    
    if (is_unix_socket(addr)) {
        const struct sockaddr_un* addr_un = (const struct sockaddr_un*)addr;
        strncpy(path, addr_un->sun_path, MAX_PATH_LEN - 1);
        path[MAX_PATH_LEN - 1] = '\0';
        intercept = 1;
    } else if (is_localhost_tcp(addr)) {
        /* Convert localhost TCP to Unix socket path */
        if (addr->sa_family == AF_INET) {
            const struct sockaddr_in* addr_in = (const struct sockaddr_in*)addr;
            snprintf(path, MAX_PATH_LEN, "/tmp/shmipc_tcp_%d", 
                    ntohs(addr_in->sin_port));
        } else if (addr->sa_family == AF_INET6) {
            const struct sockaddr_in6* addr_in6 = (const struct sockaddr_in6*)addr;
            snprintf(path, MAX_PATH_LEN, "/tmp/shmipc_tcp6_%d", 
                    ntohs(addr_in6->sin6_port));
        }
        intercept = 1;
    }
    
    if (intercept) {
        fprintf(stderr, "[shmipc] Intercepting connect to %s\n", path);
        
        void* handle = NULL;
        if (shmipc_go_client(path, &handle) == 0) {
            add_conn(sockfd, 0, path, handle);
            return 0;  /* Success */
        } else {
            fprintf(stderr, "[shmipc] Failed to create shmipc client, falling back to socket\n");
            return real_connect(sockfd, addr, addrlen);
        }
    }
    
    return real_connect(sockfd, addr, addrlen);
}

int bind(int sockfd, const struct sockaddr* addr, socklen_t addrlen) {
    init_real_functions();
    
    if (!is_shmipc_enabled()) {
        return real_bind(sockfd, addr, addrlen);
    }
    
    /* Check if we should intercept this bind */
    int intercept = 0;
    char path[MAX_PATH_LEN] = {0};
    
    if (is_unix_socket(addr)) {
        const struct sockaddr_un* addr_un = (const struct sockaddr_un*)addr;
        strncpy(path, addr_un->sun_path, MAX_PATH_LEN - 1);
        path[MAX_PATH_LEN - 1] = '\0';
        intercept = 1;
    } else if (is_localhost_tcp(addr)) {
        /* Convert localhost TCP to Unix socket path */
        if (addr->sa_family == AF_INET) {
            const struct sockaddr_in* addr_in = (const struct sockaddr_in*)addr;
            snprintf(path, MAX_PATH_LEN, "/tmp/shmipc_tcp_%d", 
                    ntohs(addr_in->sin_port));
        } else if (addr->sa_family == AF_INET6) {
            const struct sockaddr_in6* addr_in6 = (const struct sockaddr_in6*)addr;
            snprintf(path, MAX_PATH_LEN, "/tmp/shmipc_tcp6_%d", 
                    ntohs(addr_in6->sin6_port));
        }
        intercept = 1;
    }
    
    if (intercept) {
        fprintf(stderr, "[shmipc] Intercepting bind to %s\n", path);
        
        void* handle = NULL;
        if (shmipc_go_server(path, &handle) == 0) {
            add_conn(sockfd, 1, path, handle);
            return 0;  /* Success */
        } else {
            fprintf(stderr, "[shmipc] Failed to create shmipc server, falling back to socket\n");
            return real_bind(sockfd, addr, addrlen);
        }
    }
    
    return real_bind(sockfd, addr, addrlen);
}

int listen(int sockfd, int backlog) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(sockfd);
    if (conn && conn->is_shmipc && conn->is_server) {
        /* Shmipc server doesn't need listen */
        return 0;
    }
    
    return real_listen(sockfd, backlog);
}

int accept(int sockfd, struct sockaddr* addr, socklen_t* addrlen) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(sockfd);
    if (conn && conn->is_shmipc && conn->is_server) {
        fprintf(stderr, "[shmipc] Accepting shmipc connection\n");
        
        void* stream_handle = NULL;
        if (shmipc_go_accept(conn->shmipc_handle, &stream_handle) == 0) {
            /* Create a new fd for the accepted connection */
            int new_fd = real_socket(AF_UNIX, SOCK_STREAM, 0);
            if (new_fd >= 0) {
                add_conn(new_fd, 0, conn->path, stream_handle);
                if (addr && addrlen) {
                    struct sockaddr_un addr_un;
                    memset(&addr_un, 0, sizeof(addr_un));
                    addr_un.sun_family = AF_UNIX;
                    strncpy(addr_un.sun_path, conn->path, sizeof(addr_un.sun_path) - 1);
                    memcpy(addr, &addr_un, sizeof(addr_un));
                    *addrlen = sizeof(addr_un);
                }
                return new_fd;
            }
        }
        return -1;
    }
    
    return real_accept(sockfd, addr, addrlen);
}

int accept4(int sockfd, struct sockaddr* addr, socklen_t* addrlen, int flags) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(sockfd);
    if (conn && conn->is_shmipc && conn->is_server) {
        int result = accept(sockfd, addr, addrlen);
        /* Note: flags are ignored for shmipc */
        return result;
    }
    
    if (real_accept4) {
        return real_accept4(sockfd, addr, addrlen, flags);
    }
    
    /* Fallback to accept */
    return accept(sockfd, addr, addrlen);
}

int close(int fd) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(fd);
    if (conn && conn->is_shmipc) {
        fprintf(stderr, "[shmipc] Closing shmipc connection\n");
        shmipc_go_close(conn->shmipc_handle);
        remove_conn(fd);
        return 0;
    }
    
    return real_close(fd);
}

ssize_t send(int sockfd, const void* buf, size_t len, int flags) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(sockfd);
    if (conn && conn->is_shmipc && !conn->is_server) {
        /* Note: flags are ignored for shmipc */
        return shmipc_go_send(conn->shmipc_handle, buf, len);
    }
    
    if (real_send) {
        return real_send(sockfd, buf, len, flags);
    }
    
    /* Fallback to write */
    return write(sockfd, buf, len);
}

ssize_t recv(int sockfd, void* buf, size_t len, int flags) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(sockfd);
    if (conn && conn->is_shmipc && !conn->is_server) {
        /* Note: flags are ignored for shmipc */
        return shmipc_go_recv(conn->shmipc_handle, buf, len);
    }
    
    if (real_recv) {
        return real_recv(sockfd, buf, len, flags);
    }
    
    /* Fallback to read */
    return read(sockfd, buf, len);
}

ssize_t write(int fd, const void* buf, size_t count) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(fd);
    if (conn && conn->is_shmipc && !conn->is_server) {
        return shmipc_go_send(conn->shmipc_handle, buf, count);
    }
    
    if (real_write) {
        return real_write(fd, buf, count);
    }
    
    return 0;
}

ssize_t read(int fd, void* buf, size_t count) {
    init_real_functions();
    
    shmipc_conn_t* conn = find_conn(fd);
    if (conn && conn->is_shmipc && !conn->is_server) {
        return shmipc_go_recv(conn->shmipc_handle, buf, count);
    }
    
    if (real_read) {
        return real_read(fd, buf, count);
    }
    
    return 0;
}