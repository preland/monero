#!/bin/bash

# Manual Interactive Test Script for I2P Bootstrap Auto-Discovery
# This script sets up an interactive test environment for manual verification

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTNET_FLAG="--testnet"
BASE_DIR="${HOME}/.monero-i2p-manual-test"
MONEROD="${MONEROD:-./monerod}"
I2P_PROXY="127.0.0.1:7656"

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

log_cmd() {
    echo -e "${BLUE}[COMMAND]${NC} $1"
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    echo ""
    log "Stopping all test daemons..."
    pkill -f "monerod.*i2p-manual-test" || true
    sleep 2
}

trap cleanup EXIT INT TERM

show_menu() {
    echo ""
    echo "================================================================"
    echo "  Monero I2P Bootstrap - Manual Test Environment"
    echo "================================================================"
    echo ""
    echo "Choose a test scenario:"
    echo ""
    echo "  1) Test clearnet-only bootstrap (no proxy)"
    echo "  2) Test I2P auto-discovery (requires I2P router)"
    echo "  3) Test RPC endpoint directly"
    echo "  4) Monitor logs of running daemons"
    echo "  5) Start I2P reference daemon (for testing)"
    echo "  6) Cleanup and exit"
    echo ""
    read -p "Enter choice [1-6]: " choice
    echo ""
}

wait_for_daemon() {
    local port=$1
    local name=$2
    local timeout=60
    
    log "Waiting for $name to start on port $port..."
    
    local start=$(date +%s)
    while true; do
        if curl -s --max-time 2 "http://127.0.0.1:${port}/json_rpc" \
           -d '{"jsonrpc":"2.0","method":"get_info","id":"0"}' 2>/dev/null | grep -q "height"; then
            log "$name is ready!"
            return 0
        fi
        
        local now=$(date +%s)
        if [ $((now - start)) -gt $timeout ]; then
            log_error "Timeout waiting for $name"
            return 1
        fi
        sleep 2
    done
}

test_clearnet() {
    log "Starting clearnet-only bootstrap test..."
    
    local data_dir="${BASE_DIR}/clearnet"
    local log_file="${data_dir}/monerod.log"
    local rpc_port=28081
    
    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"
    
    log_cmd "${MONEROD} ${TESTNET_FLAG} --data-dir ${data_dir} --rpc-bind-port ${rpc_port} --bootstrap-daemon-address auto"
    
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --bootstrap-daemon-address auto \
        --log-level 2 \
        --offline \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    echo "Daemon PID: $pid"
    
    if ! wait_for_daemon ${rpc_port} "Clearnet daemon"; then
        return 1
    fi
    
    echo ""
    log_info "Daemon is running. Commands to try:"
    echo ""
    echo "  # Get daemon info"
    echo "  curl -s http://127.0.0.1:${rpc_port}/json_rpc -d '{\"jsonrpc\":\"2.0\",\"method\":\"get_info\",\"id\":\"0\"}' | jq ."
    echo ""
    echo "  # Get public nodes (should be clearnet only)"
    echo "  curl -s http://127.0.0.1:${rpc_port}/json_rpc -d '{\"jsonrpc\":\"2.0\",\"method\":\"get_public_nodes\",\"params\":{\"public_only\":true},\"id\":\"0\"}' | jq '.result.white[] | .host'"
    echo ""
    echo "  # View log file"
    echo "  tail -f ${log_file}"
    echo ""
    
    read -p "Press Enter to stop daemon and continue..."
    kill $pid 2>/dev/null || true
}

test_i2p() {
    # Check I2P availability
    if ! timeout 3 bash -c "cat < /dev/null > /dev/tcp/${I2P_PROXY%%:*}/${I2P_PROXY##*:}" 2>/dev/null; then
        log_error "I2P proxy not available at ${I2P_PROXY}"
        log_error "Please start I2P router with SAM bridge enabled"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log "I2P proxy is available at ${I2P_PROXY}"
    log "Starting I2P auto-discovery test..."
    
    local data_dir="${BASE_DIR}/i2p-test"
    local log_file="${data_dir}/monerod.log"
    local rpc_port=28082
    
    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"
    
    log_cmd "${MONEROD} ${TESTNET_FLAG} --data-dir ${data_dir} --bootstrap-daemon-address auto --bootstrap-daemon-proxy ${I2P_PROXY} --tx-proxy i2p,${I2P_PROXY}"
    
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --p2p-bind-port 28182 \
        --bootstrap-daemon-address auto \
        --bootstrap-daemon-proxy ${I2P_PROXY} \
        --tx-proxy i2p,${I2P_PROXY} \
        --log-level 2 \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    echo "Daemon PID: $pid"
    
    if ! wait_for_daemon ${rpc_port} "I2P daemon"; then
        return 1
    fi
    
    echo ""
    log_info "Daemon is running. Commands to try:"
    echo ""
    echo "  # Get public nodes with public_only=false (should include I2P if available)"
    echo "  curl -s http://127.0.0.1:${rpc_port}/json_rpc -d '{\"jsonrpc\":\"2.0\",\"method\":\"get_public_nodes\",\"params\":{\"public_only\":false},\"id\":\"0\"}' | jq '.result.white[] | .host'"
    echo ""
    echo "  # Get peer list (check for .b32.i2p addresses)"
    echo "  curl -s http://127.0.0.1:${rpc_port}/json_rpc -d '{\"jsonrpc\":\"2.0\",\"method\":\"get_peer_list\",\"params\":{\"public_only\":false},\"id\":\"0\"}' | jq '.result.white_list[] | select(.host | contains(\"b32.i2p\")) | .host'"
    echo ""
    echo "  # Monitor log for bootstrap attempts"
    echo "  tail -f ${log_file} | grep --line-buffered 'bootstrap'"
    echo ""
    echo "  # Check for I2P addresses in log"
    echo "  grep 'b32.i2p' ${log_file}"
    echo ""
    
    read -p "Press Enter to stop daemon and continue..."
    kill $pid 2>/dev/null || true
}

test_rpc_direct() {
    log "Starting daemon for direct RPC testing..."
    
    local data_dir="${BASE_DIR}/rpc-test"
    local log_file="${data_dir}/monerod.log"
    local rpc_port=28083
    
    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"
    
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --log-level 2 \
        --offline \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    
    if ! wait_for_daemon ${rpc_port} "RPC test daemon"; then
        return 1
    fi
    
    echo ""
    log_info "Testing RPC endpoint..."
    echo ""
    
    # Test 1: Default (no public_only)
    log "Test 1: Default behavior (backward compatibility)"
    curl -s "http://127.0.0.1:${rpc_port}/json_rpc" \
        -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{},"id":"0"}' | jq .
    echo ""
    
    # Test 2: public_only=true
    log "Test 2: public_only=true (clearnet only)"
    curl -s "http://127.0.0.1:${rpc_port}/json_rpc" \
        -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{"public_only":true},"id":"0"}' | jq .
    echo ""
    
    # Test 3: public_only=false
    log "Test 3: public_only=false (all zones)"
    curl -s "http://127.0.0.1:${rpc_port}/json_rpc" \
        -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{"public_only":false},"id":"0"}' | jq .
    echo ""
    
    read -p "Press Enter to stop daemon and continue..."
    kill $pid 2>/dev/null || true
}

monitor_logs() {
    log "Available log files:"
    echo ""
    
    local found_logs=false
    for logfile in "${BASE_DIR}"/*/monerod.log; do
        if [ -f "$logfile" ]; then
            echo "  - $logfile"
            found_logs=true
        fi
    done
    
    if [ "$found_logs" = false ]; then
        log_info "No log files found. Run a test first."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    read -p "Enter log file path to monitor (or press Enter to skip): " logpath
    
    if [ -n "$logpath" ] && [ -f "$logpath" ]; then
        log "Monitoring $logpath (Ctrl+C to stop)..."
        tail -f "$logpath"
    fi
}

start_i2p_reference() {
    # Check I2P availability
    if ! timeout 3 bash -c "cat < /dev/null > /dev/tcp/${I2P_PROXY%%:*}/${I2P_PROXY##*:}" 2>/dev/null; then
        log_error "I2P proxy not available at ${I2P_PROXY}"
        log_error "Please start I2P router with SAM bridge enabled"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log "Starting I2P reference daemon (for other daemons to discover)..."
    
    local data_dir="${BASE_DIR}/i2p-reference"
    local log_file="${data_dir}/monerod.log"
    local rpc_port=28084
    
    rm -rf "${data_dir}"
    mkdir -p "${data_dir}"
    
    log_cmd "${MONEROD} ${TESTNET_FLAG} --data-dir ${data_dir} --tx-proxy i2p,${I2P_PROXY}"
    
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --p2p-bind-port 28184 \
        --tx-proxy i2p,${I2P_PROXY} \
        --log-level 2 \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    echo "Daemon PID: $pid"
    
    if ! wait_for_daemon ${rpc_port} "I2P reference daemon"; then
        return 1
    fi
    
    echo ""
    log_info "Reference daemon is running and will discover I2P peers over time"
    log_info "Log file: ${log_file}"
    echo ""
    echo "Monitor I2P peer discovery:"
    echo "  watch -n 5 'curl -s http://127.0.0.1:${rpc_port}/json_rpc -d \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"method\\\":\\\"get_peer_list\\\",\\\"id\\\":\\\"0\\\"}\" | jq \".result.white_list[] | select(.host | contains(\\\"b32.i2p\\\")) | .host\"'"
    echo ""
    
    read -p "Press Enter to stop daemon and continue..."
    kill $pid 2>/dev/null || true
}

# Main menu loop
main() {
    # Check dependencies
    for cmd in curl jq; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Required command not found: $cmd"
            log_error "Please install: $cmd"
            exit 1
        fi
    done
    
    if [ ! -f "${MONEROD}" ]; then
        log_error "monerod not found at ${MONEROD}"
        log_error "Please build monerod or set MONEROD environment variable"
        exit 1
    fi
    
    mkdir -p "${BASE_DIR}"
    
    while true; do
        show_menu
        
        case $choice in
            1)
                test_clearnet
                ;;
            2)
                test_i2p
                ;;
            3)
                test_rpc_direct
                ;;
            4)
                monitor_logs
                ;;
            5)
                start_i2p_reference
                ;;
            6)
                log "Exiting..."
                exit 0
                ;;
            *)
                log_error "Invalid choice"
                ;;
        esac
    done
}

main "$@"
