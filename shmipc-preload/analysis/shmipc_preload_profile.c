/*
 * shmipc-preload 性能分析版本
 * 
 * 功能：在关键路径添加高精度时间戳，用于分析性能瓶颈
 * 
 * 使用方式：
 *   SHMIPC_PROFILE=1 LD_PRELOAD=./libshmipc_profile.so <your-program>
 * 
 * 输出：
 *   /tmp/shmipc_profile_<pid>.log
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

#define MAX_FDS 4096
#define MAX_PATH 256
#define SHM_BUFFER_SIZE (32 * 1024 * 1024)
#define QUEUE_CAPACITY 8192

#define LOG_SILENT 0
#define LOG_ERROR  1
#define LOG_WARN   2
#define LOG_INFO   3
#define LOG_DEBUG  4

#define CONN_TYPE_SOCKET 0
#define CONN_TYPE_SHMIPC 1

#define STREAM_STATE_OPEN   0
#define STREAM_STATE_CLOSED 1

extern int ShmipcInit(void);
extern void ShmipcCleanup(void);
extern int ShmipcCreateClientSession(int fd, const char *path);
extern int ShmipcCreateServerSession(int fd, const char *path);
extern int ShmipcOpenStream(int fd);
extern int ShmipcAcceptStream(int fd);
extern long ShmipcWrite(int stream_id, const void *data, long length);
extern long ShmipcRead(int stream_id, void *data, long length);
extern int ShmipcCloseStream(int stream_id);
extern int ShmipcCloseSession(int fd);
extern int ShmipcGetStats(void *stats);

static int g_log_level = LOG_ERROR;
static int g_initialized = 0;
static int g_shmipc_enabled = 1;
static int g_profile_enabled = 0;
static FILE *g_profile_file = NULL;
static __thread char g_thread_name[32] = {0};

static int (*real_socket)(int, int, int);
static int (*real_bind)(int, const struct sockaddr *, socklen_t);
static int (*real_listen)(int, int);
static int (*real_accept)(int, struct sockaddr *, socklen_t *);
static int (*real_accept4)(int, struct sockaddr *, socklen_t *, int);
static int (*real_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t (*real_send)(int, const void *, size_t, int);
static ssize_t (*real_recv)(int, void *, size_t, int);
static ssize_t (*real_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t (*real_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t (*real_write)(int, const void *, size_t);
static ssize_t (*real_read)(int, void *, size_t);
static ssize_t (*real_writev)(int, const struct iovec *, int);
static ssize_t (*real_readv)(int, const struct iovec *, int);
static int (*real_close)(int);
static int (*real_shutdown)(int, int);
static int (*real_getsockopt)(int, int, int, void *, socklen_t *);
static int (*real_setsockopt)(int, int, int, const void *, socklen_t);
static int (*real_fcntl)(int, int, ...);
static int (*real_dup)(int);
static int (*real_dup2)(int, int);

typedef struct {
    int fd;
    int domain;
    int type;
    int protocol;
    int conn_type;
    int is_connected;
    int is_listening;
    int is_server;
    int stream_id;
    char path[MAX_PATH];
    pthread_mutex_t lock;
    
    uint64_t total_write_calls;
    uint64_t total_read_calls;
    uint64_t total_write_bytes;
    uint64_t total_read_bytes;
    uint64_t total_write_ns;
    uint64_t total_read_ns;
    uint64_t max_write_ns;
    uint64_t max_read_ns;
} fd_info_t;

static fd_info_t g_fds[MAX_FDS];
static pthread_mutex_t g_global_lock = PTHREAD_MUTEX_INITIALIZER;

static struct {
    uint64_t total_connections;
    uint64_t shmipc_connections;
    uint64_t socket_connections;
    uint64_t total_bytes_sent;
    uint64_t total_bytes_recv;
    uint64_t shmipc_bytes_sent;
    uint64_t shmipc_bytes_recv;
    uint64_t cgo_call_count;
    uint64_t cgo_total_ns;
    uint64_t cgo_max_ns;
} g_stats;

static inline uint64_t get_ns_timestamp(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void init_thread_name(void) {
    if (g_thread_name[0] == '\0') {
        pthread_getname_np(pthread_self(), g_thread_name, sizeof(g_thread_name));
    }
}

static void profile_log(const char *event, uint64_t start_ns, uint64_t end_ns, 
                        int fd, int stream_id, size_t bytes, const char *extra) {
    if (!g_profile_enabled || !g_profile_file) return;
    
    uint64_t duration_ns = end_ns - start_ns;
    
    fprintf(g_profile_file, 
            "[%" PRIu64 "] [%s] [%s] fd=%d stream=%d bytes=%zu duration=%" PRIu64 "ns %s\n",
            start_ns, g_thread_name, event, fd, stream_id, bytes, duration_ns, 
            extra ? extra : "");
    fflush(g_profile_file);
}

static void log_msg(int level, const char *fmt, ...) {
    if (level > g_log_level) return;
    
    const char *levels[] = {"", "ERROR", "WARN", "INFO", "DEBUG"};
    fprintf(stderr, "[shmipc][%s] ", levels[level]);
    
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

static void init_real_funcs(void) {
    if (real_socket != NULL) return;
    
    real_socket = dlsym(RTLD_NEXT, "socket");
    real_bind = dlsym(RTLD_NEXT, "bind");
    real_listen = dlsym(RTLD_NEXT, "listen");
    real_accept = dlsym(RTLD_NEXT, "accept");
    real_accept4 = dlsym(RTLD_NEXT, "accept4");
    real_connect = dlsym(RTLD_NEXT, "connect");
    real_send = dlsym(RTLD_NEXT, "send");
    real_recv = dlsym(RTLD_NEXT, "recv");
    real_sendto = dlsym(RTLD_NEXT, "sendto");
    real_recvfrom = dlsym(RTLD_NEXT, "recvfrom");
    real_write = dlsym(RTLD_NEXT, "write");
    real_read = dlsym(RTLD_NEXT, "read");
    real_writev = dlsym(RTLD_NEXT, "writev");
    real_readv = dlsym(RTLD_NEXT, "readv");
    real_close = dlsym(RTLD_NEXT, "close");
    real_shutdown = dlsym(RTLD_NEXT, "shutdown");
    real_getsockopt = dlsym(RTLD_NEXT, "getsockopt");
    real_setsockopt = dlsym(RTLD_NEXT, "setsockopt");
    real_fcntl = dlsym(RTLD_NEXT, "fcntl");
    real_dup = dlsym(RTLD_NEXT, "dup");
    real_dup2 = dlsym(RTLD_NEXT, "dup2");
}

static fd_info_t* get_fd_info(int fd) {
    if (fd < 0 || fd >= MAX_FDS) return NULL;
    return &g_fds[fd];
}

static void init_fd_info(int fd, int domain, int type, int protocol) {
    if (fd < 0 || fd >= MAX_FDS) return;
    
    fd_info_t *info = &g_fds[fd];
    memset(info, 0, sizeof(*info));
    info->fd = fd;
    info->domain = domain;
    info->type = type;
    info->protocol = protocol;
    info->conn_type = CONN_TYPE_SOCKET;
    info->stream_id = -1;
    pthread_mutex_init(&info->lock, NULL);
}

static void cleanup_fd_info(int fd) {
    fd_info_t *info = get_fd_info(fd);
    if (info == NULL) return;
    
    pthread_mutex_lock(&info->lock);
    
    if (info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        ShmipcCloseStream(info->stream_id);
        info->stream_id = -1;
    }
    
    if (info->conn_type == CONN_TYPE_SHMIPC) {
        ShmipcCloseSession(fd);
    }
    
    if (g_profile_enabled && g_profile_file) {
        fprintf(g_profile_file, 
                "[STATS] fd=%d write_calls=%" PRIu64 " read_calls=%" PRIu64 
                " write_bytes=%" PRIu64 " read_bytes=%" PRIu64 
                " avg_write_ns=%" PRIu64 " avg_read_ns=%" PRIu64 
                " max_write_ns=%" PRIu64 " max_read_ns=%" PRIu64 "\n",
                fd, info->total_write_calls, info->total_read_calls,
                info->total_write_bytes, info->total_read_bytes,
                info->total_write_calls ? info->total_write_ns / info->total_write_calls : 0,
                info->total_read_calls ? info->total_read_ns / info->total_read_calls : 0,
                info->max_write_ns, info->max_read_ns);
        fflush(g_profile_file);
    }
    
    pthread_mutex_unlock(&info->lock);
    pthread_mutex_destroy(&info->lock);
    memset(info, 0, sizeof(*info));
}

static int should_use_shmipc(int domain, int type) {
    if (!g_shmipc_enabled) return 0;
    
    if (domain == AF_UNIX) return 1;
    
    if ((domain == AF_INET || domain == AF_INET6) && type == SOCK_STREAM) {
        return 1;
    }
    
    return 0;
}

static int is_loopback_addr(const struct sockaddr *addr, socklen_t addrlen) {
    if (addr == NULL) return 0;
    
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)addr;
        uint32_t ip = ntohl(in->sin_addr.s_addr);
        return (ip == 0x7f000001);
    }
    
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
        static const unsigned char loopback[16] = {
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1
        };
        return (memcmp(in6->sin6_addr.s6_addr, loopback, 16) == 0);
    }
    
    return 0;
}

__attribute__((constructor))
static void lib_init(void) {
    init_real_funcs();
    
    char *log_env = getenv("SHMIPC_LOG");
    if (log_env) {
        g_log_level = atoi(log_env);
    }
    
    char *enable_env = getenv("SHMIPC_ENABLE");
    if (enable_env && strcmp(enable_env, "0") == 0) {
        g_shmipc_enabled = 0;
    }
    
    char *profile_env = getenv("SHMIPC_PROFILE");
    if (profile_env && strcmp(profile_env, "1") == 0) {
        g_profile_enabled = 1;
        char profile_path[256];
        snprintf(profile_path, sizeof(profile_path), 
                 "/tmp/shmipc_profile_%d.log", getpid());
        g_profile_file = fopen(profile_path, "w");
        if (g_profile_file) {
            fprintf(g_profile_file, "# shmipc profile log\n");
            fprintf(g_profile_file, "# timestamp_ns thread event fd stream bytes duration_ns extra\n");
            fflush(g_profile_file);
        }
    }
    
    memset(g_fds, 0, sizeof(g_fds));
    memset(&g_stats, 0, sizeof(g_stats));
    
    int ret = ShmipcInit();
    if (ret != 0) {
        log_msg(LOG_WARN, "ShmipcInit failed: %d, fallback to socket", ret);
        g_shmipc_enabled = 0;
    }
    
    g_initialized = 1;
    log_msg(LOG_INFO, "shmipc-preload loaded (enabled: %d, log: %d, profile: %d)", 
            g_shmipc_enabled, g_log_level, g_profile_enabled);
}

__attribute__((destructor))
static void lib_fini(void) {
    if (g_profile_enabled && g_profile_file) {
        fprintf(g_profile_file, "\n# Final Statistics\n");
        fprintf(g_profile_file, "# CGO calls: %" PRIu64 " total_ns: %" PRIu64 " avg_ns: %" PRIu64 " max_ns: %" PRIu64 "\n",
                g_stats.cgo_call_count, g_stats.cgo_total_ns,
                g_stats.cgo_call_count ? g_stats.cgo_total_ns / g_stats.cgo_call_count : 0,
                g_stats.cgo_max_ns);
        fflush(g_profile_file);
        fclose(g_profile_file);
    }
    
    for (int i = 0; i < MAX_FDS; i++) {
        if (g_fds[i].fd > 0) {
            cleanup_fd_info(i);
        }
    }
    
    ShmipcCleanup();
    log_msg(LOG_INFO, "shmipc-preload unloaded");
}

int socket(int domain, int type, int protocol) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    int fd = real_socket(domain, type, protocol);
    if (fd < 0) return fd;
    
    init_fd_info(fd, domain, type, protocol);
    
    fd_info_t *info = get_fd_info(fd);
    if (info && should_use_shmipc(domain, type)) {
        info->conn_type = CONN_TYPE_SHMIPC;
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [shmipc]", 
               domain, type, protocol, fd);
    } else {
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [socket]", 
               domain, type, protocol, fd);
    }
    
    uint64_t end_ns = get_ns_timestamp();
    profile_log("socket", start_ns, end_ns, fd, -1, 0, NULL);
    
    __sync_fetch_and_add(&g_stats.total_connections, 1);
    return fd;
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    
    if (info && addr) {
        if (addr->sa_family == AF_UNIX) {
            struct sockaddr_un *un = (struct sockaddr_un *)addr;
            strncpy(info->path, un->sun_path, MAX_PATH - 1);
            info->is_server = 1;
            log_msg(LOG_DEBUG, "bind(%d, \"%s\") [shmipc]", sockfd, info->path);
        }
    }
    
    return real_bind(sockfd, addr, addrlen);
}

int listen(int sockfd, int backlog) {
    init_real_funcs();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *info = get_fd_info(sockfd);
    if (info) {
        info->is_listening = 1;
        
        if (info->conn_type == CONN_TYPE_SHMIPC && info->is_server) {
            int ret = ShmipcCreateServerSession(sockfd, info->path);
            if (ret != 0) {
                log_msg(LOG_WARN, "ShmipcCreateServerSession failed: %d", ret);
            }
            log_msg(LOG_DEBUG, "listen(%d, %d) [shmipc]", sockfd, backlog);
        }
    }
    
    int ret = real_listen(sockfd, backlog);
    
    uint64_t end_ns = get_ns_timestamp();
    profile_log("listen", start_ns, end_ns, sockfd, -1, 0, NULL);
    
    return ret;
}

int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *server_info = get_fd_info(sockfd);
    
    int client_fd = real_accept(sockfd, addr, addrlen);
    if (client_fd < 0) return client_fd;
    
    if (server_info && server_info->conn_type == CONN_TYPE_SHMIPC) {
        init_fd_info(client_fd, server_info->domain, server_info->type, server_info->protocol);
        
        fd_info_t *client_info = get_fd_info(client_fd);
        if (client_info) {
            client_info->conn_type = CONN_TYPE_SHMIPC;
            client_info->is_connected = 1;
            client_info->is_server = 0;
            strncpy(client_info->path, server_info->path, MAX_PATH - 1);
            
            uint64_t cgo_start = get_ns_timestamp();
            int stream_id = ShmipcAcceptStream(sockfd);
            uint64_t cgo_end = get_ns_timestamp();
            
            uint64_t cgo_duration = cgo_end - cgo_start;
            __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
            __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
            
            if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
                __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
            }
            
            if (stream_id >= 0) {
                client_info->stream_id = stream_id;
                log_msg(LOG_DEBUG, "accept(%d) = %d, stream=%d [shmipc]", 
                       sockfd, client_fd, stream_id);
            }
            
            __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
        }
    } else {
        __sync_fetch_and_add(&g_stats.socket_connections, 1);
    }
    
    uint64_t end_ns = get_ns_timestamp();
    profile_log("accept", start_ns, end_ns, client_fd, 
                client_info ? client_info->stream_id : -1, 0, NULL);
    
    return client_fd;
}

int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *server_info = get_fd_info(sockfd);
    
    int client_fd = real_accept4(sockfd, addr, addrlen, flags);
    if (client_fd < 0) return client_fd;
    
    if (server_info && server_info->conn_type == CONN_TYPE_SHMIPC) {
        init_fd_info(client_fd, server_info->domain, server_info->type, server_info->protocol);
        
        fd_info_t *client_info = get_fd_info(client_fd);
        if (client_info) {
            client_info->conn_type = CONN_TYPE_SHMIPC;
            client_info->is_connected = 1;
            client_info->is_server = 0;
            strncpy(client_info->path, server_info->path, MAX_PATH - 1);
            
            uint64_t cgo_start = get_ns_timestamp();
            int stream_id = ShmipcAcceptStream(sockfd);
            uint64_t cgo_end = get_ns_timestamp();
            
            uint64_t cgo_duration = cgo_end - cgo_start;
            __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
            __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
            
            if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
                __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
            }
            
            if (stream_id >= 0) {
                client_info->stream_id = stream_id;
                log_msg(LOG_DEBUG, "accept4(%d) = %d, stream=%d [shmipc]", 
                       sockfd, client_fd, stream_id);
            }
            
            __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
        }
    } else {
        __sync_fetch_and_add(&g_stats.socket_connections, 1);
    }
    
    uint64_t end_ns = get_ns_timestamp();
    profile_log("accept4", start_ns, end_ns, client_fd, 
                client_info ? client_info->stream_id : -1, 0, NULL);
    
    return client_fd;
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *info = get_fd_info(sockfd);
    int use_shmipc = 0;
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC) {
        if (addr && addr->sa_family == AF_UNIX) {
            struct sockaddr_un *un = (struct sockaddr_un *)addr;
            strncpy(info->path, un->sun_path, MAX_PATH - 1);
            use_shmipc = 1;
        } else if (addr && is_loopback_addr(addr, addrlen)) {
            use_shmipc = 1;
        }
    }
    
    int ret = real_connect(sockfd, addr, addrlen);
    
    if (ret == 0 && info) {
        info->is_connected = 1;
        
        if (use_shmipc) {
            uint64_t cgo_start = get_ns_timestamp();
            int shmipc_ret = ShmipcCreateClientSession(sockfd, info->path);
            uint64_t cgo_end = get_ns_timestamp();
            
            uint64_t cgo_duration = cgo_end - cgo_start;
            __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
            __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
            
            if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
                __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
            }
            
            if (shmipc_ret == 0) {
                cgo_start = get_ns_timestamp();
                int stream_id = ShmipcOpenStream(sockfd);
                cgo_end = get_ns_timestamp();
                
                cgo_duration = cgo_end - cgo_start;
                __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
                __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
                
                if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
                    __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
                }
                
                if (stream_id >= 0) {
                    info->stream_id = stream_id;
                    log_msg(LOG_DEBUG, "connect(%d, \"%s\") stream=%d [shmipc]", 
                           sockfd, info->path, stream_id);
                }
            } else {
                log_msg(LOG_WARN, "ShmipcCreateClientSession failed: %d", shmipc_ret);
            }
            
            __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
        } else {
            __sync_fetch_and_add(&g_stats.socket_connections, 1);
        }
    }
    
    uint64_t end_ns = get_ns_timestamp();
    profile_log("connect", start_ns, end_ns, sockfd, info ? info->stream_id : -1, 0, NULL);
    
    return ret;
}

ssize_t send(int sockfd, const void *buf, size_t len, int flags) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *info = get_fd_info(sockfd);
    ssize_t ret;
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        uint64_t cgo_start = get_ns_timestamp();
        long shmipc_ret = ShmipcWrite(info->stream_id, buf, (long)len);
        uint64_t cgo_end = get_ns_timestamp();
        
        uint64_t cgo_duration = cgo_end - cgo_start;
        __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
        __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
        
        if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
            __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
        }
        
        if (shmipc_ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, shmipc_ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, shmipc_ret);
            
            info->total_write_calls++;
            info->total_write_bytes += shmipc_ret;
            info->total_write_ns += cgo_duration;
            if (cgo_duration > info->max_write_ns) {
                info->max_write_ns = cgo_duration;
            }
            
            ret = (ssize_t)shmipc_ret;
        } else {
            ret = shmipc_ret;
        }
        
        uint64_t end_ns = get_ns_timestamp();
        char extra[64];
        snprintf(extra, sizeof(extra), "cgo_ns=%" PRIu64, cgo_duration);
        profile_log("send_shmipc", start_ns, end_ns, sockfd, info->stream_id, ret, extra);
    } else {
        ret = real_send(sockfd, buf, len, flags);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
        }
        
        uint64_t end_ns = get_ns_timestamp();
        profile_log("send_socket", start_ns, end_ns, sockfd, -1, ret, NULL);
    }
    
    return ret;
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *info = get_fd_info(sockfd);
    ssize_t ret;
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        uint64_t cgo_start = get_ns_timestamp();
        long shmipc_ret = ShmipcRead(info->stream_id, buf, (long)len);
        uint64_t cgo_end = get_ns_timestamp();
        
        uint64_t cgo_duration = cgo_end - cgo_start;
        __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
        __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
        
        if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
            __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
        }
        
        if (shmipc_ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, shmipc_ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, shmipc_ret);
            
            info->total_read_calls++;
            info->total_read_bytes += shmipc_ret;
            info->total_read_ns += cgo_duration;
            if (cgo_duration > info->max_read_ns) {
                info->max_read_ns = cgo_duration;
            }
            
            ret = (ssize_t)shmipc_ret;
        } else {
            ret = shmipc_ret;
        }
        
        uint64_t end_ns = get_ns_timestamp();
        char extra[64];
        snprintf(extra, sizeof(extra), "cgo_ns=%" PRIu64, cgo_duration);
        profile_log("recv_shmipc", start_ns, end_ns, sockfd, info->stream_id, ret, extra);
    } else {
        ret = real_recv(sockfd, buf, len, flags);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
        }
        
        uint64_t end_ns = get_ns_timestamp();
        profile_log("recv_socket", start_ns, end_ns, sockfd, -1, ret, NULL);
    }
    
    return ret;
}

ssize_t write(int fd, const void *buf, size_t count) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *info = get_fd_info(fd);
    ssize_t ret;
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        uint64_t cgo_start = get_ns_timestamp();
        long shmipc_ret = ShmipcWrite(info->stream_id, buf, (long)count);
        uint64_t cgo_end = get_ns_timestamp();
        
        uint64_t cgo_duration = cgo_end - cgo_start;
        __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
        __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
        
        if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
            __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
        }
        
        if (shmipc_ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, shmipc_ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, shmipc_ret);
            
            info->total_write_calls++;
            info->total_write_bytes += shmipc_ret;
            info->total_write_ns += cgo_duration;
            if (cgo_duration > info->max_write_ns) {
                info->max_write_ns = cgo_duration;
            }
            
            ret = (ssize_t)shmipc_ret;
        } else {
            ret = shmipc_ret;
        }
        
        uint64_t end_ns = get_ns_timestamp();
        char extra[64];
        snprintf(extra, sizeof(extra), "cgo_ns=%" PRIu64, cgo_duration);
        profile_log("write_shmipc", start_ns, end_ns, fd, info->stream_id, ret, extra);
    } else {
        ret = real_write(fd, buf, count);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
        }
        
        uint64_t end_ns = get_ns_timestamp();
        profile_log("write_socket", start_ns, end_ns, fd, -1, ret, NULL);
    }
    
    return ret;
}

ssize_t read(int fd, void *buf, size_t count) {
    init_real_funcs();
    init_thread_name();
    
    uint64_t start_ns = get_ns_timestamp();
    
    fd_info_t *info = get_fd_info(fd);
    ssize_t ret;
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        uint64_t cgo_start = get_ns_timestamp();
        long shmipc_ret = ShmipcRead(info->stream_id, buf, (long)count);
        uint64_t cgo_end = get_ns_timestamp();
        
        uint64_t cgo_duration = cgo_end - cgo_start;
        __sync_fetch_and_add(&g_stats.cgo_call_count, 1);
        __sync_fetch_and_add(&g_stats.cgo_total_ns, cgo_duration);
        
        if (cgo_duration > __atomic_load_n(&g_stats.cgo_max_ns, __ATOMIC_RELAXED)) {
            __atomic_store_n(&g_stats.cgo_max_ns, cgo_duration, __ATOMIC_RELAXED);
        }
        
        if (shmipc_ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, shmipc_ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, shmipc_ret);
            
            info->total_read_calls++;
            info->total_read_bytes += shmipc_ret;
            info->total_read_ns += cgo_duration;
            if (cgo_duration > info->max_read_ns) {
                info->max_read_ns = cgo_duration;
            }
            
            ret = (ssize_t)shmipc_ret;
        } else {
            ret = shmipc_ret;
        }
        
        uint64_t end_ns = get_ns_timestamp();
        char extra[64];
        snprintf(extra, sizeof(extra), "cgo_ns=%" PRIu64, cgo_duration);
        profile_log("read_shmipc", start_ns, end_ns, fd, info->stream_id, ret, extra);
    } else {
        ret = real_read(fd, buf, count);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
        }
        
        uint64_t end_ns = get_ns_timestamp();
        profile_log("read_socket", start_ns, end_ns, fd, -1, ret, NULL);
    }
    
    return ret;
}

int close(int fd) {
    init_real_funcs();
    
    uint64_t start_ns = get_ns_timestamp();
    
    cleanup_fd_info(fd);
    
    int ret = real_close(fd);
    
    uint64_t end_ns = get_ns_timestamp();
    profile_log("close", start_ns, end_ns, fd, -1, 0, NULL);
    
    return ret;
}

int shutdown(int sockfd, int how) {
    init_real_funcs();
    return real_shutdown(sockfd, how);
}

int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen) {
    init_real_funcs();
    return real_getsockopt(sockfd, level, optname, optval, optlen);
}

int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen) {
    init_real_funcs();
    return real_setsockopt(sockfd, level, optname, optval, optlen);
}

int fcntl(int fd, int cmd, ...) {
    init_real_funcs();
    
    va_list args;
    va_start(args, cmd);
    void *arg = va_arg(args, void *);
    va_end(args);
    
    return real_fcntl(fd, cmd, arg);
}

int dup(int oldfd) {
    init_real_funcs();
    return real_dup(oldfd);
}

int dup2(int oldfd, int newfd) {
    init_real_funcs();
    return real_dup2(oldfd, newfd);
}

ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
               const struct sockaddr *dest_addr, socklen_t addrlen) {
    init_real_funcs();
    return real_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
}

ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
                 struct sockaddr *src_addr, socklen_t *addrlen) {
    init_real_funcs();
    return real_recvfrom(sockfd, buf, len, flags, src_addr, addrlen);
}

ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();
    return real_writev(fd, iov, iovcnt);
}

ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();
    return real_readv(fd, iov, iovcnt);
}
