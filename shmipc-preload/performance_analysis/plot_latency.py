#!/usr/bin/env python3

import sys
import csv
import matplotlib.pyplot as plt
import numpy as np

def plot_latency(csv_file):
    data = {
        'socket': {'sizes': [], 'latency': [], 'p50': [], 'p90': [], 'p99': []},
        'shmipc_orig': {'sizes': [], 'latency': [], 'p50': [], 'p90': [], 'p99': []},
        'shmipc_opt': {'sizes': [], 'latency': [], 'p50': [], 'p90': [], 'p99': []}
    }
    
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            conn_type = row['Type']
            if conn_type in data:
                data[conn_type]['sizes'].append(int(row['Size(Bytes)']))
                data[conn_type]['latency'].append(float(row['Latency(us)']))
                data[conn_type]['p50'].append(float(row['Percentile_50(us)']))
                data[conn_type]['p90'].append(float(row['Percentile_90(us)']))
                data[conn_type]['p99'].append(float(row['Percentile_99(us)']))
    
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    
    ax1 = axes[0, 0]
    for label, d in data.items():
        if d['sizes']:
            ax1.plot(d['sizes'], d['latency'], marker='o', label=label, linewidth=2)
    ax1.set_xlabel('Message Size (bytes)', fontsize=12)
    ax1.set_ylabel('Average Latency (μs)', fontsize=12)
    ax1.set_title('Average Latency vs Message Size', fontsize=14)
    ax1.set_xscale('log', base=2)
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    
    ax2 = axes[0, 1]
    for label, d in data.items():
        if d['sizes']:
            ax2.plot(d['sizes'], d['p99'], marker='s', label=label, linewidth=2)
    ax2.set_xlabel('Message Size (bytes)', fontsize=12)
    ax2.set_ylabel('P99 Latency (μs)', fontsize=12)
    ax2.set_title('P99 Latency vs Message Size', fontsize=14)
    ax2.set_xscale('log', base=2)
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    
    ax3 = axes[1, 0]
    x = np.arange(len(data['socket']['sizes']))
    width = 0.25
    
    if data['socket']['sizes']:
        sizes_labels = [str(s) for s in data['socket']['sizes']]
        
        ax3.bar(x - width, data['socket']['latency'], width, label='socket', alpha=0.8)
        if data['shmipc_orig']['latency']:
            ax3.bar(x, data['shmipc_orig']['latency'], width, label='shmipc_orig', alpha=0.8)
        if data['shmipc_opt']['latency']:
            ax3.bar(x + width, data['shmipc_opt']['latency'], width, label='shmipc_opt', alpha=0.8)
        
        ax3.set_xlabel('Message Size (bytes)', fontsize=12)
        ax3.set_ylabel('Average Latency (μs)', fontsize=12)
        ax3.set_title('Latency Comparison by Size', fontsize=14)
        ax3.set_xticks(x)
        ax3.set_xticklabels(sizes_labels, rotation=45)
        ax3.legend()
        ax3.grid(True, alpha=0.3, axis='y')
    
    ax4 = axes[1, 1]
    if data['shmipc_orig']['latency'] and data['socket']['latency']:
        improvement = []
        for i in range(min(len(data['shmipc_orig']['latency']), len(data['socket']['latency']))):
            if data['socket']['latency'][i] > 0:
                imp = (data['socket']['latency'][i] - data['shmipc_orig']['latency'][i]) / data['socket']['latency'][i] * 100
                improvement.append(imp)
            else:
                improvement.append(0)
        
        ax4.bar(data['socket']['sizes'][:len(improvement)], improvement, alpha=0.8, color='green', label='shmipc_orig')
        
        if data['shmipc_opt']['latency']:
            improvement_opt = []
            for i in range(min(len(data['shmipc_opt']['latency']), len(data['socket']['latency']))):
                if data['socket']['latency'][i] > 0:
                    imp = (data['socket']['latency'][i] - data['shmipc_opt']['latency'][i]) / data['socket']['latency'][i] * 100
                    improvement_opt.append(imp)
                else:
                    improvement_opt.append(0)
            ax4.bar(np.array(data['socket']['sizes'][:len(improvement_opt)]) * 1.1, improvement_opt, alpha=0.8, color='blue', label='shmipc_opt')
        
        ax4.set_xlabel('Message Size (bytes)', fontsize=12)
        ax4.set_ylabel('Latency Improvement (%)', fontsize=12)
        ax4.set_title('Latency Improvement vs Socket', fontsize=14)
        ax4.set_xscale('log', base=2)
        ax4.axhline(y=0, color='red', linestyle='--', linewidth=1)
        ax4.legend()
        ax4.grid(True, alpha=0.3)
    
    plt.tight_layout()
    
    output_file = csv_file.replace('.csv', '.png')
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Plot saved to: {output_file}")
    
    plt.show()

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 plot_latency.py <csv_file>")
        sys.exit(1)
    
    plot_latency(sys.argv[1])
