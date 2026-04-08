#!/usr/bin/env python3
"""
eBPF User-space Program for shmipc Memory Tracing
Requires: bcc (BPF Compiler Collection)

Usage:
    sudo python3 trace_shmipc_ebpf.py <pid>
"""

from bcc import BPF
import sys
import time
import argparse
from collections import defaultdict

bpf_program = """
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>

struct event_t {
    u32 pid;
    u32 tid;
    u64 timestamp;
    u64 size;
    char comm[16];
    char func[32];
};

BPF_RINGBUF_OUTPUT(events, 1 << 24);
BPF_HASH(memcpy_stats, u32, u64);

int trace_memcpy(struct pt_regs *ctx) {
    struct event_t e = {};
    u64 id = bpf_get_current_pid_tgid();
    
    e.pid = id >> 32;
    e.tid = (u32)id;
    e.timestamp = bpf_ktime_get_ns();
    e.size = PT_REGS_PARM3(ctx);
    bpf_get_current_comm(&e.comm, sizeof(e.comm));
    __builtin_memcpy(e.func, "memcpy", 7);
    
    events.ringbuf_output(&e, sizeof(e), 0);
    
    u64 *count = memcpy_stats.lookup(&e.pid);
    if (count) {
        (*count) += e.size;
    } else {
        u64 init = e.size;
        memcpy_stats.update(&e.pid, &init);
    }
    
    return 0;
}

int trace_memmove(struct pt_regs *ctx) {
    struct event_t e = {};
    u64 id = bpf_get_current_pid_tgid();
    
    e.pid = id >> 32;
    e.tid = (u32)id;
    e.timestamp = bpf_ktime_get_ns();
    e.size = PT_REGS_PARM3(ctx);
    bpf_get_current_comm(&e.comm, sizeof(e.comm));
    __builtin_memcpy(e.func, "memmove", 8);
    
    events.ringbuf_output(&e, sizeof(e), 0);
    
    return 0;
}
"""

def main():
    parser = argparse.ArgumentParser(description='Trace memory operations in shmipc')
    parser.add_argument('pid', type=int, nargs='?', help='PID to trace (optional, traces all if not specified)')
    parser.add_argument('--duration', type=int, default=10, help='Duration to trace (seconds)')
    args = parser.parse_args()
    
    print(f"Loading eBPF program...")
    b = BPF(text=bpf_program)
    
    print("Attaching probes...")
    b.attach_uprobe(name="c", sym="memcpy", fn_name="trace_memcpy")
    b.attach_uprobe(name="c", sym="memmove", fn_name="trace_memmove")
    
    stats = defaultdict(lambda: {'count': 0, 'total_size': 0, 'funcs': defaultdict(int)})
    
    def handle_event(cpu, data, size):
        event = b['events'].event(data)
        
        if args.pid and event.pid != args.pid:
            return
        
        stats[event.pid]['count'] += 1
        stats[event.pid]['total_size'] += event.size
        stats[event.pid]['funcs'][event.func.decode()] += 1
        
        if event.size > 4096:
            print(f"[{event.pid}:{event.tid}] {event.func.decode()}: {event.size} bytes ({event.comm.decode()})")
    
    b['events'].open_ring_buffer(handle_event)
    
    print(f"Tracing for {args.duration} seconds... (Ctrl+C to stop)")
    print("=" * 80)
    
    try:
        for i in range(args.duration):
            b.ring_buffer_poll(timeout=1000)
            if i > 0 and i % 5 == 0:
                print(f"\n--- Stats at {i}s ---")
                for pid, data in sorted(stats.items(), key=lambda x: x[1]['total_size'], reverse=True)[:5]:
                    print(f"  PID {pid}: {data['count']} calls, {data['total_size']/1024/1024:.2f} MB")
    except KeyboardInterrupt:
        pass
    
    print("\n" + "=" * 80)
    print("=== Final Statistics ===")
    print("=" * 80)
    
    for pid, data in sorted(stats.items(), key=lambda x: x[1]['total_size'], reverse=True):
        print(f"\nPID {pid}:")
        print(f"  Total calls: {data['count']}")
        print(f"  Total bytes: {data['total_size']:,} ({data['total_size']/1024/1024:.2f} MB)")
        print(f"  Avg size: {data['total_size']/data['count']:.0f} bytes")
        print(f"  By function:")
        for func, count in sorted(data['funcs'].items(), key=lambda x: x[1], reverse=True):
            print(f"    {func}: {count} calls")

if __name__ == '__main__':
    main()
