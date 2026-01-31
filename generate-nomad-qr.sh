#!/usr/bin/env bash
set -euo pipefail

info() {
  printf "[Nomad] %s\n" "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
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
    python3 - "$host" "$user" "$port" "$token" <<'PY'
import urllib.parse
import sys
host, user, port, token = sys.argv[1:5]
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

usage() {
  cat <<USAGE
Usage:
  generate-nomad-qr.sh --auto
  generate-nomad-qr.sh --host <ip> [--user <name>] [--port <port>]
USAGE
}

main() {
  local host=""
  local user=""
  local port="22"
  local auto=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --host)
        host="$2"
        shift 2
        ;;
      --user)
        user="$2"
        shift 2
        ;;
      --port)
        port="$2"
        shift 2
        ;;
      --auto)
        auto=1
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

  if [ -z "$host" ] && [ $auto -eq 1 ]; then
    host=$(detect_ip)
  fi

  if [ -z "$host" ]; then
    info "Missing host."
    usage
    exit 1
  fi

  if [ -z "$user" ]; then
    user=$(whoami)
  fi

  local token
  token=$(make_token)

  local payload
  payload=$(encode_payload "$host" "$user" "$port" "$token")

  info "QR payload:"
  echo "$payload"

  if command_exists qrencode; then
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
  <h2>Nomad QR</h2>
  <img src="$qr_url" alt="Nomad QR" />
  <code>$payload</code>
</div>
</html>
HTML
    open_file "$html"
  fi
}

main "$@"
