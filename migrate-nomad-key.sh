#!/usr/bin/env bash
set -euo pipefail

info() {
  printf "[Nomad] %s\n" "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

decode_pubkey_b64() {
  local input="$1"
  if command_exists python3; then
    python3 - "$input" <<'PY'
import base64
import sys

data = sys.argv[1].strip()
try:
    decoded = base64.b64decode(data).decode("utf-8")
    print(decoded)
except Exception:
    print("")
PY
    return
  fi
  if command_exists base64; then
    if base64 --help 2>&1 | grep -q -- "--decode"; then
      printf '%s' "$input" | base64 --decode
    elif base64 --help 2>&1 | grep -q " -d"; then
      printf '%s' "$input" | base64 -d
    else
      printf '%s' "$input" | base64 -D
    fi
  fi
}

usage() {
  cat <<USAGE
Usage:
  migrate-nomad-key.sh --pubkey "<ssh-ed25519 ...>" [--comment-prefix "Nomad-"] [--no-prune]
  migrate-nomad-key.sh --pubkey-b64 "<base64>" [--comment-prefix "Nomad-"] [--no-prune]

Options:
  --pubkey         Full public key line (ssh-ed25519 ...)
  --pubkey-b64     Base64-encoded public key line
  --comment-prefix Prefix used to identify legacy Nomad keys (default: Nomad-)
  --no-prune       Keep legacy ecdsa-sha2-nistp256 lines (default prunes)
USAGE
}

main() {
  local pubkey=""
  local pubkey_b64=""
  local comment_prefix="Nomad-"
  local prune=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --pubkey)
        pubkey="$2"
        shift 2
        ;;
      --pubkey-b64)
        pubkey_b64="$2"
        shift 2
        ;;
      --comment-prefix)
        comment_prefix="$2"
        shift 2
        ;;
      --no-prune)
        prune=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        info "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [ -z "$pubkey" ] && [ -n "$pubkey_b64" ]; then
    pubkey=$(decode_pubkey_b64 "$pubkey_b64" || true)
    pubkey=$(echo "$pubkey" | tr -d '\r')
  fi

  if [ -z "$pubkey" ]; then
    info "Missing --pubkey or --pubkey-b64."
    usage
    exit 1
  fi

  local target_user="${SUDO_USER:-${USER:-}}"
  if [ -z "$target_user" ]; then
    target_user="$(id -un 2>/dev/null || true)"
  fi
  if [ -z "$target_user" ]; then
    target_user="root"
  fi

  local target_home
  target_home=$(eval echo "~${target_user}")
  if [ -z "$target_home" ] || [ "$target_home" = "~${target_user}" ]; then
    target_home="$HOME"
  fi

  local ssh_dir="${target_home}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  info "Updating ${auth_keys} (user: ${target_user})"

  if [ "$(id -u)" -eq 0 ] && [ "$target_user" != "root" ]; then
    install -d -m 700 -o "$target_user" -g "$target_user" "$ssh_dir"
    touch "$auth_keys"
    chown "$target_user":"$target_user" "$auth_keys"
    chmod 600 "$auth_keys"
  else
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_keys"
    chmod 600 "$auth_keys"
  fi

  local backup="${auth_keys}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$auth_keys" "$backup"
  info "Backup saved: ${backup}"

  if [ $prune -eq 1 ]; then
    local tmp
    tmp="$(mktemp)"
    awk -v prefix="$comment_prefix" '
      $1=="ecdsa-sha2-nistp256" && index($0, prefix) { next }
      { print }
    ' "$auth_keys" > "$tmp"
    mv "$tmp" "$auth_keys"
    info "Removed legacy Nomad ECDSA keys (prefix: ${comment_prefix})"
  fi

  if ! grep -Fq "$pubkey" "$auth_keys"; then
    printf '%s\n' "$pubkey" >> "$auth_keys"
    if [ "$(id -u)" -eq 0 ] && [ "$target_user" != "root" ]; then
      chown "$target_user":"$target_user" "$auth_keys"
    fi
    info "Added new public key."
  else
    info "Public key already present."
  fi
}

main "$@"
