#!/usr/bin/env bash
# iphone-dev-service — signing and delivery environment for iOS apps over USB.
#
# This CLI brings up and drives a self-contained stack that lets an agent (or a
# human) sign and install arbitrary .ipa files onto a USB-connected iPhone
# without root and without macOS:
#
#   usbmuxd                 device transport (private socket + persisted pairing)
#   anisette-server         Apple ADI/anisette machine (Docker, persisted)
#   anisette-proxy          strips the Xcode client-info that Apple 503s
#   gsa-proxy :4443         gsa.apple.com, fresh TLS connection per request
#   gsa-proxy :4444         developerservices2.apple.com (App IDs / profiles)
#   AltServer + zsign       Apple-ID login, app-id registration, signing, install
#
# The relevant subcommands are `up`, `sideload`, and `build-install`; run
# `iphone-dev-service help` for the full list.
set -euo pipefail

SHARE="${IPHONE_DEV_SERVICE_SHARE:-@shareDir@}"
VERSION="@version@"
PYTHON="${IPHONE_DEV_PYTHON:-python3}"
RUNTIME="${CONTAINER_RUNTIME:-podman}"

# ---------------------------------------------------------------- layout -----
STATE_ROOT="${IPHONE_DEV_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/iphone-dev-service}"
CONFIG_ROOT="${IPHONE_DEV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/iphone-dev-service}"
LOCKDOWN="$STATE_ROOT/lockdown"
TOOLS="$STATE_ROOT/tools"
ANISETTE_STATE="$STATE_ROOT/anisette"
RUN="$STATE_ROOT/run"
SOCK="$RUN/usbmuxd.sock"

# ----------------------------------------------------------------- ports -----
ANISETTE_PORT="${IPHONE_DEV_ANISETTE_PORT:-6970}"
ANISETTE_PROXY_PORT="${IPHONE_DEV_ANISETTE_PROXY_PORT:-6969}"
GSA_PORT="${IPHONE_DEV_GSA_PORT:-4443}"
DEVSERVICES_PORT="${IPHONE_DEV_DEVSERVICES_PORT:-4444}"

# ---------------------------------------------------------------- images -----
ALTSERVER_IMAGE="${IPHONE_DEV_ALTSERVER_IMAGE:-ghcr.io/dragoshont/altserver-linux:latest-main}"
ANISETTE_IMAGE="${IPHONE_DEV_ANISETTE_IMAGE:-localhost/iphone-dev-anisette:latest}"
ANISETTE_CONTAINER="${IPHONE_DEV_ANISETTE_CONTAINER:-iphone-dev-anisette}"

export IPHONE_DEV_LOG_DIR="$RUN"
export IPHONE_DEV_ANISETTE_PROXY="http://127.0.0.1:$ANISETTE_PROXY_PORT"
export IPHONE_DEV_ANISETTE_UPSTREAM="http://127.0.0.1:$ANISETTE_PORT"
export IPHONE_DEV_ANISETTE_PROXY_PORT="$ANISETTE_PROXY_PORT"
export IPHONE_DEV_GSA_PORT="$GSA_PORT"
export IPHONE_DEV_DEVSERVICES_PORT="$DEVSERVICES_PORT"

# ------------------------------------------------------------------ utils -----
log() { printf '[iphone-dev-service] %s\n' "$*" >&2; }
warn() { printf '[iphone-dev-service] WARNING: %s\n' "$*" >&2; }
die() { printf '[iphone-dev-service] ERROR: %s\n' "$*" >&2; exit 1; }

ensure_dirs() {
  mkdir -p "$LOCKDOWN" "$TOOLS" "$ANISETTE_STATE" "$RUN" "$CONFIG_ROOT"
  chmod 700 "$CONFIG_ROOT" 2>/dev/null || true
}

image_exists() { "$RUNTIME" image inspect "$1" >/dev/null 2>&1; }
container_exists() { "$RUNTIME" container inspect "$1" >/dev/null 2>&1; }
container_running() {
  [ "$("$RUNTIME" container inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]
}

component_pid() {
  local name="$1"
  local pidfile="$RUN/$name.pid"
  [ -f "$pidfile" ] || return 1
  local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

component_running() { component_pid "$1" >/dev/null 2>&1; }

start_component() {
  local name="$1"; shift
  if component_running "$name"; then
    log "$name already running (pid $(component_pid "$name"))"
    return 0
  fi
  # setsid forks, so $! is not the daemon pid: have the child record its own
  # pid ($$ stays valid across the exec) before exec'ing the daemon.
  local pidfile="$RUN/$name.pid"
  rm -f "$pidfile"
  setsid nohup bash -c 'pidfile="$1"; shift; echo $$ > "$pidfile"; exec "$@"' \
    _ "$pidfile" "$@" </dev/null >>"$RUN/$name.log" 2>&1 &
  local i
  for ((i = 0; i < 30; i++)); do
    [ -s "$pidfile" ] && break
    sleep 0.1
  done
  log "started $name (pid $(cat "$pidfile" 2>/dev/null || echo '?'))"
}

stop_component() {
  local name="$1"
  local pidfile="$RUN/$name.pid"
  local pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 0.3
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
  log "stopped $name"
}

wait_for_url() {
  local url="$1" timeout="${2:-60}" i
  for ((i = 0; i < timeout; i++)); do
    if curl -sf -m 4 -o /dev/null "$url" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_port() {
  local host="$1" port="$2" timeout="${3:-30}" i
  for ((i = 0; i < timeout; i++)); do
    if "$PYTHON" - "$host" "$port" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(2)
s.connect((sys.argv[1], int(sys.argv[2])))
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

device_udid() {
  USBMUXD_SOCKET_ADDRESS="UNIX:$SOCK" idevice_id -l 2>/dev/null | head -n1
}

load_credentials() {
  local file="${IPHONE_DEV_CREDENTIALS:-}"
  if [ -z "$file" ]; then
    if [ -f "$CONFIG_ROOT/credentials" ]; then
      file="$CONFIG_ROOT/credentials"
    elif [ -f "$PWD/credentials.txt" ]; then
      file="$PWD/credentials.txt"
    fi
  fi
  [ -n "$file" ] && [ -f "$file" ] || die "no credentials file (set IPHONE_DEV_CREDENTIALS or create $CONFIG_ROOT/credentials)"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  [ -n "${APPLE_ID:-}" ] || die "APPLE_ID missing from $file"
  [ -n "${APPLE_PASSWORD:-}" ] || die "APPLE_PASSWORD missing from $file"
}

# -------------------------------------------------------------- components ----
start_usbmuxd() {
  if component_running usbmuxd; then
    log "usbmuxd already running"
    return 0
  fi
  # seed the pairing record from the config dir on first use
  if [ -d "$CONFIG_ROOT/lockdown" ] && [ -z "$(ls -A "$LOCKDOWN" 2>/dev/null)" ]; then
    cp -a "$CONFIG_ROOT/lockdown/." "$LOCKDOWN/" 2>/dev/null || true
    log "seeded pairing records from $CONFIG_ROOT/lockdown"
  fi
  rm -f "$SOCK"
  start_component usbmuxd \
    usbmuxd -f -v -p -S "$SOCK" -P "$RUN/usbmuxd.pid" -C "$LOCKDOWN" -l "$RUN/usbmuxd.log"
  wait_for_port 127.0.0.1 1 1 2>/dev/null || true
  sleep 1
}

stop_usbmuxd() { stop_component usbmuxd; }

ensure_tools() {
  if [ -x "$TOOLS/AltServer.patched" ] && [ -x "$TOOLS/zsign" ]; then
    return 0
  fi
  log "fetching signing engine ($ALTSERVER_IMAGE) ..."
  "$RUNTIME" pull "$ALTSERVER_IMAGE" >/dev/null
  rm -rf "$TOOLS"
  mkdir -p "$TOOLS"
  "$RUNTIME" run --rm -v "$TOOLS:/dest" "$ALTSERVER_IMAGE" extract
  chmod +x "$TOOLS/AltServer" "$TOOLS/zsign" 2>/dev/null || true
  [ -x "$TOOLS/AltServer" ] || die "AltServer extraction failed"
  "$PYTHON" "$SHARE/patch_altserver.py" "$TOOLS/AltServer" "$TOOLS/AltServer.patched"
  log "signing engine ready in $TOOLS"
}

ensure_anisette() {
  if ! image_exists "$ANISETTE_IMAGE"; then
    log "building anisette image $ANISETTE_IMAGE ..."
    "$RUNTIME" build -t "$ANISETTE_IMAGE" -f "$SHARE/Dockerfile.anisette" "$SHARE" >&2
  fi
  if ! container_exists "$ANISETTE_CONTAINER"; then
    log "starting anisette container ..."
    "$RUNTIME" run -d --name "$ANISETTE_CONTAINER" \
      -p "127.0.0.1:$ANISETTE_PORT:6969" \
      -v "$ANISETTE_STATE:/home/Chester/.config/Provision:U" \
      "$ANISETTE_IMAGE" >/dev/null
  elif ! container_running "$ANISETTE_CONTAINER"; then
    "$RUNTIME" start "$ANISETTE_CONTAINER" >/dev/null
  fi
  if ! wait_for_url "http://127.0.0.1:$ANISETTE_PORT/" 90; then
    die "anisette server did not become ready (see: $RUNTIME logs $ANISETTE_CONTAINER)"
  fi
}

stop_anisette() {
  if container_exists "$ANISETTE_CONTAINER"; then
    "$RUNTIME" rm -f "$ANISETTE_CONTAINER" >/dev/null 2>&1 || true
    log "removed anisette container (machine state kept in $ANISETTE_STATE)"
  fi
}

start_proxies() {
  start_component anisette-proxy "$PYTHON" "$SHARE/anisette-proxy.py"
  start_component gsa-4443 "$PYTHON" "$SHARE/gsa-proxy.py" "$GSA_PORT" gsa.apple.com --refresh-2fa
  start_component gsa-4444 "$PYTHON" "$SHARE/gsa-proxy.py" "$DEVSERVICES_PORT" developerservices2.apple.com
  wait_for_port 127.0.0.1 "$ANISETTE_PROXY_PORT" 20 || die "anisette proxy did not start"
  wait_for_port 127.0.0.1 "$GSA_PORT" 20 || die "gsa proxy did not start"
  wait_for_port 127.0.0.1 "$DEVSERVICES_PORT" 20 || die "developerservices proxy did not start"
}

stop_proxies() {
  stop_component anisette-proxy
  stop_component gsa-4443
  stop_component gsa-4444
}

write_env_file() {
  cat > "$STATE_ROOT/env" <<EOF
export USBMUXD_SOCKET_ADDRESS="UNIX:$SOCK"
export ALTSERVER_ANISETTE_SERVER="http://127.0.0.1:$ANISETTE_PROXY_PORT"
export ALTSIGN_ZSIGN="$TOOLS/zsign"
export PATH="$TOOLS:\$PATH"
EOF
}

# ------------------------------------------------------------- commands -------
cmd_up() {
  ensure_dirs
  start_usbmuxd
  ensure_tools
  ensure_anisette
  start_proxies
  write_env_file
  log "stack up. source $STATE_ROOT/env to use AltServer directly."
}

cmd_down() {
  stop_proxies
  stop_anisette
  stop_usbmuxd
  log "stack down."
}

cmd_status() {
  ensure_dirs
  echo "state:      $STATE_ROOT"
  echo "config:     $CONFIG_ROOT"
  echo "socket:     $SOCK"
  echo
  printf '%-16s %s\n' usbmuxd "$(component_running usbmuxd && echo "running (pid $(component_pid usbmuxd))" || echo stopped)"
  printf '%-16s %s\n' anisette "$(container_running "$ANISETTE_CONTAINER" && echo "running (:${ANISETTE_PORT})" || echo stopped)"
  printf '%-16s %s\n' anisette-proxy "$(component_running anisette-proxy && echo "running (:$ANISETTE_PROXY_PORT)" || echo stopped)"
  printf '%-16s %s\n' gsa-proxy "$(component_running gsa-4443 && echo "running (:$GSA_PORT)" || echo stopped)"
  printf '%-16s %s\n' devservices "$(component_running gsa-4444 && echo "running (:$DEVSERVICES_PORT)" || echo stopped)"
  printf '%-16s %s\n' altserver "$([ -x "$TOOLS/AltServer.patched" ] && echo "ready ($TOOLS/AltServer.patched)" || echo "not fetched")"
  printf '%-16s %s\n' zsign "$([ -x "$TOOLS/zsign" ] && echo ready || echo "not fetched")"
  echo
  local udid; udid="$(device_udid || true)"
  printf '%-16s %s\n' device "${udid:-none}"
  if [ -n "$udid" ]; then
    printf '%-16s %s\n' pairing \
      "$(USBMUXD_SOCKET_ADDRESS="UNIX:$SOCK" idevicepair validate 2>&1 | tail -n1)"
  fi
}

cmd_env() {
  ensure_dirs
  write_env_file
  cat "$STATE_ROOT/env"
}

cmd_pair() {
  ensure_dirs
  start_usbmuxd
  export USBMUXD_SOCKET_ADDRESS="UNIX:$SOCK"
  log "pairing: accept the Trust prompt on the device (may need it unlocked)"
  idevicepair pair
  idevicepair validate
  log "pairing record stored in $LOCKDOWN (copy to $CONFIG_ROOT/lockdown to persist)"
}

cmd_devices() {
  ensure_dirs
  start_usbmuxd
  USBMUXD_SOCKET_ADDRESS="UNIX:$SOCK" idevice_id -l
}

cmd_sideload() {
  [ $# -ge 1 ] || die "usage: iphone-dev-service sideload <path/to/app.ipa>"
  local ipa; ipa="$(readlink -f "$1")"
  [ -f "$ipa" ] || die "IPA not found: $ipa"
  load_credentials
  cmd_up
  local udid; udid="${IPHONE_DEV_UDID:-$(device_udid || true)}"
  [ -n "$udid" ] || die "no device detected on $SOCK"
  export USBMUXD_SOCKET_ADDRESS="UNIX:$SOCK"
  export ALTSERVER_ANISETTE_SERVER="http://127.0.0.1:$ANISETTE_PROXY_PORT"
  export ALTSIGN_ZSIGN="$TOOLS/zsign"
  log "signing + installing $(basename "$ipa") on $udid ..."
  "$PYTHON" "$SHARE/sideload.py" \
    --altserver "$TOOLS/AltServer.patched" \
    --ipa "$ipa" \
    --udid "$udid" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --code-file "${IPHONE_DEV_2FA_FILE:-$PWD/2fa.txt}" \
    --log "$RUN/sideload.log"
}

cmd_build_install() {
  [ $# -ge 1 ] || die "usage: iphone-dev-service build-install <source-dir>"
  local src; src="$(readlink -f "$1")"
  [ -d "$src" ] || die "source dir not found: $src"
  load_credentials
  local sdk="${IOS_SDK:-$CONFIG_ROOT/ios-sdk/iPhoneOS.sdk}"
  export IOS_SDK="$sdk"
  [ -d "$sdk" ] || die "iOS SDK not found at $sdk (set IOS_SDK or place it at $CONFIG_ROOT/ios-sdk/iPhoneOS.sdk)"
  mkdir -p "$RUN/build"
  local name; name="$(basename "$src")"
  local ipa; ipa="$("$SHARE/build-ios.sh" "$src" "$RUN/build/$name.ipa")"
  log "built $ipa"
  cmd_sideload "$ipa"
}

cmd_doctor() {
  ensure_dirs
  local rc=0
  echo "== iphone-dev-service doctor =="
  for tool in "$RUNTIME" curl openssl usbmuxd idevice_id idevicepair python3; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf 'ok    %s (%s)\n' "$tool" "$(command -v "$tool")"
    else
      printf 'FAIL  %s not found\n' "$tool"; rc=1
    fi
  done
  echo
  cmd_status
  echo
  if [ -f "$STATE_ROOT/env" ]; then
    echo "== env file =="; cat "$STATE_ROOT/env"
  fi
  return $rc
}

cmd_seed_anisette() {
  local from="${1:-}"
  [ -n "$from" ] || die "usage: iphone-dev-service seed-anisette <container-with-trusted-machine>"
  "$RUNTIME" container inspect "$from" >/dev/null 2>&1 || die "container not found: $from"
  ensure_dirs
  rm -rf "$ANISETTE_STATE"; mkdir -p "$ANISETTE_STATE"
  "$RUNTIME" cp "$from:/home/Chester/.config/Provision/." "$ANISETTE_STATE/"
  log "copied anisette machine state from $from to $ANISETTE_STATE"
}

cmd_install_user_service() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/iphone-dev-service.service" <<EOF
[Unit]
Description=iPhone signing and delivery environment (usbmuxd + anisette + proxies)
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/.nix-profile/bin/iphone-dev-service up
ExecStop=%h/.nix-profile/bin/iphone-dev-service down
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF
  log "wrote $unit_dir/iphone-dev-service.service"
  log "enable with: systemctl --user daemon-reload && systemctl --user enable --now iphone-dev-service.service"
}

usage() {
  cat <<EOF
iphone-dev-service $VERSION — signing and delivery environment for iOS over USB

usage: iphone-dev-service <command> [args]

commands:
  up                       start usbmuxd, the anisette server, and the proxies
  down                     stop everything (anisette machine state is kept)
  restart                  down + up
  status                   show component / device / pairing status
  doctor                    environment + connectivity diagnostics
  env                      print the exports needed to drive AltServer directly
  pair                     pair (trust) the connected device
  devices                  list connected device UDIDs
  sideload <app.ipa>       sign + install an IPA on the device
  build-install <dir>      compile <dir> into an IPA and sideload it (needs IOS_SDK)
  seed-anisette <ctr>      copy a trusted anisette machine out of <ctr>
  install-user-service     write a systemd --user unit for this stack
  version | help           this message

environment:
  IPHONE_DEV_STATE         state root (default: \$XDG_STATE_HOME/iphone-dev-service)
  IPHONE_DEV_CONFIG        config root with credentials (default: \$XDG_CONFIG_HOME/iphone-dev-service)
  IPHONE_DEV_CREDENTIALS   credentials file (APPLE_ID / APPLE_PASSWORD)
  IPHONE_DEV_UDID          force a device UDID
  IPHONE_DEV_2FA_FILE      where to read the 2FA code (default: ./2fa.txt)
  IOS_SDK                  iPhoneOS.sdk for build-install
  CONTAINER_RUNTIME        podman (default) or docker
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    up) cmd_up "$@" ;;
    down) cmd_down "$@" ;;
    restart) cmd_down "$@"; cmd_up ;;
    status) cmd_status "$@" ;;
    doctor) cmd_doctor "$@" ;;
    env) cmd_env "$@" ;;
    pair) cmd_pair "$@" ;;
    devices) cmd_devices "$@" ;;
    sideload) cmd_sideload "$@" ;;
    build-install) cmd_build_install "$@" ;;
    seed-anisette) cmd_seed_anisette "$@" ;;
    install-user-service) cmd_install_user_service "$@" ;;
    version) echo "iphone-dev-service $VERSION" ;;
    help|-h|--help) usage ;;
    *) die "unknown command: $cmd (try 'iphone-dev-service help')" ;;
  esac
}

main "$@"