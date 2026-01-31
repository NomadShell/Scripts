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
    sudo apt-get install -y mosh tmux qrencode
    return
  fi
  if command_exists yum; then
    sudo yum install -y mosh tmux qrencode
    return
  fi
  if command_exists dnf; then
    sudo dnf install -y mosh tmux qrencode
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
  if command_exists python3; then
    python3 - <<PY
import urllib.parse
host = ${host@Q}
user = ${user@Q}
port = ${port@Q}
token = ${token@Q}
query = urllib.parse.urlencode({"host": host, "port": port, "user": user, "mosh": "true", "setup_token": token})
print(f"nomad://connect?{query}")
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
    if command_exists python3; then
      encoded=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote('''$payload'''))
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
