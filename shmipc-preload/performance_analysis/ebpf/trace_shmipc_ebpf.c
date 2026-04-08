// trace_shmipc_ebpf.c - eBPF 程序：追踪 shmipc 内存拷贝
// 编译: clang -g -O2 -target bpf -D__TARGET_ARCH_x86 -c trace_shmipc_ebpf.c -o trace_shmipc_ebpf.o

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

struct event_t {
    u32 pid;
    u32 tid;
    u64 timestamp;
    u64 size;
    char comm[16];
    char func[32];
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24);
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u32);
    __type(value, u64);
} memcpy_stats SEC(".maps");

SEC("uprobe/libc.so.6:memcpy")
int BPF_UPROBE(trace_memcpy, void *dst, void *src, size_t n) {
    struct event_t *e;
    
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    
    u64 id = bpf_get_current_pid_tgid();
    e->pid = id >> 32;
    e->tid = (u32)id;
    e->timestamp = bpf_ktime_get_ns();
    e->size = n;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    __builtin_memcpy(e->func, "memcpy", 7);
    
    bpf_ringbuf_submit(e, 0);
    
    u32 pid = e->pid;
    u64 *count = bpf_map_lookup_elem(&memcpy_stats, &pid);
    if (count) {
        __sync_fetch_and_add(count, n);
    } else {
        u64 init = n;
        bpf_map_update_elem(&memcpy_stats, &pid, &init, BPF_ANY);
    }
    
    return 0;
}

SEC("uprobe/libc.so.6:memmove")
int BPF_UPROBE(trace_memmove, void *dst, void *src, size_t n) {
    struct event_t *e;
    
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    
    u64 id = bpf_get_current_pid_tgid();
    e->pid = id >> 32;
    e->tid = (u32)id;
    e->timestamp = bpf_ktime_get_ns();
    e->size = n;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    __builtin_memcpy(e->func, "memmove", 8);
    
    bpf_ringbuf_submit(e, 0);
    
    return 0;
}

SEC("uprobe/libc.so.6:memset")
int BPF_UPROBE(trace_memset, void *s, int c, size_t n) {
    struct event_t *e;
    
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    
    u64 id = bpf_get_current_pid_tgid();
    e->pid = id >> 32;
    e->tid = (u32)id;
    e->timestamp = bpf_ktime_get_ns();
    e->size = n;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    __builtin_memcpy(e->func, "memset", 7);
    
    bpf_ringbuf_submit(e, 0);
    
    return 0;
}
