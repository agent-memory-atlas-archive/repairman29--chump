#!/bin/bash
# MISSION-110 — Test posse watchdog functionality
# Verifies watchdog service exists, can be installed, and monitors restarts

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WATCHDOG_SERVICE="$REPO_ROOT/scripts/dispatch/posse-watchdog.service"
WATCHDOG_SCRIPT="$REPO_ROOT/scripts/dispatch/posse-watchdog.sh"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-posse-systemd.sh"

# Test 1: Verify watchdog files exist
echo "Test 1: Checking watchdog files exist..."
if [[ ! -f "$WATCHDOG_SERVICE" ]]; then
  echo "ERROR: Watchdog service file not found: $WATCHDOG_SERVICE"
  exit 1
fi

if [[ ! -f "$WATCHDOG_SCRIPT" ]]; then
  echo "ERROR: Watchdog script file not found: $WATCHDOG_SCRIPT"
  exit 1
fi
echo "✓ Watchdog files exist"

# Test 2: Verify watchdog service syntax is valid
echo ""
echo "Test 2: Validating systemd service syntax..."
if ! systemd-analyze verify "$WATCHDOG_SERVICE" 2>&1; then
  echo "ERROR: Watchdog service file has invalid systemd syntax"
  exit 1
fi
echo "✓ Watchdog service syntax is valid"

# Test 3: Verify watchdog script is executable bash
echo ""
echo "Test 3: Checking watchdog script syntax..."
if ! bash -n "$WATCHDOG_SCRIPT"; then
  echo "ERROR: Watchdog script has bash syntax errors"
  exit 1
fi
echo "✓ Watchdog script syntax is valid"

# Test 4: Verify watchdog script has required functions
echo ""
echo "Test 4: Checking watchdog script contains required functionality..."
required_functions=("log_event" "is_service_active" "restart_service" "main")
for func in "${required_functions[@]}"; do
  if ! grep -q "^${func}()" "$WATCHDOG_SCRIPT"; then
    echo "ERROR: Watchdog script missing required function: $func"
    exit 1
  fi
done
echo "✓ Watchdog script has all required functions"

# Test 5: Verify install script includes watchdog
echo ""
echo "Test 5: Checking install script references watchdog..."
if ! grep -q "WATCHDOG_SERVICE" "$INSTALL_SCRIPT"; then
  echo "ERROR: Install script does not reference WATCHDOG_SERVICE"
  exit 1
fi

if ! grep -q "posse-watchdog.service" "$INSTALL_SCRIPT"; then
  echo "ERROR: Install script does not install posse-watchdog.service"
  exit 1
fi

if ! grep -q "/opt/posse-watchdog.sh" "$INSTALL_SCRIPT"; then
  echo "ERROR: Install script does not copy watchdog script to /opt"
  exit 1
fi
echo "✓ Install script properly integrates watchdog"

# Test 6: Verify watchdog service has Restart=always
echo ""
echo "Test 6: Verifying watchdog service configuration..."
if ! grep -q "^Restart=always" "$WATCHDOG_SERVICE"; then
  echo "ERROR: Watchdog service missing Restart=always"
  exit 1
fi

if ! grep -q "^RestartSec=" "$WATCHDOG_SERVICE"; then
  echo "ERROR: Watchdog service missing RestartSec"
  exit 1
fi

if ! grep -q "^WantedBy=multi-user.target" "$WATCHDOG_SERVICE"; then
  echo "ERROR: Watchdog service missing WantedBy target"
  exit 1
fi
echo "✓ Watchdog service configuration is complete"

echo ""
echo "All tests passed! ✓"
exit 0
