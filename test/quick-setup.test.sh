#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

test_bash_setup_forwards_overrides() {
  local output
  output=$(
    MOSHLINE_SETUP_SOURCE_ONLY=1 source "$REPO_ROOT/quick-setup.sh"
    install_deps() { :; }
    enable_ssh() { :; }
    configure_firewall() { :; }
    add_pubkey_if_provided() { :; }
    install_host_helper() { :; }
    wait_for_host_helper() { return 0; }
    moshline-host() { printf 'HOST_HELPER_ARG=<%s>\n' "$@"; }
    main \
      --host 'server.example.test' \
      --user 'test user' \
      --port 2222 \
      --bridge-port 25000
  )

  assert_contains "$output" 'HOST_HELPER_ARG=<setup>'
  assert_contains "$output" 'HOST_HELPER_ARG=<--address>'
  assert_contains "$output" 'HOST_HELPER_ARG=<server.example.test>'
  assert_contains "$output" 'HOST_HELPER_ARG=<--user>'
  assert_contains "$output" 'HOST_HELPER_ARG=<test user>'
  assert_contains "$output" 'HOST_HELPER_ARG=<--ssh-port>'
  assert_contains "$output" 'HOST_HELPER_ARG=<2222>'
  assert_contains "$output" 'HOST_HELPER_ARG=<--bridge-port>'
  assert_contains "$output" 'HOST_HELPER_ARG=<25000>'
}

test_bash_setup_rejects_invalid_ports() {
  local output
  if output=$(bash "$REPO_ROOT/quick-setup.sh" --port 70000 --skip-system-setup 2>&1); then
    fail 'quick-setup.sh accepted an invalid SSH port'
  fi
  assert_contains "$output" 'SSH port must be an integer between 1 and 65535.'
}

test_windows_setup_uses_supported_wsl_path() {
  local setup
  local generator
  setup=$(<"$REPO_ROOT/quick-setup.ps1")
  generator=$(<"$REPO_ROOT/generate-nomad-qr.ps1")

  assert_contains "$setup" 'networkingMode=mirrored'
  assert_contains "$setup" 'Moshline-WSL-Mosh'
  assert_contains "$setup" "@('60000-61000')"
  assert_contains "$setup" 'Ensure-Systemd'
  assert_contains "$setup" 'Ensure-CurrentWSL'
  assert_contains "$setup" 'Test-IsWindowsWorkstation'
  assert_contains "$setup" 'quick-setup.sh'
  assert_contains "$generator" 'quick-setup.ps1'

  [[ "$setup" != *'nomad://connect?'* ]] || fail 'Windows setup still emits the unsupported legacy pairing payload'
  [[ "$generator" != *'nomad://connect?'* ]] || fail 'Windows QR wrapper still emits the unsupported legacy pairing payload'
}

test_linux_setup_upgrades_old_node_runtimes() {
  local setup
  setup=$(<"$REPO_ROOT/quick-setup.sh")

  assert_contains "$setup" 'https://deb.nodesource.com/setup_22.x'
  assert_contains "$setup" 'https://rpm.nodesource.com/setup_22.x'
  assert_contains "$setup" 'if ! node_runtime_supported'
}

test_linux_setup_opens_required_ufw_ports() {
  local output
  output=$(
    exec 2>&1
    MOSHLINE_SETUP_SOURCE_ONLY=1 source "$REPO_ROOT/quick-setup.sh"
    command_exists() { [[ "$1" == 'ufw' ]]; }
    sudo() {
      if [[ "$*" == 'ufw status' ]]; then
        printf 'Status: active\n'
      else
        printf 'SUDO_ARGS=%s\n' "$*" >&2
      fi
    }
    configure_firewall 2222 25000
  )

  assert_contains "$output" 'SUDO_ARGS=ufw allow 2222/tcp'
  assert_contains "$output" 'SUDO_ARGS=ufw allow 25000/tcp'
  assert_contains "$output" 'SUDO_ARGS=ufw allow 60000:61000/udp'
}

test_bash_setup_forwards_overrides
test_bash_setup_rejects_invalid_ports
test_windows_setup_uses_supported_wsl_path
test_linux_setup_upgrades_old_node_runtimes
test_linux_setup_opens_required_ufw_ports

printf 'PASS: quick setup script tests\n'
