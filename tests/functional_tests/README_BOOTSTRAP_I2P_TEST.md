# I2P Bootstrap Auto-Discovery Test Suite

This directory contains test scripts for the I2P bootstrap auto-discovery feature.

## Overview

These tests verify that the Monero daemon can automatically discover and connect to I2P bootstrap nodes when configured with a SOCKS proxy, while maintaining backward compatibility with clearnet-only operation.

## Test Scripts

### 1. `bootstrap_i2p_test.sh` - Automated Test Suite

Comprehensive automated tests covering all aspects of the I2P auto-discovery feature.

**Features:**
- Runs on testnet with low difficulty
- Automatic test execution and result reporting
- Tests clearnet-only, I2P, RPC endpoints, and backward compatibility
- Color-coded output with pass/fail indicators

**Usage:**
```bash
cd /path/to/monero
make release  # or make debug

# Run tests
./tests/functional_tests/bootstrap_i2p_test.sh

# With custom monerod path
MONEROD=/path/to/monerod ./tests/functional_tests/bootstrap_i2p_test.sh
```

**Tests Included:**
1. **Clearnet-only bootstrap** - Verifies default behavior without proxy
2. **RPC public_only parameter** - Tests the new RPC parameter
3. **I2P auto-discovery** - Tests I2P node discovery (requires I2P router)
4. **Proxy detection logic** - Verifies zone detection mechanism
5. **Backward compatibility** - Ensures legacy RPC calls still work

### 2. `bootstrap_i2p_manual_test.sh` - Interactive Manual Testing

Interactive script for manual testing and experimentation.

**Features:**
- Menu-driven interface
- Start individual test scenarios
- Monitor daemon logs in real-time
- Direct RPC endpoint testing
- Reference I2P daemon for testing

**Usage:**
```bash
./tests/functional_tests/bootstrap_i2p_manual_test.sh
```

**Menu Options:**
1. Test clearnet-only bootstrap
2. Test I2P auto-discovery
3. Test RPC endpoint directly
4. Monitor logs of running daemons
5. Start I2P reference daemon
6. Cleanup and exit

## Prerequisites

### Required Tools

```bash
# Ubuntu/Debian
sudo apt-get install curl jq

# macOS
brew install curl jq

# Fedora/RHEL
sudo dnf install curl jq
```

### For I2P Tests (Optional)

I2P router with SAM bridge enabled on `127.0.0.1:7656`

**Installing I2P:**

**Linux:**
```bash
# Download and install I2P
wget https://geti2p.net/en/download/0.9.56/clearnet/https/download.i2p2.de/releases/0.9.56/i2p-install_0.9.56.jar
java -jar i2p-install_0.9.56.jar -console

# Start I2P
i2prouter start

# Enable SAM bridge:
# 1. Open http://127.0.0.1:7657 in browser
# 2. Navigate to Configure > Clients
# 3. Enable "SAM application bridge"
# 4. Set port to 7656
# 5. Save and restart I2P
```

**macOS:**
```bash
brew install i2p
i2p start

# Configure SAM bridge via web interface at http://127.0.0.1:7657
```

### Building Monero

```bash
cd /path/to/monero
make release-test  # Includes test builds

# Or for debug with verbose output
make debug
```

## Running Tests

### Quick Test (Automated)

```bash
# From monero root directory
./tests/functional_tests/bootstrap_i2p_test.sh
```

**Expected Output:**
```
================================================================
  Monero I2P Bootstrap Auto-Discovery Test Suite
  Testing on: TESTNET
================================================================

[INFO] Initializing test environment...
[INFO] Using monerod: ./build/release/bin/monerod

========================================
TEST 1: Clearnet-only bootstrap
========================================
✓ PASSED: Clearnet-only bootstrap returns only clearnet addresses

========================================
TEST 2: RPC public_only parameter
========================================
✓ PASSED: RPC endpoint accepts request without public_only parameter
✓ PASSED: RPC endpoint accepts public_only=true
✓ PASSED: RPC endpoint accepts public_only=false

...

================================================================
  TEST SUMMARY
================================================================
Total tests:  10
Passed:       10
Failed:       0

✓ ALL TESTS PASSED
```

### Manual Testing

```bash
./tests/functional_tests/bootstrap_i2p_manual_test.sh
```

Follow the interactive menu to test specific scenarios.

## Test Scenarios

### Scenario 1: Clearnet Bootstrap (Control)

**Setup:**
```bash
monerod --testnet --bootstrap-daemon-address auto
```

**Expected Behavior:**
- Daemon queries peer list with `public_only=true`
- Only clearnet (IPv4/IPv6) addresses returned
- Bootstrap succeeds via clearnet

**Verification:**
```bash
# Check bootstrap addresses in log
grep "bootstrapping from" ~/.monero-i2p-test/clearnet/test.log

# Should show only IPv4/IPv6, no .b32.i2p
```

### Scenario 2: I2P Auto-Discovery

**Setup:**
```bash
monerod --testnet \
        --bootstrap-daemon-address auto \
        --bootstrap-daemon-proxy 127.0.0.1:7656 \
        --tx-proxy i2p,127.0.0.1:7656
```

**Expected Behavior:**
- Daemon detects proxy configuration
- Checks peer list for non-clearnet zones
- If I2P peers exist, uses `public_only=false`
- Discovers and attempts I2P bootstrap addresses
- Connects through SOCKS proxy

**Verification:**
```bash
# Check for I2P bootstrap addresses
grep "bootstrapping from.*b32.i2p" ~/.monero-i2p-test/i2p-test/test.log

# Query RPC for all zones
curl -s http://127.0.0.1:28082/json_rpc \
  -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{"public_only":false},"id":"0"}' \
  | jq '.result.white[] | select(.host | contains("b32.i2p")) | .host'
```

### Scenario 3: RPC Endpoint Testing

**Setup:**
```bash
monerod --testnet --rpc-bind-port 28083
```

**Tests:**

1. **Default (backward compatible):**
```bash
curl -s http://127.0.0.1:28083/json_rpc \
  -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{},"id":"0"}' \
  | jq '.result'
```

2. **Explicit public_only=true:**
```bash
curl -s http://127.0.0.1:28083/json_rpc \
  -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{"public_only":true},"id":"0"}' \
  | jq '.result.white[] | .host'
```

3. **Explicit public_only=false:**
```bash
curl -s http://127.0.0.1:28083/json_rpc \
  -d '{"jsonrpc":"2.0","method":"get_public_nodes","params":{"public_only":false},"id":"0"}' \
  | jq '.result.white[] | .host'
```

## Troubleshooting

### Test Failures

**"monerod not found"**
```bash
# Build monerod first
cd /path/to/monero
make release

# Or specify path
MONEROD=/path/to/build/release/bin/monerod ./tests/functional_tests/bootstrap_i2p_test.sh
```

**"I2P proxy not available"**
- I2P tests will be skipped if I2P router is not running
- This is expected and not a failure
- To run I2P tests, install and start I2P router with SAM bridge

**"Daemon failed to start"**
```bash
# Check logs
cat ~/.monero-i2p-test/*/test.log

# Common issues:
# - Port already in use: kill existing monerod processes
# - Permissions: check directory permissions
```

### I2P-Specific Issues

**No I2P peers discovered**
- This is normal on testnet with few I2P nodes
- I2P peer discovery can take 5-10 minutes
- The test verifies the mechanism works even without peers

**I2P connection fails**
```bash
# Verify I2P is running
curl -s http://127.0.0.1:7657/home

# Check SAM bridge
nc -zv 127.0.0.1 7656

# Check I2P router logs
tail -f ~/.i2p/logs/log-*.txt
```

## Expected Test Results

### With I2P Router Running

All tests should pass, including I2P auto-discovery with actual I2P addresses.

### Without I2P Router

Tests 1, 2, 4, and 5 should pass.
Test 3 (I2P auto-discovery) will report "SKIPPED" or pass with warning.

## Cleaning Up

Tests automatically clean up on exit. To manually clean:

```bash
# Stop all test daemons
pkill -f "monerod.*i2p-test"

# Remove test data
rm -rf ~/.monero-i2p-test
```

## Contributing

When adding new tests:

1. Follow existing test structure
2. Add clear logging with `log_info`, `log_error`
3. Use `test_passed` and `test_failed` for tracking
4. Include cleanup in test functions
5. Update this README with new test documentation

## Support

For issues with these tests:
1. Check logs in `~/.monero-i2p-test/`
2. Run manual test script for interactive debugging
3. Report issues with full log output

## References

- [Monero I2P Documentation](../../docs/ANONYMITY_NETWORKS.md)
- [I2P Router Documentation](https://geti2p.net/en/docs)
- [Monero RPC Documentation](https://www.getmonero.org/resources/developer-guides/daemon-rpc.html)
