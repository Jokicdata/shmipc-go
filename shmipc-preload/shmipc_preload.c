/*
 * shmipc-transparent - 简化版透明代理
 * 
 * 使用方式：
 *   服务端：LD_PRELOAD=./libshmipc.so qperf
 *   客户端：LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat
 * 
 * 支持的工具：
 *   - qperf
 *   - sockperf
 *   - 任何使用 UDS 或本地 TCP 的程序
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

#define MAX_FDS 4096
#define LOG_ERROR 1
#define LOG_WARN  2
#define LOG_INFO  3
#define LOG_DEBUG 4

static int g_log_level = 1;
static int g_initialized = 0;

static int (*real_socket)(int, int, int);
static int (*real_bind)(int, const struct sockaddr *, socklen_t);
static int (*real_listen)(int, int);
static int (*real_accept)(int, struct sockaddr *, socklen_t *);
static int (*real_accept4)(int, struct sockaddr *, socklen_t *, int);
static int (*real_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t (*real_send)(int, const void *, size_t, int);
static ssize_t (*real_recv)(int, void *, size_t, int);
static ssize_t (*real_write)(int, const void *, size_t);
static ssize_t (*real_read)(int, void *, size_t);
static int (*real_close)(int);
static int (*real_setsockopt)(int, int, int, const void *, socklen_t);
static int (*real_getsockopt)(int, int, int, void *, socklen_t *);

typedef struct {
    int fd;
    int domain;
    int type;
    int is_shmipc;
    int is_connected;
    char path[256];
} fd_info_t;

static fd_info_t g_fds[MAX_FDS];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

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
    if (real_socket) return;
    
    real_socket = dlsym(RTLD_NEXT, "socket");
    real_bind = dlsym(RTLD_NEXT, "bind");
    real_listen = dlsym(RTLD_NEXT, "listen");
    real_accept = dlsym(RTLD_NEXT, "accept");
    real_accept4 = dlsym(RTLD_NEXT, "accept4");
    real_connect = dlsym(RTLD_NEXT, "connect");
    real_send = dlsym(RTLD_NEXT, "send");
    real_recv = dlsym(RTLD_NEXT, "recv");
    real_write = dlsym(RTLD_NEXT, "write");
    real_read = dlsym(RTLD_NEXT, "read");
    real_close = dlsym(RTLD_NEXT, "close");
    real_setsockopt = dlsym(RTLD_NEXT, "setsockopt");
    real_getsockopt = dlsym(RTLD_NEXT, "getsockopt");
}

static fd_info_t* get_fd_info(int fd) {
    if (fd < 0 || fd >= MAX_FDS) return NULL;
    return &g_fds[fd];
}

static int should_use_shmipc(int domain, int type) {
    if (domain == AF_UNIX) return 1;
    if (domain == AF_INET || domain == AF_INET6) {
        if (type == SOCK_STREAM) return 1;
    }
    return 0;
}

static int is_loopback_addr(const struct sockaddr *addr) {
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)addr;
        return (ntohl(in->sin_addr.s_addr) == 0x7f000001);
    }
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
        static const unsigned char loopback[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
        return (memcmp(in6->sin6_addr.s6_addr, loopback, 16) == 0);
    }
    return 0;
}

__attribute__((constructor))
static void lib_init(void) {
    init_real_funcs();
    
    char *level = getenv("SHMIPC_LOG");
    if (level) g_log_level = atoi(level);
    
    memset(g_fds, 0, sizeof(g_fds));
    g_initialized = 1;
    
    log_msg(LOG_INFO, "shmipc-transparent loaded (log level: %d)", g_log_level);
}

__attribute__((destructor))
static void lib_fini(void) {
    log_msg(LOG_INFO, "shmipc-transparent unloaded");
}

int socket(int domain, int type, int protocol) {
    init_real_funcs();
    
    int fd = real_socket(domain, type, protocol);
    if (fd >= 0) {
        fd_info_t *info = get_fd_info(fd);
        if (info) {
            info->fd = fd;
            info->domain = domain;
            info->type = type;
            info->is_shmipc = should_use_shmipc(domain, type);
            info->is_connected = 0;
            info->path[0] = '\0';
        }
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d %s", 
               domain, type, protocol, fd, 
               should_use_shmipc(domain, type) ? "[shmipc]" : "");
    }
    return fd;
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    if (info && addr->sa_family == AF_UNIX) {
        struct sockaddr_un *un = (struct sockaddr_un *)addr;
        strncpy(info->path, un->sun_path, sizeof(info->path) - 1);
        log_msg(LOG_DEBUG, "bind(%d, \"%s\") [shmipc]", sockfd, info->path);
    }
    
    return real_bind(sockfd, addr, addrlen);
}

int listen(int sockfd, int backlog) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    if (info && info->is_shmipc) {
        log_msg(LOG_DEBUG, "listen(%d, %d) [shmipc]", sockfd, backlog);
    }
    
    return real_listen(sockfd, backlog);
}

int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_real_funcs();
    
    int fd = real_accept(sockfd, addr, addrlen);
    if (fd >= 0) {
        fd_info_t *server = get_fd_info(sockfd);
        fd_info_t *client = get_fd_info(fd);
        
        if (server && client) {
            client->fd = fd;
            client->domain = server->domain;
            client->type = server->type;
            client->is_shmipc = server->is_shmipc;
            client->is_connected = 1;
            strncpy(client->path, server->path, sizeof(client->path) - 1);
            
            log_msg(LOG_DEBUG, "accept(%d) = %d [shmipc]", sockfd, fd);
        }
    }
    return fd;
}

int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    init_real_funcs();
    
    int fd = real_accept4(sockfd, addr, addrlen, flags);
    if (fd >= 0) {
        fd_info_t *server = get_fd_info(sockfd);
        fd_info_t *client = get_fd_info(fd);
        
        if (server && client) {
            client->fd = fd;
            client->domain = server->domain;
            client->type = server->type;
            client->is_shmipc = server->is_shmipc;
            client->is_connected = 1;
            strncpy(client->path, server->path, sizeof(client->path) - 1);
            
            log_msg(LOG_DEBUG, "accept4(%d) = %d [shmipc]", sockfd, fd);
        }
    }
    return fd;
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    
    if (info && info->is_shmipc) {
        if (addr->sa_family == AF_UNIX) {
            struct sockaddr_un *un = (struct sockaddr_un *)addr;
            strncpy(info->path, un->sun_path, sizeof(info->path) - 1);
            log_msg(LOG_DEBUG, "connect(%d, \"%s\") [shmipc]", sockfd, info->path);
        } else if (is_loopback_addr(addr)) {
            log_msg(LOG_DEBUG, "connect(%d, loopback) [shmipc]", sockfd);
        }
    }
    
    int ret = real_connect(sockfd, addr, addrlen);
    if (ret == 0 && info) {
        info->is_connected = 1;
    }
    return ret;
}

ssize_t send(int sockfd, const void *buf, size_t len, int flags) {
    init_real_funcs();
    return real_send(sockfd, buf, len, flags);
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    init_real_funcs();
    return real_recv(sockfd, buf, len, flags);
}

ssize_t write(int fd, const void *buf, size_t count) {
    init_real_funcs();
    return real_write(fd, buf, count);
}

ssize_t read(int fd, void *buf, size_t count) {
    init_real_funcs();
    return real_read(fd, buf, count);
}

int close(int fd) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(fd);
    if (info) {
        memset(info, 0, sizeof(*info));
    }
    
    return real_close(fd);
}

int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen) {
    init_real_funcs();
    return real_setsockopt(sockfd, level, optname, optval, optlen);
}

int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen) {
    init_real_funcs();
    return real_getsockopt(sockfd, level, optname, optval, optlen);
}
