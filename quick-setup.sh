#!/usr/bin/env bash
set -euo pipefail

info() {
  printf "[Nomad] %s\n" "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_deps() {
  local missing=()
  command_exists mosh || missing+=(mosh)
  command_exists tmux || missing+=(tmux)
  command_exists sshd || missing+=(openssh-server)

  if [ ${#missing[@]} -eq 0 ]; then
    return
  fi

  info "Installing dependencies: ${missing[*]}"
  if command_exists brew; then
    brew install mosh tmux qrencode
    return
  fi
  if command_exists apt-get; then
    sudo apt-get update
    sudo apt-get install -y mosh tmux qrencode openssh-server
    return
  fi
  if command_exists yum; then
    sudo yum install -y mosh tmux qrencode openssh-server
    return
  fi
  if command_exists dnf; then
    sudo dnf install -y mosh tmux qrencode openssh-server
    return
  fi

  info "No supported package manager found. Please install: mosh tmux (and optional qrencode)."
}

enable_ssh() {
  if command_exists systemsetup; then
    if ! systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
      info "Enabling Remote Login (SSH)"
      sudo systemsetup -setremotelogin on
    fi
    return
  fi
  if command_exists systemctl; then
    local svc=""
    if systemctl list-unit-files 2>/dev/null | grep -q "^sshd.service"; then
      svc="sshd"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^ssh.service"; then
      svc="ssh"
    fi
    if [ -n "$svc" ]; then
      if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        info "Enabling SSH service ($svc)"
        sudo systemctl enable "$svc" >/dev/null 2>&1 || true
      fi
      if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Starting SSH service ($svc)"
        sudo systemctl start "$svc" >/dev/null 2>&1 || true
      fi
      return
    fi
  fi
  if command_exists service; then
    if service ssh status >/dev/null 2>&1; then
      return
    fi
    info "Starting SSH service (ssh)"
    sudo service ssh start >/dev/null 2>&1 || true
  fi
}

decode_pubkey() {
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

add_pubkey_if_provided() {
  local pubkey_b64="${NOMAD_PUBKEY_B64:-}"
  if [ -z "$pubkey_b64" ]; then
    return
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

  local pubkey
  pubkey=$(decode_pubkey "$pubkey_b64" || true)
  pubkey=$(echo "$pubkey" | tr -d '\r')
  if [ -z "$pubkey" ]; then
    info "Unable to decode NOMAD_PUBKEY_B64."
    return
  fi

  local ssh_dir="${target_home}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"
  info "Adding SSH public key to ${auth_keys} (user: ${target_user})"

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

  if ! grep -Fq "$pubkey" "$auth_keys"; then
    printf '%s\n' "$pubkey" >> "$auth_keys"
    if [ "$(id -u)" -eq 0 ] && [ "$target_user" != "root" ]; then
      chown "$target_user":"$target_user" "$auth_keys"
    fi
    info "Added SSH public key to ${auth_keys}"
  else
    info "SSH public key already exists in ${auth_keys}"
  fi
}

detect_ip() {
  local ip=""
  if command_exists ipconfig; then
    ip=$(ipconfig getifaddr en0 || true)
    if [ -z "$ip" ]; then
      ip=$(ipconfig getifaddr en1 || true)
    fi
  fi
  if [ -z "$ip" ] && command_exists hostname; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$ip" ] && command_exists ip; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  fi
  echo "$ip"
}

make_token() {
  if command_exists uuidgen; then
    uuidgen
    return
  fi
  if command_exists python3; then
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    return
  fi
  date +%s
}

encode_payload() {
  local host="$1"
  local user="$2"
  local port="$3"
  local token="$4"
  if command_exists python3 || command_exists python; then
    local py="python3"
    command_exists python3 || py="python"
    "$py" - "$host" "$user" "$port" "$token" <<'PY'
import sys
try:
    import urllib.parse as parse
except Exception:
    import urllib as parse

host, user, port, token = sys.argv[1:5]
query = parse.urlencode({"host": host, "port": port, "user": user, "mosh": "true", "setup_token": token})
print("nomad://connect?{}".format(query))
PY
  else
    echo "nomad://connect?host=${host}&port=${port}&user=${user}&mosh=true&setup_token=${token}"
  fi
}

open_file() {
  local path="$1"
  if command_exists open; then
    open "$path"
  elif command_exists xdg-open; then
    xdg-open "$path"
  fi
}

main() {
  install_deps
  enable_ssh
  add_pubkey_if_provided

  local ip
  ip=$(detect_ip)
  if [ -z "$ip" ]; then
    info "Unable to detect a LAN IP. Please run on the server and provide --host manually."
    exit 1
  fi

  local user
  user=$(whoami)

  local token
  token=$(make_token)

  local payload
  payload=$(encode_payload "$ip" "$user" 22 "$token")

  info "Quick setup payload:"
  echo "$payload"

  if command_exists qrencode; then
    info "QR code:"
    qrencode -t ANSIUTF8 "$payload"
  else
    local encoded="$payload"
    if command_exists python3 || command_exists python; then
      local py="python3"
      command_exists python3 || py="python"
      encoded=$("$py" - "$payload" <<'PY'
import sys
try:
    import urllib.parse as parse
except Exception:
    import urllib as parse

payload = sys.argv[1]
print(parse.quote(payload))
PY
      )
    fi
    local qr_url="https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=${encoded}"
    local html="/tmp/nomad-qr.html"
    cat > "$html" <<HTML
<!doctype html>
<html lang="en">
<meta charset="utf-8" />
<title>Nomad QR</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #0b0c0e; color: #e7e9ee; display: flex; align-items: center; justify-content: center; height: 100vh; }
.card { background: #14161b; padding: 24px; border-radius: 16px; text-align: center; box-shadow: 0 20px 60px rgba(0,0,0,0.4); }
code { display: block; margin-top: 12px; font-size: 12px; word-break: break-all; color: #a0a6b1; }
img { width: 260px; height: 260px; }
</style>
<div class="card">
  <h2>Nomad Quick Setup</h2>
  <img src="$qr_url" alt="Nomad QR" />
  <code>$payload</code>
</div>
</html>
HTML
    info "Opening QR code in browser..."
    open_file "$html"
  fi

  info "Done. Scan the QR code from the Nomad app."
}

main "$@"
