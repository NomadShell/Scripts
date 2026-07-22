#!/usr/bin/env bash
set -euo pipefail

info() {
  printf "[Moshline] %s\n" "$*"
}

MOSHLINE_HOST_VERSION="0.1.3"
MOSHLINE_HOST_SHA256="a6c09a0861a91ecb2e477baae0cf5e3afda7f0b64fc930539c1f054ed659866b"
MOSHLINE_RELEASE_ROOT="${MOSHLINE_DOWNLOAD_BASE_URL:-https://raw.githubusercontent.com/NomadShell/Scripts/main/dist}"
MOSHLINE_TEMP_DIR=""

cleanup() {
  if [ -n "${MOSHLINE_TEMP_DIR:-}" ] && [ -d "$MOSHLINE_TEMP_DIR" ]; then
    rm -rf "$MOSHLINE_TEMP_DIR"
  fi
}

trap cleanup EXIT

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'USAGE'
Usage:
  quick-setup.sh [--host <address>] [--user <name>] [--port <port>]
                 [--bridge-port <port>] [--skip-system-setup] [--no-browser]

Options:
  --host               Override the detected address advertised to the iPhone app
  --user               Override the SSH username
  --port               Override the SSH port (default: 22)
  --bridge-port        Override the Host Helper port (default: 24000)
  --skip-system-setup  Skip dependency, SSH service, and firewall changes
  --no-browser         Do not open a browser for the legacy terminal-only QR page
USAGE
}

validate_port() {
  local label="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      info "$label must be an integer between 1 and 65535."
      exit 1
      ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    info "$label must be an integer between 1 and 65535."
    exit 1
  fi
}

node_runtime_supported() {
  command_exists node && command_exists npm && [ "$(node -p 'Number(process.versions.node.split(".")[0]) >= 18 ? "yes" : "no"' 2>/dev/null || true)" = "yes" ]
}

install_deps() {
  local missing=()
  command_exists mosh || missing+=(mosh)
  command_exists tmux || missing+=(tmux)
  command_exists sshd || missing+=(openssh-server)
  node_runtime_supported || missing+=(nodejs-18+ npm)

  if [ ${#missing[@]} -eq 0 ]; then
    return
  fi

  info "Installing dependencies: ${missing[*]}"
  if command_exists brew; then
    brew install mosh tmux qrencode node
    install_supported_node_runtime
    return
  fi
  if command_exists apt-get; then
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl mosh tmux qrencode openssh-server
    install_supported_node_runtime
    return
  fi
  if command_exists yum; then
    sudo yum install -y ca-certificates curl mosh tmux qrencode openssh-server
    install_supported_node_runtime
    return
  fi
  if command_exists dnf; then
    sudo dnf install -y ca-certificates curl mosh tmux qrencode openssh-server
    install_supported_node_runtime
    return
  fi

  info "No supported package manager found. Please install: Node.js 18+, npm, mosh, tmux (and optional qrencode)."
}

require_node_runtime() {
  if node_runtime_supported; then
    return
  fi
  info "Moshline Host Helper requires Node.js 18 or newer and npm."
  info "Install a current Node.js release, then run this setup command again."
  exit 1
}

download_file() {
  local url="$1"
  local destination="$2"
  if command_exists curl; then
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$destination"
    return
  fi
  if command_exists wget; then
    wget -O "$destination" "$url"
    return
  fi
  info "curl or wget is required to download Moshline Host Helper."
  exit 1
}

install_supported_node_runtime() {
  if node_runtime_supported; then
    return
  fi

  local setup_url=""
  local package_manager=""
  if command_exists apt-get; then
    setup_url="https://deb.nodesource.com/setup_22.x"
    package_manager="apt"
  elif command_exists dnf; then
    setup_url="https://rpm.nodesource.com/setup_22.x"
    package_manager="dnf"
  elif command_exists yum; then
    setup_url="https://rpm.nodesource.com/setup_22.x"
    package_manager="yum"
  else
    return
  fi

  local node_setup_dir
  node_setup_dir=$(mktemp -d "${TMPDIR:-/tmp}/moshline-node.XXXXXX")
  MOSHLINE_TEMP_DIR="$node_setup_dir"
  local node_setup_script="${node_setup_dir}/nodesource.sh"
  info "The system Node.js is too old; enabling the NodeSource 22.x repository..."
  download_file "$setup_url" "$node_setup_script"
  sudo -E bash "$node_setup_script"
  case "$package_manager" in
    apt)
      sudo apt-get install -y nodejs
      ;;
    dnf)
      sudo dnf install -y nodejs
      ;;
    yum)
      sudo yum install -y nodejs
      ;;
  esac
  rm -rf "$node_setup_dir"
  MOSHLINE_TEMP_DIR=""

  if ! node_runtime_supported; then
    info "Unable to install Node.js 18 or newer."
    exit 1
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual=""
  if command_exists shasum; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  elif command_exists sha256sum; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  else
    info "shasum or sha256sum is required to verify the Host Helper download."
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    info "Host Helper checksum mismatch; refusing to install."
    exit 1
  fi
}

install_host_helper() {
  require_node_runtime

  MOSHLINE_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/moshline-host.XXXXXX")
  local archive="${MOSHLINE_TEMP_DIR}/moshline-host-${MOSHLINE_HOST_VERSION}.tgz"
  local archive_url="${MOSHLINE_RELEASE_ROOT}/moshline-host-${MOSHLINE_HOST_VERSION}.tgz"

  info "Downloading Moshline Host Helper ${MOSHLINE_HOST_VERSION} from GitHub..."
  download_file "$archive_url" "$archive"
  verify_sha256 "$archive" "$MOSHLINE_HOST_SHA256"

  info "Installing the verified Host Helper package..."
  local npm_prefix
  npm_prefix=$(npm prefix --global 2>/dev/null || true)
  if [ "$(id -u)" -eq 0 ] || { [ -n "$npm_prefix" ] && [ -w "$npm_prefix" ]; }; then
    npm install --global "$archive"
  else
    sudo npm install --global "$archive"
  fi
  hash -r
  if ! command_exists moshline-host; then
    info "Host Helper installed, but moshline-host is not on PATH."
    exit 1
  fi
}

wait_for_host_helper() {
  local attempt=1
  while [ "$attempt" -le 15 ]; do
    if moshline-host doctor --json >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

enable_ssh() {
  if [ "${MOSHLINE_SKIP_SSH_ENABLE:-0}" = "1" ]; then
    info "Skipping SSH service changes (MOSHLINE_SKIP_SSH_ENABLE=1)."
    return
  fi
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

configure_firewall() {
  local ssh_port="$1"
  local bridge_port="$2"
  if [ "${MOSHLINE_SKIP_FIREWALL:-0}" = "1" ]; then
    info "Skipping firewall changes (MOSHLINE_SKIP_FIREWALL=1)."
    return
  fi

  if command_exists ufw && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "Allowing SSH, Host Helper, and Mosh through ufw..."
    sudo ufw allow "${ssh_port}/tcp" >/dev/null
    sudo ufw allow "${bridge_port}/tcp" >/dev/null
    sudo ufw allow '60000:61000/udp' >/dev/null
    return
  fi

  if command_exists firewall-cmd && sudo firewall-cmd --state >/dev/null 2>&1; then
    info "Allowing SSH, Host Helper, and Mosh through firewalld..."
    sudo firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null
    sudo firewall-cmd --permanent --add-port="${bridge_port}/tcp" >/dev/null
    sudo firewall-cmd --permanent --add-port='60000-61000/udp' >/dev/null
    sudo firewall-cmd --reload >/dev/null
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
  local host_override=""
  local user_override=""
  local ssh_port="${MOSHLINE_SSH_PORT:-22}"
  local bridge_port="${MOSHLINE_BRIDGE_PORT:-24000}"
  local skip_system_setup="${MOSHLINE_SKIP_SYSTEM_SETUP:-0}"
  local no_browser=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host)
        [ "$#" -ge 2 ] || { info "--host requires a value."; usage; exit 1; }
        host_override="$2"
        shift 2
        ;;
      --user)
        [ "$#" -ge 2 ] || { info "--user requires a value."; usage; exit 1; }
        user_override="$2"
        shift 2
        ;;
      --port)
        [ "$#" -ge 2 ] || { info "--port requires a value."; usage; exit 1; }
        ssh_port="$2"
        shift 2
        ;;
      --bridge-port)
        [ "$#" -ge 2 ] || { info "--bridge-port requires a value."; usage; exit 1; }
        bridge_port="$2"
        shift 2
        ;;
      --skip-system-setup)
        skip_system_setup=1
        shift
        ;;
      --no-browser)
        no_browser=1
        shift
        ;;
      -h|--help)
        usage
        return
        ;;
      *)
        info "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  validate_port "SSH port" "$ssh_port"
  validate_port "Host Helper port" "$bridge_port"

  if [ "$skip_system_setup" = "1" ]; then
    info "Skipping dependency, SSH service, and firewall setup."
  else
    install_deps
    enable_ssh
    configure_firewall "$ssh_port" "$bridge_port"
  fi
  add_pubkey_if_provided

  local ip
  if [ -n "$host_override" ]; then
    ip="$host_override"
  else
    ip=$(detect_ip)
  fi
  if [ -z "$ip" ]; then
    info "Unable to detect a LAN IP. Please run on the server and provide --host manually."
    exit 1
  fi

  local user
  if [ -n "$user_override" ]; then
    user="$user_override"
  else
    user=$(whoami)
  fi

  local terminal_only="${MOSHLINE_TERMINAL_ONLY:-${NOMAD_TERMINAL_ONLY:-${NOMAD_LEGACY_SETUP:-0}}}"
  if [ "$terminal_only" != "1" ]; then
    install_host_helper
    info "Configuring SSH, persistent sessions, agent hooks, Inbox, and Usages..."
    local pairing_output
    pairing_output=$(moshline-host setup \
      --address "$ip" \
      --user "$user" \
      --ssh-port "$ssh_port" \
      --bridge-port "$bridge_port")
    info "Waiting for Host Helper self-checks..."
    if ! wait_for_host_helper; then
      info "Host Helper was installed but did not become ready."
      moshline-host doctor || true
      exit 1
    fi
    printf '%s\n' "$pairing_output"
    info "Done. Scan the Moshline Host Helper QR code in the Moshline app."
    info "Run 'moshline-host doctor' any time to check the connection and agent hooks."
    return
  fi

  info "Using legacy terminal-only setup (Host Helper, Inbox, and Usages are disabled)."

  local token
  token=$(make_token)

  local payload
  payload=$(encode_payload "$ip" "$user" "$ssh_port" "$token")

  info "Legacy terminal-only setup payload:"
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
    if [ "$no_browser" -eq 1 ]; then
      info "QR page saved to $html"
    else
      info "Opening QR code in browser..."
      open_file "$html"
    fi
  fi

  info "Done. Scan the QR code from the Moshline app."
}

if [ "${MOSHLINE_SETUP_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
