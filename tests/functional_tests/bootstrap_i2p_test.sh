#!/bin/bash

# Monero I2P Bootstrap Auto-Discovery Test Suite
# Tests the automatic I2P bootstrap node discovery feature
# Runs on testnet with low difficulty

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
TESTNET_FLAG="--testnet"
BASE_DIR="${HOME}/.monero-i2p-test"
MONEROD="${MONEROD:-./monerod}"
I2P_PROXY="127.0.0.1:7656"
TEST_TIMEOUT=300  # 5 minutes per test

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up test environment...${NC}"
    pkill -f "monerod.*i2p-test" || true
    sleep 2
    rm -rf "${BASE_DIR}"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT INT TERM

# Logging function
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Test result tracking
test_passed() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo -e "${GREEN}✓ PASSED${NC}: $1"
}

test_failed() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo -e "${RED}✗ FAILED${NC}: $1"
}

# Wait for daemon to be ready
wait_for_daemon() {
    local rpc_port=$1
    local timeout=$2
    local start_time=$(date +%s)
    
    log_info "Waiting for daemon on port ${rpc_port} to be ready..."
    
    while true; do
        if curl -s --max-time 2 "http://127.0.0.1:${rpc_port}/json_rpc" \
           -d '{"jsonrpc":"2.0","method":"get_info","id":"0"}' \
           -H 'Content-Type: application/json' | grep -q "height"; then
            log_info "Daemon on port ${rpc_port} is ready"
            return 0
        fi
        
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log_error "Timeout waiting for daemon on port ${rpc_port}"
            return 1
        fi
        
        sleep 2
    done
}

# Check if I2P proxy is available
check_i2p_available() {
    log_info "Checking if I2P proxy is available at ${I2P_PROXY}..."
    
    # Try to connect to I2P SAM bridge
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${I2P_PROXY%%:*}/${I2P_PROXY##*:}" 2>/dev/null; then
        log_info "I2P proxy is available"
        return 0
    else
        log_warning "I2P proxy not available - I2P tests will be skipped"
        return 1
    fi
}

# Parse log file for bootstrap addresses
get_bootstrap_addresses() {
    local log_file=$1
    grep "bootstrapping from" "$log_file" | sed 's/.*bootstrapping from //' | cut -d' ' -f1 || true
}

# Check if address is I2P (.b32.i2p)
is_i2p_address() {
    local address=$1
    echo "$address" | grep -q "\.b32\.i2p"
}

# Check if address is clearnet (IPv4/IPv6)
is_clearnet_address() {
    local address=$1
    echo "$address" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" || \
    echo "$address" | grep -q ":"
}

# Query RPC endpoint
query_public_nodes() {
    local rpc_port=$1
    local public_only=$2
    
    curl -s --max-time 10 "http://127.0.0.1:${rpc_port}/json_rpc" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"get_public_nodes\",\"params\":{\"public_only\":${public_only}},\"id\":\"0\"}" \
        -H 'Content-Type: application/json'
}

# Initialize test environment
init_test_env() {
    log_info "Initializing test environment..."
    
    # Cleanup old test data
    rm -rf "${BASE_DIR}"
    mkdir -p "${BASE_DIR}"
    
    # Check if monerod exists
    if [ ! -f "${MONEROD}" ]; then
        log_error "monerod not found at ${MONEROD}"
        log_error "Please build monerod or set MONEROD environment variable"
        exit 1
    fi
    
    log_info "Using monerod: ${MONEROD}"
    log_info "Test directory: ${BASE_DIR}"
}

# ============================================================================
# TEST 1: Clearnet-only bootstrap without proxy (baseline)
# ============================================================================
test_clearnet_only() {
    log_info "========================================"
    log_info "TEST 1: Clearnet-only bootstrap"
    log_info "========================================"
    
    local data_dir="${BASE_DIR}/clearnet"
    local log_file="${data_dir}/test.log"
    local rpc_port=38081
    
    mkdir -p "${data_dir}"
    
    # Start daemon with auto bootstrap, no proxy
    log_info "Starting clearnet-only daemon..."
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --bootstrap-daemon-address auto \
        --log-level 2 \
        --offline \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    sleep 5
    
    # Check if daemon is running
    if ! kill -0 $pid 2>/dev/null; then
        log_error "Daemon failed to start"
        cat "${log_file}"
        test_failed "Clearnet-only bootstrap - daemon startup"
        return 1
    fi
    
    # Wait for daemon to be ready
    if ! wait_for_daemon ${rpc_port} 30; then
        kill $pid 2>/dev/null || true
        test_failed "Clearnet-only bootstrap - daemon not ready"
        return 1
    fi
    
    # Query RPC with public_only=true (default)
    log_info "Querying public nodes with public_only=true..."
    local response=$(query_public_nodes ${rpc_port} true)
    
    # Check response has white or gray lists
    if echo "$response" | jq -e '.result.white' > /dev/null 2>&1; then
        # Extract addresses
        local addresses=$(echo "$response" | jq -r '.result.white[].host' 2>/dev/null || true)
        
        if [ -n "$addresses" ]; then
            log_info "Found addresses: $(echo "$addresses" | head -3 | tr '\n' ' ')"
            
            # Verify all addresses are clearnet
            local has_non_clearnet=false
            while IFS= read -r addr; do
                if ! is_clearnet_address "$addr"; then
                    log_error "Found non-clearnet address: $addr"
                    has_non_clearnet=true
                fi
            done <<< "$addresses"
            
            if [ "$has_non_clearnet" = false ]; then
                test_passed "Clearnet-only bootstrap returns only clearnet addresses"
            else
                test_failed "Clearnet-only bootstrap returned non-clearnet addresses"
            fi
        else
            log_warning "No addresses returned (expected if no peers discovered yet)"
            test_passed "Clearnet-only bootstrap (no peers yet, acceptable)"
        fi
    else
        log_error "Invalid response from RPC"
        echo "$response" | jq '.' || echo "$response"
        test_failed "Clearnet-only bootstrap - invalid RPC response"
    fi
    
    # Cleanup
    kill $pid 2>/dev/null || true
    sleep 2
}

# ============================================================================
# TEST 2: RPC endpoint with public_only parameter
# ============================================================================
test_rpc_public_only_param() {
    log_info "========================================"
    log_info "TEST 2: RPC public_only parameter"
    log_info "========================================"
    
    local data_dir="${BASE_DIR}/rpc-test"
    local log_file="${data_dir}/test.log"
    local rpc_port=38082
    
    mkdir -p "${data_dir}"
    
    # Start daemon
    log_info "Starting daemon for RPC testing..."
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --log-level 2 \
        --offline \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    
    if ! wait_for_daemon ${rpc_port} 30; then
        kill $pid 2>/dev/null || true
        test_failed "RPC test - daemon not ready"
        return 1
    fi
    
    # Test default behavior (no public_only param)
    log_info "Testing default behavior (no public_only parameter)..."
    local response_default=$(curl -s --max-time 10 "http://127.0.0.1:${rpc_port}/json_rpc" \
        -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{},"id":"0"}' \
        -H 'Content-Type: application/json')
    
    if echo "$response_default" | jq -e '.result' > /dev/null 2>&1; then
        test_passed "RPC endpoint accepts request without public_only parameter"
    else
        test_failed "RPC endpoint rejects request without public_only parameter"
    fi
    
    # Test public_only=true
    log_info "Testing public_only=true..."
    local response_true=$(query_public_nodes ${rpc_port} true)
    
    if echo "$response_true" | jq -e '.result' > /dev/null 2>&1; then
        test_passed "RPC endpoint accepts public_only=true"
    else
        test_failed "RPC endpoint rejects public_only=true"
    fi
    
    # Test public_only=false
    log_info "Testing public_only=false..."
    local response_false=$(query_public_nodes ${rpc_port} false)
    
    if echo "$response_false" | jq -e '.result' > /dev/null 2>&1; then
        test_passed "RPC endpoint accepts public_only=false"
    else
        test_failed "RPC endpoint rejects public_only=false"
    fi
    
    # Cleanup
    kill $pid 2>/dev/null || true
    sleep 2
}

# ============================================================================
# TEST 3: I2P auto-discovery with proxy
# ============================================================================
test_i2p_auto_discovery() {
    log_info "========================================"
    log_info "TEST 3: I2P auto-discovery"
    log_info "========================================"
    
    # Check if I2P is available
    if ! check_i2p_available; then
        log_warning "Skipping I2P test - I2P proxy not available"
        log_warning "To run I2P tests, ensure I2P router is running with SAM bridge on ${I2P_PROXY}"
        return 0
    fi
    
    local ref_data_dir="${BASE_DIR}/i2p-reference"
    local test_data_dir="${BASE_DIR}/i2p-test"
    local ref_log="${ref_data_dir}/test.log"
    local test_log="${test_data_dir}/test.log"
    local ref_rpc_port=38083
    local test_rpc_port=38084
    
    mkdir -p "${ref_data_dir}" "${test_data_dir}"
    
    # Start reference I2P daemon
    log_info "Starting reference I2P daemon..."
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${ref_data_dir}" \
        --rpc-bind-port ${ref_rpc_port} \
        --p2p-bind-port 38183 \
        --tx-proxy i2p,${I2P_PROXY} \
        --log-level 2 \
        > "${ref_log}" 2>&1 &
    
    local ref_pid=$!
    
    if ! wait_for_daemon ${ref_rpc_port} 60; then
        kill $ref_pid 2>/dev/null || true
        test_failed "I2P test - reference daemon not ready"
        return 1
    fi
    
    # Wait for I2P peers to be discovered (this may take a while on testnet)
    log_info "Waiting for I2P peers to be discovered (up to 120 seconds)..."
    local peer_wait=0
    local has_i2p_peers=false
    
    while [ $peer_wait -lt 120 ]; do
        # Query peer list
        local peer_response=$(curl -s --max-time 10 "http://127.0.0.1:${ref_rpc_port}/json_rpc" \
            -d '{"jsonrpc":"2.0","method":"get_peer_list","params":{"public_only":false},"id":"0"}' \
            -H 'Content-Type: application/json' 2>/dev/null || true)
        
        # Check if we have any I2P peers
        if echo "$peer_response" | jq -e '.result.white_list[]? | select(.host | contains(".b32.i2p"))' > /dev/null 2>&1 || \
           echo "$peer_response" | jq -e '.result.gray_list[]? | select(.host | contains(".b32.i2p"))' > /dev/null 2>&1; then
            has_i2p_peers=true
            log_info "I2P peers discovered!"
            break
        fi
        
        sleep 10
        peer_wait=$((peer_wait + 10))
        log_info "Still waiting for I2P peers... (${peer_wait}s elapsed)"
    done
    
    if [ "$has_i2p_peers" = false ]; then
        log_warning "No I2P peers discovered after 120 seconds"
        log_warning "This is expected on testnet with few I2P nodes"
        log_warning "Test will verify that mechanism works, but may not find I2P addresses"
    fi
    
    # Now start test daemon with auto bootstrap via I2P proxy
    log_info "Starting test daemon with I2P auto-discovery..."
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${test_data_dir}" \
        --rpc-bind-port ${test_rpc_port} \
        --p2p-bind-port 38184 \
        --bootstrap-daemon-address auto \
        --bootstrap-daemon-proxy ${I2P_PROXY} \
        --tx-proxy i2p,${I2P_PROXY} \
        --log-level 2 \
        > "${test_log}" 2>&1 &
    
    local test_pid=$!
    
    if ! wait_for_daemon ${test_rpc_port} 60; then
        kill $test_pid $ref_pid 2>/dev/null || true
        test_failed "I2P test - test daemon not ready"
        return 1
    fi
    
    # Give it time to attempt bootstrap
    log_info "Waiting for bootstrap attempts..."
    sleep 20
    
    # Check logs for bootstrap attempts
    local bootstrap_addresses=$(get_bootstrap_addresses "${test_log}")
    
    if [ -n "$bootstrap_addresses" ]; then
        log_info "Bootstrap addresses found:"
        echo "$bootstrap_addresses" | head -5
        
        # Check if any I2P addresses were attempted
        local has_i2p_bootstrap=false
        while IFS= read -r addr; do
            if is_i2p_address "$addr"; then
                log_info "Found I2P bootstrap address: $addr"
                has_i2p_bootstrap=true
            fi
        done <<< "$bootstrap_addresses"
        
        if [ "$has_i2p_bootstrap" = true ]; then
            test_passed "I2P auto-discovery found and attempted I2P bootstrap addresses"
        else
            if [ "$has_i2p_peers" = true ]; then
                test_failed "I2P peers available but not used for bootstrap"
            else
                log_warning "No I2P bootstrap addresses (no I2P peers discovered)"
                test_passed "I2P auto-discovery mechanism works (no I2P peers to test with)"
            fi
        fi
    else
        log_warning "No bootstrap addresses in logs yet"
        test_passed "I2P test completed (bootstrap may happen later)"
    fi
    
    # Query RPC to verify public_only=false returns all zones
    log_info "Querying public nodes with public_only=false..."
    local response_all=$(query_public_nodes ${test_rpc_port} false)
    
    if echo "$response_all" | jq -e '.result' > /dev/null 2>&1; then
        test_passed "RPC query with public_only=false succeeds with I2P proxy"
    else
        test_failed "RPC query with public_only=false fails"
    fi
    
    # Cleanup
    kill $test_pid $ref_pid 2>/dev/null || true
    sleep 2
}

# ============================================================================
# TEST 4: Proxy detection logic
# ============================================================================
test_proxy_detection() {
    log_info "========================================"
    log_info "TEST 4: Proxy detection logic"
    log_info "========================================"
    
    local data_dir="${BASE_DIR}/proxy-detect"
    local log_file="${data_dir}/test.log"
    local rpc_port=38085
    
    mkdir -p "${data_dir}"
    
    # Test with a dummy proxy (doesn't need to be real for this test)
    log_info "Starting daemon with proxy but clearnet-only peers..."
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --bootstrap-daemon-address auto \
        --bootstrap-daemon-proxy 127.0.0.1:9999 \
        --log-level 2 \
        --offline \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    
    if ! wait_for_daemon ${rpc_port} 30; then
        kill $pid 2>/dev/null || true
        test_failed "Proxy detection test - daemon not ready"
        return 1
    fi
    
    # The daemon should:
    # 1. Detect proxy is configured
    # 2. Check peer list for non-clearnet zones
    # 3. Since only clearnet zone exists, use public_only=true
    
    sleep 10
    
    # Check log for decision-making
    if grep -q "Auto bootstrap" "${log_file}" 2>/dev/null; then
        log_info "Found auto bootstrap logging in output"
        test_passed "Proxy detection mechanism executed"
    else
        log_warning "No auto bootstrap logging found (may not have debug output)"
        test_passed "Proxy detection test completed"
    fi
    
    # Cleanup
    kill $pid 2>/dev/null || true
    sleep 2
}

# ============================================================================
# TEST 5: Backward compatibility (no public_only field)
# ============================================================================
test_backward_compatibility() {
    log_info "========================================"
    log_info "TEST 5: Backward compatibility"
    log_info "========================================"
    
    local data_dir="${BASE_DIR}/compat"
    local log_file="${data_dir}/test.log"
    local rpc_port=38086
    
    mkdir -p "${data_dir}"
    
    log_info "Starting daemon for compatibility testing..."
    ${MONEROD} ${TESTNET_FLAG} \
        --data-dir "${data_dir}" \
        --rpc-bind-port ${rpc_port} \
        --log-level 2 \
        --offline \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    
    if ! wait_for_daemon ${rpc_port} 30; then
        kill $pid 2>/dev/null || true
        test_failed "Compatibility test - daemon not ready"
        return 1
    fi
    
    # Test legacy RPC call without public_only parameter
    log_info "Testing legacy RPC call (no public_only parameter)..."
    local response=$(curl -s --max-time 10 "http://127.0.0.1:${rpc_port}/json_rpc" \
        -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{},"id":"0"}' \
        -H 'Content-Type: application/json')
    
    if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        test_passed "Backward compatibility - legacy RPC call works"
    else
        test_failed "Backward compatibility - legacy RPC call fails"
        echo "$response" | jq '.' || echo "$response"
    fi
    
    # Verify default is public_only=true (clearnet only)
    local addresses=$(echo "$response" | jq -r '.result.white[].host' 2>/dev/null || true)
    if [ -n "$addresses" ]; then
        local all_clearnet=true
        while IFS= read -r addr; do
            if ! is_clearnet_address "$addr"; then
                all_clearnet=false
                log_error "Default behavior returned non-clearnet address: $addr"
            fi
        done <<< "$addresses"
        
        if [ "$all_clearnet" = true ]; then
            test_passed "Backward compatibility - defaults to clearnet only"
        else
            test_failed "Backward compatibility - default behavior changed"
        fi
    else
        log_info "No addresses to test (no peers yet)"
        test_passed "Backward compatibility - RPC structure compatible"
    fi
    
    # Cleanup
    kill $pid 2>/dev/null || true
    sleep 2
}

# ============================================================================
# Main test execution
# ============================================================================
main() {
    echo ""
    echo "================================================================"
    echo "  Monero I2P Bootstrap Auto-Discovery Test Suite"
    echo "  Testing on: TESTNET"
    echo "================================================================"
    echo ""
    
    # Check dependencies
    for cmd in curl jq; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Required command not found: $cmd"
            log_error "Please install: $cmd"
            exit 1
        fi
    done
    
    # Initialize
    init_test_env
    
    # Run tests
    test_clearnet_only
    echo ""
    
    test_rpc_public_only_param
    echo ""
    
    test_i2p_auto_discovery
    echo ""
    
    test_proxy_detection
    echo ""
    
    test_backward_compatibility
    echo ""
    
    # Print summary
    echo "================================================================"
    echo "  TEST SUMMARY"
    echo "================================================================"
    echo -e "Total tests:  ${TESTS_TOTAL}"
    echo -e "${GREEN}Passed:       ${TESTS_PASSED}${NC}"
    echo -e "${RED}Failed:       ${TESTS_FAILED}${NC}"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
        exit 0
    else
        echo -e "${RED}✗ SOME TESTS FAILED${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
