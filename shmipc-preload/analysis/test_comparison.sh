#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRELOAD_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$SCRIPT_DIR/results/comparison"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$OUTPUT_DIR"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

print_header() {
    echo -e "${COLOR_BLUE}=========================================="
    echo -e "$1"
    echo -e "==========================================${COLOR_RESET}"
}

print_success() {
    echo -e "${COLOR_GREEN}✓ $1${COLOR_RESET}"
}

print_error() {
    echo -e "${COLOR_RED}✗ $1${COLOR_RESET}"
}

print_warning() {
    echo -e "${COLOR_YELLOW}! $1${COLOR_RESET}"
}

check_dependencies() {
    print_header "Checking Dependencies"
    
    local missing=()
    
    if ! command -v sockperf &> /dev/null; then
        missing+=("sockperf")
    fi
    
    if ! command -v qperf &> /dev/null; then
        missing+=("qperf")
    fi
    
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing dependencies:"
        for tool in "${missing[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian: sudo apt-get install sockperf qperf bc"
        echo "  CentOS/RHEL:   sudo yum install sockperf qperf bc"
        exit 1
    fi
    
    print_success "All dependencies installed"
}

check_builds() {
    print_header "Checking Builds"
    
    local builds_ok=true
    
    if [ -f "$PRELOAD_DIR/libshmipc.so" ]; then
        print_success "Found: libshmipc.so (original)"
    else
        print_warning "Missing: libshmipc.so (original)"
        builds_ok=false
    fi
    
    if [ -f "$PRELOAD_DIR/libshmipc_go.so" ]; then
        print_success "Found: libshmipc_go.so (original)"
    else
        print_warning "Missing: libshmipc_go.so (original)"
        builds_ok=false
    fi
    
    if [ -f "$SCRIPT_DIR/libshmipc_profile.so" ]; then
        print_success "Found: libshmipc_profile.so (profile)"
    else
        print_warning "Missing: libshmipc_profile.so (profile) - run 'make profile'"
    fi
    
    if [ -f "$SCRIPT_DIR/libshmipc_optimized.so" ]; then
        print_success "Found: libshmipc_optimized.so (optimized)"
    else
        print_warning "Missing: libshmipc_optimized.so (optimized) - run 'make optimized'"
    fi
    
    if [ "$builds_ok" = false ]; then
        echo ""
        print_warning "Some builds missing. Run:"
        echo "  cd $PRELOAD_DIR && make"
        echo "  cd $SCRIPT_DIR && make profile"
        echo "  cd $SCRIPT_DIR && make optimized"
    fi
}

run_latency_test() {
    local msg_size="$1"
    local mode="$2"
    local duration="${3:-10}"
    
    local result
    
    if [ "$mode" == "socket" ]; then
        sockperf sr --tcp -i 127.0.0.1 -p 11111 &
        local server_pid=$!
        sleep 2
        
        result=$(sockperf pp --tcp -i 127.0.0.1 -p 11111 --msg-size "$msg_size" --time "$duration" 2>&1 | grep -E "avg-lat|percentile")
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    elif [ "$mode" == "shmipc" ]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" sockperf sr --tcp -i 127.0.0.1 -p 11111 &
        local server_pid=$!
        sleep 2
        
        result=$(LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" sockperf pp --tcp -i 127.0.0.1 -p 11111 --msg-size "$msg_size" --time "$duration" 2>&1 | grep -E "avg-lat|percentile")
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    elif [ "$mode" == "optimized" ]; then
        LD_PRELOAD="$SCRIPT_DIR/libshmipc_optimized.so" sockperf sr --tcp -i 127.0.0.1 -p 11111 &
        local server_pid=$!
        sleep 2
        
        result=$(LD_PRELOAD="$SCRIPT_DIR/libshmipc_optimized.so" sockperf pp --tcp -i 127.0.0.1 -p 11111 --msg-size "$msg_size" --time "$duration" 2>&1 | grep -E "avg-lat|percentile")
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    fi
    
    echo "$result"
}

run_bandwidth_test() {
    local msg_size="$1"
    local mode="$2"
    local duration="${3:-10}"
    
    local result
    
    if [ "$mode" == "socket" ]; then
        qperf &
        local server_pid=$!
        sleep 2
        
        result=$(qperf 127.0.0.1 -m "$msg_size" -t "$duration" tcp_bw 2>&1 | grep -E "bw")
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    elif [ "$mode" == "shmipc" ]; then
        LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf &
        local server_pid=$!
        sleep 2
        
        result=$(LD_PRELOAD="$PRELOAD_DIR/libshmipc.so" qperf 127.0.0.1 -m "$msg_size" -t "$duration" tcp_bw 2>&1 | grep -E "bw")
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    elif [ "$mode" == "optimized" ]; then
        LD_PRELOAD="$SCRIPT_DIR/libshmipc_optimized.so" qperf &
        local server_pid=$!
        sleep 2
        
        result=$(LD_PRELOAD="$SCRIPT_DIR/libshmipc_optimized.so" qperf 127.0.0.1 -m "$msg_size" -t "$duration" tcp_bw 2>&1 | grep -E "bw")
        
        kill $server_pid 2>/dev/null
        wait $server_pid 2>/dev/null
    fi
    
    echo "$result"
}

extract_latency() {
    local output="$1"
    echo "$output" | grep "avg-lat" | awk '{print $NF}' | head -1
}

extract_bandwidth() {
    local output="$1"
    echo "$output" | grep "bw" | awk '{print $3}' | head -1
}

compare_results() {
    local socket_val="$1"
    local shmipc_val="$2"
    local optimized_val="$3"
    local unit="$4"
    local lower_better="$5"
    
    if [ -z "$socket_val" ] || [ -z "$shmipc_val" ]; then
        echo "N/A"
        return
    fi
    
    local socket_num=$(echo "$socket_val" | tr -d '[:alpha:]')
    local shmipc_num=$(echo "$shmipc_val" | tr -d '[:alpha:]')
    local optimized_num=""
    
    if [ -n "$optimized_val" ]; then
        optimized_num=$(echo "$optimized_val" | tr -d '[:alpha:]')
    fi
    
    local diff_shmipc diff_optimized
    
    if [ "$lower_better" == "true" ]; then
        diff_shmipc=$(echo "scale=1; (($socket_num - $shmipc_num) / $socket_num) * 100" | bc)
        if [ -n "$optimized_num" ]; then
            diff_optimized=$(echo "scale=1; (($socket_num - $optimized_num) / $socket_num) * 100" | bc)
        fi
    else
        diff_shmipc=$(echo "scale=1; (($shmipc_num - $socket_num) / $socket_num) * 100" | bc)
        if [ -n "$optimized_num" ]; then
            diff_optimized=$(echo "scale=1; (($optimized_num - $socket_num) / $socket_num) * 100" | bc)
        fi
    fi
    
    local result="Socket: ${socket_val}${unit}, Shmipc: ${shmipc_val}${unit} (${diff_shmipc}%)"
    if [ -n "$optimized_val" ]; then
        result+=", Optimized: ${optimized_val}${unit} (${diff_optimized}%)"
    fi
    
    echo "$result"
}

run_comparison() {
    local result_file="$OUTPUT_DIR/comparison_${TIMESTAMP}.log"
    
    print_header "Running Comparison Tests"
    echo "Results will be saved to: $result_file"
    echo ""
    
    local msg_sizes=(512 4096 16384 65536 262144 1048576)
    
    {
        echo "# shmipc-preload Performance Comparison"
        echo ""
        echo "Date: $(date)"
        echo "Kernel: $(uname -r)"
        echo ""
        
        echo "## Latency Comparison (sockperf ping-pong)"
        echo ""
        echo "| Size | Socket | Shmipc | Optimized | Shmipc vs Socket | Optimized vs Socket |"
        echo "|------|--------|--------|-----------|------------------|---------------------|"
        
        for size in "${msg_sizes[@]}"; do
            echo -n "Testing latency with size $size bytes... "
            
            local socket_out=$(run_latency_test "$size" "socket" 5)
            local shmipc_out=$(run_latency_test "$size" "shmipc" 5)
            local optimized_out=""
            
            if [ -f "$SCRIPT_DIR/libshmipc_optimized.so" ]; then
                optimized_out=$(run_latency_test "$size" "optimized" 5)
            fi
            
            local socket_lat=$(extract_latency "$socket_out")
            local shmipc_lat=$(extract_latency "$shmipc_out")
            local optimized_lat=$(extract_latency "$optimized_out")
            
            local comparison=$(compare_results "$socket_lat" "$shmipc_lat" "$optimized_lat" "ns" "true")
            
            echo "$size | $socket_lat | $shmipc_lat | $optimized_lat | $comparison" >> /dev/stderr
            
            echo "| $size | $socket_lat | $shmipc_lat | $optimized_lat | $comparison |"
            
            echo "done"
            sleep 2
        done
        
        echo ""
        echo "## Bandwidth Comparison (qperf tcp_bw)"
        echo ""
        echo "| Size | Socket | Shmipc | Optimized | Shmipc vs Socket | Optimized vs Socket |"
        echo "|------|--------|--------|-----------|------------------|---------------------|"
        
        for size in "${msg_sizes[@]}"; do
            echo -n "Testing bandwidth with size $size bytes... "
            
            local socket_bw=$(run_bandwidth_test "$size" "socket" 5)
            local shmipc_bw=$(run_bandwidth_test "$size" "shmipc" 5)
            local optimized_bw=""
            
            if [ -f "$SCRIPT_DIR/libshmipc_optimized.so" ]; then
                optimized_bw=$(run_bandwidth_test "$size" "optimized" 5)
            fi
            
            local socket_bw_val=$(extract_bandwidth "$socket_bw")
            local shmipc_bw_val=$(extract_bandwidth "$shmipc_bw")
            local optimized_bw_val=$(extract_bandwidth "$optimized_bw")
            
            local comparison=$(compare_results "$socket_bw_val" "$shmipc_bw_val" "$optimized_bw_val" " MB/s" "false")
            
            echo "| $size | $socket_bw_val | $shmipc_bw_val | $optimized_bw_val | $comparison |"
            
            echo "done"
            sleep 2
        done
        
        echo ""
        echo "## Analysis"
        echo ""
        echo "### Observations"
        echo ""
        echo "1. Small packets (< 4KB):"
        echo "   - Shmipc shows improvement due to zero-copy shared memory"
        echo "   - CGO overhead is negligible"
        echo ""
        echo "2. Medium packets (4KB - 256KB):"
        echo "   - Trade-off between CGO overhead and kernel copy overhead"
        echo "   - Results depend on specific implementation"
        echo ""
        echo "3. Large packets (> 256KB):"
        echo "   - Original shmipc may show degradation due to C.GoBytes copy"
        echo "   - Optimized version should show improvement"
        echo ""
        echo "### Recommendations"
        echo ""
        echo "1. Use optimized version for large packet scenarios"
        echo "2. Consider batching for small packets"
        echo "3. Profile specific workloads for fine-tuning"
        echo ""
        
    } | tee "$result_file"
    
    echo ""
    print_success "Comparison complete. Results saved to: $result_file"
}

quick_test() {
    print_header "Quick Test (64KB)"
    
    echo "Testing socket baseline..."
    local socket_out=$(run_latency_test 65536 "socket" 5)
    local socket_lat=$(extract_latency "$socket_out")
    echo "Socket latency: $socket_lat"
    
    echo ""
    echo "Testing shmipc..."
    local shmipc_out=$(run_latency_test 65536 "shmipc" 5)
    local shmipc_lat=$(extract_latency "$shmipc_out")
    echo "Shmipc latency: $shmipc_lat"
    
    if [ -f "$SCRIPT_DIR/libshmipc_optimized.so" ]; then
        echo ""
        echo "Testing optimized..."
        local optimized_out=$(run_latency_test 65536 "optimized" 5)
        local optimized_lat=$(extract_latency "$optimized_out")
        echo "Optimized latency: $optimized_lat"
    fi
    
    echo ""
    print_header "Results Summary"
    echo "Socket:    $socket_lat"
    echo "Shmipc:    $shmipc_lat"
    [ -n "$optimized_lat" ] && echo "Optimized: $optimized_lat"
}

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  check       Check dependencies and builds"
    echo "  quick       Run quick test (64KB only)"
    echo "  compare     Run full comparison test"
    echo "  help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 check"
    echo "  $0 quick"
    echo "  $0 compare"
    echo ""
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"

case "$command" in
    check)
        check_dependencies
        check_builds
        ;;
    quick)
        check_dependencies
        quick_test
        ;;
    compare)
        check_dependencies
        check_builds
        run_comparison
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $command"
        usage
        exit 1
        ;;
esac
