#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APPID="730"
CONFIG_DIR="/etc/cs2"
RUNTIME_CONF="$CONFIG_DIR/runtime.conf"
UPDATE_MESSAGE_FILE="$CONFIG_DIR/update-message.txt"
START_SCRIPT="/usr/local/bin/cs2-start"
WORKSHOP_CONF="$CONFIG_DIR/workshop.conf"
WORKSHOP_HELPER="/usr/local/bin/cs2-workshop"
RCON_HELPER="/usr/local/libexec/cs2-rcon"
UPDATER_SCRIPT="/usr/local/sbin/cs2-autoupdate"
SERVICE_FILE="/etc/systemd/system/cs2.service"
UPDATE_SERVICE_FILE="/etc/systemd/system/cs2-autoupdate.service"
UPDATE_TIMER_FILE="/etc/systemd/system/cs2-autoupdate.timer"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

ask() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        printf '%s' "${value:-$default}"
    else
        read -r -p "$prompt: " value
        printf '%s' "$value"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N]: " answer
        answer="${answer:-n}"
    fi

    [[ "$answer" =~ ^[YyJj]$ ]]
}

valid_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

valid_ipv4() {
    local ip="$1" octet
    local IFS=.
    read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
}

cfg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Please run as root: sudo $0"
}

check_platform() {
    [[ "$(uname -s)" == "Linux" ]] || die "This script is intended for Linux only."

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "This script currently supports x86_64/amd64 only." ;;
    esac

    [[ -r /etc/os-release ]] || die "/etc/os-release is missing."
    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu) ;;
        *)
            if [[ "${ID_LIKE:-}" != *debian* ]]; then
                die "Supported systems are Debian/Ubuntu and Debian-based distributions."
            fi
            ;;
    esac
}

collect_settings() {
    echo "CS2 Dedicated Server Installer"
    echo "------------------------------"
    echo "Default: 16-slot Deathmatch, port 27015, update check every 5 minutes."
    echo

    SERVER_USER="$(ask "Linux user for the CS2 server" "steam")"
    [[ "$SERVER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid Linux username."

    if id "$SERVER_USER" >/dev/null 2>&1; then
        SERVER_HOME="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
        [[ -n "$SERVER_HOME" ]] || die "Could not determine home directory for $SERVER_USER."
    else
        SERVER_HOME="/home/$SERVER_USER"
    fi

    [[ "$SERVER_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "The home directory contains unsupported characters: $SERVER_HOME"

    INSTALL_DIR="$(ask "CS2 installation directory" "$SERVER_HOME/cs2")"
    [[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]         || die "Installation path must be absolute and may only contain letters, numbers, /, ., _ and -."

    HOSTNAME_VALUE="$(ask "Server name" "My CS2 Deathmatch")"

    PORT="$(ask "Game/RCON-Port" "27015")"
    valid_uint "$PORT" && (( PORT >= 1 && PORT <= 65535 )) || die "Invalid port."

    BIND_IP="$(ask "Bind IP address" "0.0.0.0")"
    valid_ipv4 "$BIND_IP" || die "Invalid IPv4 address."

    MAXPLAYERS="$(ask "Maximum slots" "16")"
    valid_uint "$MAXPLAYERS" && (( MAXPLAYERS >= 1 && MAXPLAYERS <= 64 )) || die "Slots must be between 1 and 64."

    echo
    echo "Game mode:"
    echo "  1) Deathmatch   (game_type 1 / game_mode 2)"
    echo "  2) Competitive  (0 / 1)"
    echo "  3) Casual       (0 / 0)"
    echo "  4) Custom values"
    MODE_CHOICE="$(ask "Selection" "1")"

    case "$MODE_CHOICE" in
        1)
            GAME_TYPE="1"
            GAME_MODE="2"
            ;;
        2)
            GAME_TYPE="0"
            GAME_MODE="1"
            ;;
        3)
            GAME_TYPE="0"
            GAME_MODE="0"
            ;;
        4)
            GAME_TYPE="$(ask "game_type" "1")"
            GAME_MODE="$(ask "game_mode" "2")"
            valid_uint "$GAME_TYPE" || die "game_type must be numeric."
            valid_uint "$GAME_MODE" || die "game_mode must be numeric."
            ;;
        *)
            die "Invalid mode selection."
            ;;
    esac

    START_MAP="$(ask "Start map" "de_dust2")"
    [[ "$START_MAP" =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid map name."

    echo
    echo "A GSLT is required for a public CS2 server (App ID 730)."
    read -r -s -p "GSLT (leave blank for later/LAN): " GSLT
    echo

    echo
    read -r -s -p "RCON password (blank = generate automatically): " RCON_PASSWORD
    echo
    if [[ -z "$RCON_PASSWORD" ]]; then
        RCON_PASSWORD="$(openssl rand -hex 24 2>/dev/null || true)"
        if [[ -z "$RCON_PASSWORD" ]]; then
            RCON_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
        fi
        echo "RCON password was generated automatically."
    fi
    [[ "$RCON_PASSWORD" != *$'\n'* && "$RCON_PASSWORD" != *$'\r'* ]] || die "RCON password must not contain a line break."

    read -r -s -p "Server password (blank = public): " SV_PASSWORD
    echo
    [[ "$SV_PASSWORD" != *$'\n'* && "$SV_PASSWORD" != *$'\r'* ]] || die "Server password must not contain a line break."

    UPDATE_INTERVAL_MINUTES="$(ask "Check for updates every how many minutes?" "5")"
    valid_uint "$UPDATE_INTERVAL_MINUTES" && (( UPDATE_INTERVAL_MINUTES >= 1 && UPDATE_INTERVAL_MINUTES <= 1440 )) \
        || die "Update interval must be between 1 and 1440 minutes."

    UPDATE_MESSAGE="$(ask "5-minute RCON message" "CS2 Released an Update - Restart in 5 minutes")"
    UPDATE_MESSAGE="${UPDATE_MESSAGE//$'\r'/}"
    UPDATE_MESSAGE="${UPDATE_MESSAGE//$'\n'/ }"

    START_NOW="no"
    if ask_yes_no "Start the server immediately after installation?" "y"; then
        START_NOW="yes"
    fi
}

install_packages() {
    info "Installing required packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        tar \
        python3 \
        openssl \
        util-linux \
        lib32gcc-s1 \
        lib32stdc++6
}

create_user() {
    if id "$SERVER_USER" >/dev/null 2>&1; then
        info "User $SERVER_USER already exists"
    else
        info "Creating user $SERVER_USER"
        useradd --create-home --home-dir "$SERVER_HOME" --shell /bin/bash "$SERVER_USER"
    fi

    SERVER_HOME="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
    SERVER_GROUP="$(id -gn "$SERVER_USER")"
    [[ -n "$SERVER_HOME" ]] || die "Could not determine home directory."

    STEAMCMD_DIR="$SERVER_HOME/steamcmd"
    STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
    SECRET_DIR="$SERVER_HOME/.config/cs2"
}

install_steamcmd() {
    info "Installing/updating SteamCMD"

    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_GROUP" "$STEAMCMD_DIR"

    if [[ ! -x "$STEAMCMD" ]]; then
        tmp_archive="$(mktemp)"
        trap 'rm -f "${tmp_archive:-}"' EXIT
        curl -fL --retry 3 \
            "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
            -o "$tmp_archive"
        tar -xzf "$tmp_archive" -C "$STEAMCMD_DIR"
        rm -f "$tmp_archive"
        trap - EXIT
        chown -R "$SERVER_USER:$SERVER_GROUP" "$STEAMCMD_DIR"
    fi

    runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" "$STEAMCMD" +quit
}

install_cs2() {
    info "Installing/updating Counter-Strike 2 (App ID $APPID)"

    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_GROUP" "$INSTALL_DIR"

    local manifest="$INSTALL_DIR/steamapps/appmanifest_${APPID}.acf"

    if systemctl is-active --quiet cs2.service 2>/dev/null; then
        systemctl stop cs2.service
    fi

    if [[ -f "$manifest" ]]; then
        echo "Existing installation detected: normal app_update without validate."
        runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
            "$STEAMCMD" \
            +force_install_dir "$INSTALL_DIR" \
            +login anonymous \
            +app_update "$APPID" \
            +quit
    else
        echo "New installation detected: initial download with validate."
        runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
            "$STEAMCMD" \
            +force_install_dir "$INSTALL_DIR" \
            +login anonymous \
            +app_update "$APPID" validate \
            +quit
    fi

    [[ -x "$INSTALL_DIR/game/bin/linuxsteamrt64/cs2" ]] \
        || die "CS2 binary was not found: $INSTALL_DIR/game/bin/linuxsteamrt64/cs2"
}

install_v8_compat_links() {
    info "Setting up CS2 V8 compatibility library links"

    local src_dir="$INSTALL_DIR/game/bin/linuxsteamrt64"
    local dst_dir="$INSTALL_DIR/game/csgo/bin/linuxsteamrt64"
    local lib found=0

    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_GROUP" "$dst_dir"

    for lib in "$src_dir"/libv8*.so; do
        [[ -e "$lib" ]] || continue
        found=1
        ln -sfn "$lib" "$dst_dir/$(basename "$lib")"
    done

    (( found == 1 )) || die "No libv8*.so libraries found in $src_dir"

    chown -h "$SERVER_USER:$SERVER_GROUP" "$dst_dir"/libv8*.so 2>/dev/null || true
}

install_steam_sdk_links() {
    info "Setting up Steam SDK libraries"

    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_GROUP" \
        "$SERVER_HOME/.steam/sdk32" \
        "$SERVER_HOME/.steam/sdk64"

    if [[ -f "$STEAMCMD_DIR/linux32/steamclient.so" ]]; then
        ln -sfn "$STEAMCMD_DIR/linux32/steamclient.so" "$SERVER_HOME/.steam/sdk32/steamclient.so"
    fi

    if [[ -f "$STEAMCMD_DIR/linux64/steamclient.so" ]]; then
        ln -sfn "$STEAMCMD_DIR/linux64/steamclient.so" "$SERVER_HOME/.steam/sdk64/steamclient.so"
    fi

    chown -h "$SERVER_USER:$SERVER_GROUP" \
        "$SERVER_HOME/.steam/sdk32/steamclient.so" \
        "$SERVER_HOME/.steam/sdk64/steamclient.so" 2>/dev/null || true
}

write_runtime_config() {
    info "Writing configuration"

    install -d -m 0755 "$CONFIG_DIR"
    install -d -m 0700 -o "$SERVER_USER" -g "$SERVER_GROUP" "$SECRET_DIR"

    cat > "$RUNTIME_CONF" <<EOF
APPID=$APPID
SERVER_USER=$SERVER_USER
SERVER_HOME=$SERVER_HOME
INSTALL_DIR=$INSTALL_DIR
STEAMCMD=$STEAMCMD
PORT=$PORT
BIND_IP=$BIND_IP
MAXPLAYERS=$MAXPLAYERS
START_MAP=$START_MAP
GAME_TYPE=$GAME_TYPE
GAME_MODE=$GAME_MODE
EOF
    chmod 0644 "$RUNTIME_CONF"

    # Keep Workshop mode in a separate file so it can be changed later without
    # rerunning the installer. Do not overwrite an existing Workshop setup.
    if [[ ! -f "$WORKSHOP_CONF" ]]; then
        cat > "$WORKSHOP_CONF" <<'EOF'
WORKSHOP_ENABLED=0
WORKSHOP_COLLECTION=
WORKSHOP_MAP=
EOF
        chmod 0644 "$WORKSHOP_CONF"
    fi

    printf '%s\n' "$UPDATE_MESSAGE" > "$UPDATE_MESSAGE_FILE"
    chmod 0644 "$UPDATE_MESSAGE_FILE"

    printf '%s' "$GSLT" > "$SECRET_DIR/gslt.token"
    printf '%s' "$RCON_PASSWORD" > "$SECRET_DIR/rcon.password"
    chmod 0600 "$SECRET_DIR/gslt.token" "$SECRET_DIR/rcon.password"
    chown "$SERVER_USER:$SERVER_GROUP" "$SECRET_DIR/gslt.token" "$SECRET_DIR/rcon.password"

    CFG_DIR="$INSTALL_DIR/game/csgo/cfg"
    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_GROUP" "$CFG_DIR"

    if [[ -f "$CFG_DIR/server.cfg" ]]; then
        cp -a "$CFG_DIR/server.cfg" "$CFG_DIR/server.cfg.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    local hostname_escaped rcon_escaped svpw_escaped
    hostname_escaped="$(cfg_escape "$HOSTNAME_VALUE")"
    rcon_escaped="$(cfg_escape "$RCON_PASSWORD")"
    svpw_escaped="$(cfg_escape "$SV_PASSWORD")"

    cat > "$CFG_DIR/server.cfg" <<EOF
// Generated by cs2-install.sh
hostname "$hostname_escaped"
rcon_password "$rcon_escaped"
sv_password "$svpw_escaped"

sv_lan 0
sv_cheats 0
sv_hibernate_when_empty 1
sv_visiblemaxplayers $MAXPLAYERS
EOF

    chown "$SERVER_USER:$SERVER_GROUP" "$CFG_DIR/server.cfg"
    chmod 0600 "$CFG_DIR/server.cfg"
}

write_start_script() {
    cat > "$START_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/cs2/runtime.conf

WORKSHOP_CONF="/etc/cs2/workshop.conf"
WORKSHOP_ENABLED=0
WORKSHOP_COLLECTION=""
WORKSHOP_MAP=""
if [[ -r "$WORKSHOP_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$WORKSHOP_CONF"
fi

# Never run the game server itself as root. If this launcher is invoked
# manually as root, immediately re-exec it as the configured server user.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    exec runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" "$0" "$@"
fi

GSLT_FILE="$SERVER_HOME/.config/cs2/gslt.token"
GSLT=""
if [[ -r "$GSLT_FILE" ]]; then
    GSLT="$(<"$GSLT_FILE")"
fi

ARGS=(
    -dedicated
    -console
    -usercon
    -ip "$BIND_IP"
    -port "$PORT"
    -maxplayers_override "$MAXPLAYERS"
    +game_type "$GAME_TYPE"
    +game_mode "$GAME_MODE"
    +exec server.cfg
)

if [[ "$WORKSHOP_ENABLED" == "1" ]]; then
    [[ "$WORKSHOP_COLLECTION" =~ ^[0-9]+$ ]] || {
        echo "Invalid Workshop collection ID in $WORKSHOP_CONF" >&2
        exit 1
    }
    [[ "$WORKSHOP_MAP" =~ ^[0-9]+$ ]] || {
        echo "Invalid Workshop map ID in $WORKSHOP_CONF" >&2
        exit 1
    }

    # Workshop mode replaces the normal +map startup parameter.
    ARGS+=(
        +host_workshop_collection "$WORKSHOP_COLLECTION"
        +host_workshop_map "$WORKSHOP_MAP"
    )
else
    ARGS+=(+map "$START_MAP")
fi

if [[ -n "$GSLT" ]]; then
    ARGS+=(+sv_setsteamaccount "$GSLT")
fi

# CS2 keeps the V8 runtime in game/bin/linuxsteamrt64 while libserver.so
# lives in game/csgo/bin/linuxsteamrt64. Some Linux builds do not resolve
# those V8 dependencies reliably through LD_LIBRARY_PATH alone, so keep
# compatibility symlinks in the csgo module directory as well.
LIB_DIR="$INSTALL_DIR/game/bin/linuxsteamrt64"
CSGO_LIB_DIR="$INSTALL_DIR/game/csgo/bin/linuxsteamrt64"

for lib in "$LIB_DIR"/libv8*.so; do
    [[ -e "$lib" ]] || continue
    ln -sfn "$lib" "$CSGO_LIB_DIR/$(basename "$lib")" 2>/dev/null || true
done

export LD_LIBRARY_PATH="$LIB_DIR:$CSGO_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$INSTALL_DIR/game/bin/linuxsteamrt64/cs2" "${ARGS[@]}"
EOF
    chmod 0755 "$START_SCRIPT"
}

write_workshop_helper() {
    cat > "$WORKSHOP_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/cs2/workshop.conf"
SERVICE="cs2.service"

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
        echo "Please run as root: sudo $0 $*" >&2
        exit 1
    }
}

valid_id() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

load_config() {
    WORKSHOP_ENABLED=0
    WORKSHOP_COLLECTION=""
    WORKSHOP_MAP=""
    if [[ -r "$CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG"
    fi
}

save_config() {
    local enabled="$1" collection="$2" map="$3"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<CFG
WORKSHOP_ENABLED=$enabled
WORKSHOP_COLLECTION=$collection
WORKSHOP_MAP=$map
CFG
    install -m 0644 "$tmp" "$CONFIG"
    rm -f "$tmp"
}

show_status() {
    load_config
    if [[ "$WORKSHOP_ENABLED" == "1" ]]; then
        echo "Workshop mode:       enabled"
        echo "Workshop collection: $WORKSHOP_COLLECTION"
        echo "Workshop start map:  $WORKSHOP_MAP"
    else
        echo "Workshop mode:       disabled"
        echo "The server uses START_MAP from /etc/cs2/runtime.conf."
    fi
}

restart_if_requested() {
    local answer
    read -r -p "Restart CS2 now? [Y/n]: " answer
    answer="${answer:-y}"
    if [[ "$answer" =~ ^[YyJj]$ ]]; then
        systemctl restart "$SERVICE"
        systemctl --no-pager --full status "$SERVICE" || true
    fi
}

enable_workshop() {
    local collection="${1:-}" map="${2:-}"

    if [[ -z "$collection" ]]; then
        read -r -p "Workshop collection ID: " collection
    fi
    if [[ -z "$map" ]]; then
        read -r -p "Workshop start map ID: " map
    fi

    valid_id "$collection" || {
        echo "Invalid Workshop collection ID: $collection" >&2
        exit 2
    }
    valid_id "$map" || {
        echo "Invalid Workshop map ID: $map" >&2
        exit 2
    }

    save_config 1 "$collection" "$map"
    echo "Workshop mode enabled."
    echo "Startup parameters: +host_workshop_collection $collection +host_workshop_map $map"
}

disable_workshop() {
    load_config
    save_config 0 "$WORKSHOP_COLLECTION" "$WORKSHOP_MAP"
    echo "Workshop mode disabled. The normal START_MAP will be used on the next start."
}

usage() {
    cat <<USAGE
Usage:
  sudo cs2-workshop                         Interactive menu
  sudo cs2-workshop enable <collection> <map>
  sudo cs2-workshop disable
  sudo cs2-workshop status

Examples:
  sudo cs2-workshop enable 3791159560 3722688576
  sudo cs2-workshop status
  sudo cs2-workshop disable
USAGE
}

interactive_menu() {
    load_config
    echo "CS2 Workshop helper"
    echo "-------------------"
    show_status
    echo
    echo "1) Enable/update Workshop mode"
    echo "2) Disable Workshop mode"
    echo "3) Show status"
    echo "4) Exit"
    echo
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            enable_workshop
            restart_if_requested
            ;;
        2)
            disable_workshop
            restart_if_requested
            ;;
        3)
            show_status
            ;;
        4)
            exit 0
            ;;
        *)
            echo "Invalid selection." >&2
            exit 2
            ;;
    esac
}

need_root "$@"

case "${1:-}" in
    "")
        interactive_menu
        ;;
    enable)
        [[ $# -le 3 ]] || { usage; exit 2; }
        enable_workshop "${2:-}" "${3:-}"
        restart_if_requested
        ;;
    disable)
        [[ $# -eq 1 ]] || { usage; exit 2; }
        disable_workshop
        restart_if_requested
        ;;
    status)
        [[ $# -eq 1 ]] || { usage; exit 2; }
        show_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
EOF
    chmod 0755 "$WORKSHOP_HELPER"
}

write_rcon_helper() {
    install -d -m 0755 /usr/local/libexec

    cat > "$RCON_HELPER" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import socket
import struct
import sys


def packet(request_id: int, packet_type: int, body: str) -> bytes:
    payload = struct.pack("<ii", request_id, packet_type) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        data = sock.recv(remaining)
        if not data:
            raise ConnectionError("RCON connection closed")
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


def recv_packet(sock: socket.socket):
    length = struct.unpack("<i", recv_exact(sock, 4))[0]
    if length < 10 or length > 4 * 1024 * 1024:
        raise ValueError(f"Invalid RCON packet length: {length}")
    data = recv_exact(sock, length)
    request_id, packet_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, body


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal Source RCON client for CS2")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("command")
    args = parser.parse_args()

    with open(args.password_file, "r", encoding="utf-8") as fh:
        password = fh.read().strip()

    if not password:
        print("RCON password is empty", file=sys.stderr)
        return 2

    auth_id = 1001
    cmd_id = 1002

    with socket.create_connection((args.host, args.port), timeout=args.timeout) as sock:
        sock.settimeout(args.timeout)
        sock.sendall(packet(auth_id, 3, password))

        authenticated = False
        for _ in range(4):
            response_id, response_type, _ = recv_packet(sock)
            if response_id == -1:
                print("RCON authentication failed", file=sys.stderr)
                return 3
            if response_id == auth_id and response_type == 2:
                authenticated = True
                break

        if not authenticated:
            print("No RCON authentication response received", file=sys.stderr)
            return 4

        sock.sendall(packet(cmd_id, 2, args.command))

        try:
            response_id, _, body = recv_packet(sock)
            if response_id == cmd_id and body:
                print(body)
        except socket.timeout:
            # A chat "say" command may not return useful output; the command
            # has already been sent, so a response timeout is not fatal.
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
    chmod 0755 "$RCON_HELPER"
}

write_updater() {
    cat > "$UPDATER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONFIG="/etc/cs2/runtime.conf"
MESSAGE_FILE="/etc/cs2/update-message.txt"
LOCK_FILE="/run/lock/cs2-autoupdate.lock"
RCON_HELPER="/usr/local/libexec/cs2-rcon"

log() {
    echo "[$(date '+%F %T')] $*"
}

[[ -r "$CONFIG" ]] || {
    echo "Missing $CONFIG" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$CONFIG"

MANIFEST="$INSTALL_DIR/steamapps/appmanifest_${APPID}.acf"
RCON_PASSWORD_FILE="$SERVER_HOME/.config/cs2/rcon.password"

ensure_v8_compat_links() {
    local src_dir="$INSTALL_DIR/game/bin/linuxsteamrt64"
    local dst_dir="$INSTALL_DIR/game/csgo/bin/linuxsteamrt64"
    local lib found=0

    install -d -m 0755 -o "$SERVER_USER" -g "$(id -gn "$SERVER_USER")" "$dst_dir"

    for lib in "$src_dir"/libv8*.so; do
        [[ -e "$lib" ]] || continue
        found=1
        ln -sfn "$lib" "$dst_dir/$(basename "$lib")"
    done

    if (( found == 0 )); then
        log "WARNING: No libv8*.so libraries found in $src_dir"
        return 1
    fi

    chown -h "$SERVER_USER:$(id -gn "$SERVER_USER")" "$dst_dir"/libv8*.so 2>/dev/null || true
}

# Refresh the compatibility links on every updater run, even when no new
# CS2 build is available. This also repairs installations affected by the
# Linux libv8.so loading issue.
ensure_v8_compat_links || true

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another update check is already running."
    exit 0
fi

get_local_build() {
    [[ -r "$MANIFEST" ]] || return 1
    awk -F'"' '/"buildid"/ { print $4; exit }' "$MANIFEST"
}

get_remote_build() {
    local tmp build
    tmp="$(mktemp)"

    if ! runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
        "$STEAMCMD" \
        +login anonymous \
        +app_info_update 1 \
        +app_info_print "$APPID" \
        +quit >"$tmp" 2>&1; then
        cat "$tmp" >&2
        rm -f "$tmp"
        return 1
    fi

    build="$(
        awk '
            /"branches"/ { in_branches=1 }
            in_branches && /"public"/ { in_public=1 }
            in_public && /"buildid"/ {
                line=$0
                sub(/^.*"buildid"[[:space:]]*"/, "", line)
                sub(/".*$/, "", line)
                print line
                exit
            }
        ' "$tmp"
    )"

    rm -f "$tmp"

    [[ "$build" =~ ^[0-9]+$ ]] || {
        log "Could not read remote build ID from SteamCMD." >&2
        return 1
    }

    printf '%s\n' "$build"
}

rcon_say() {
    local message="$1"
    local rcon_host="$BIND_IP"

    # 0.0.0.0 is valid for binding/listening, but it is not a proper
    # destination address for an outgoing RCON connection. Use loopback
    # when CS2 listens on all interfaces.
    if [[ "$rcon_host" == "0.0.0.0" ]]; then
        rcon_host="127.0.0.1"
    fi

    if [[ ! -x "$RCON_HELPER" || ! -r "$RCON_PASSWORD_FILE" ]]; then
        log "RCON is unavailable; warning '$message' could not be sent."
        return 0
    fi

    if ! runuser -u "$SERVER_USER" -- \
        "$RCON_HELPER" \
        --host "$rcon_host" \
        --port "$PORT" \
        --password-file "$RCON_PASSWORD_FILE" \
        "say $message" >/dev/null 2>&1; then
        log "Could not send RCON warning: $message"
    else
        log "RCON: $message"
    fi
}

LOCAL_BUILD="$(get_local_build || true)"
[[ "$LOCAL_BUILD" =~ ^[0-9]+$ ]] || {
    log "Could not determine local build ID: $MANIFEST"
    exit 1
}

REMOTE_BUILD="$(get_remote_build || true)"
[[ "$REMOTE_BUILD" =~ ^[0-9]+$ ]] || exit 1

log "Local: $LOCAL_BUILD | Steam public: $REMOTE_BUILD"

if [[ "$LOCAL_BUILD" == "$REMOTE_BUILD" ]]; then
    log "CS2 is up to date."
    exit 0
fi

log "CS2 update detected."

if systemctl is-active --quiet cs2.service; then
    if [[ -r "$MESSAGE_FILE" ]]; then
        FIRST_MESSAGE="$(head -n 1 "$MESSAGE_FILE")"
    else
        FIRST_MESSAGE="CS2 Released an Update - Restart in 5 minutes"
    fi

    rcon_say "$FIRST_MESSAGE"
    sleep 240

    rcon_say "Server restart for CS2 update in 1 minute"
    sleep 30

    rcon_say "Server restart in 30 seconds"
    sleep 20

    rcon_say "Server restart in 10 seconds"
    sleep 10
else
    log "CS2 is not running; skipping 5-minute countdown."
fi

# The build ID may have changed again during the countdown.
LATEST_REMOTE_BUILD="$(get_remote_build || true)"
if [[ "$LATEST_REMOTE_BUILD" =~ ^[0-9]+$ ]]; then
    REMOTE_BUILD="$LATEST_REMOTE_BUILD"
fi

log "Stopping CS2."
systemctl stop cs2.service || true

log "Installing CS2 update to build $REMOTE_BUILD."
if ! runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
    "$STEAMCMD" \
    +force_install_dir "$INSTALL_DIR" \
    +login anonymous \
    +app_update "$APPID" \
    +quit; then
    log "SteamCMD update failed. Attempting to start the server again."
    systemctl start cs2.service || true
    exit 1
fi

NEW_LOCAL_BUILD="$(get_local_build || true)"
log "Local build ID after update: ${NEW_LOCAL_BUILD:-unknown}"

ensure_v8_compat_links || true

log "Starting CS2."
systemctl start cs2.service

sleep 5

if systemctl is-active --quiet cs2.service; then
    log "CS2 is running again."
else
    log "ERROR: cs2.service is not active after the update."
    systemctl status cs2.service --no-pager || true
    exit 1
fi
EOF
    chmod 0750 "$UPDATER_SCRIPT"
}

write_systemd_units() {
    info "Setting up systemd services"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Counter-Strike 2 Dedicated Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVER_USER
Group=$SERVER_GROUP
WorkingDirectory=$INSTALL_DIR
ExecStart=$START_SCRIPT
Restart=on-failure
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=60
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=Check and install Counter-Strike 2 server updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER_SCRIPT
EOF

    cat > "$UPDATE_TIMER_FILE" <<EOF
[Unit]
Description=Check Counter-Strike 2 updates every $UPDATE_INTERVAL_MINUTES minutes

[Timer]
OnBootSec=2min
OnUnitInactiveSec=${UPDATE_INTERVAL_MINUTES}min
AccuracySec=15s
Persistent=true
Unit=cs2-autoupdate.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable cs2.service
    systemctl enable --now cs2-autoupdate.timer
}

finish() {
    echo
    echo "============================================================"
    echo "CS2 installation completed"
    echo "============================================================"
    echo "User:          $SERVER_USER"
    echo "Install dir:   $INSTALL_DIR"
    echo "Bind IP:       $BIND_IP"
    echo "Port:          $PORT/UDP (Game) + $PORT/TCP (RCON)"
    echo "Slots:         $MAXPLAYERS"
    echo "Start map:     $START_MAP"
    echo "game_type:     $GAME_TYPE"
    echo "game_mode:     $GAME_MODE"
    echo "Update check:  every $UPDATE_INTERVAL_MINUTES minutes"
    echo
    echo "Important commands:"
    echo "  systemctl start cs2"
    echo "  systemctl stop cs2"
    echo "  systemctl restart cs2"
    echo "  systemctl status cs2"
    echo "  journalctl -fu cs2"
    echo
    echo "Workshop helper:"
    echo "  cs2-workshop"
    echo "  cs2-workshop enable 3791159560 3722688576"
    echo "  cs2-workshop status"
    echo "  cs2-workshop disable"
    echo
    echo "Updater:"
    echo "  systemctl status cs2-autoupdate.timer"
    echo "  systemctl start cs2-autoupdate.service"
    echo "  journalctl -u cs2-autoupdate.service"
    echo
    echo "Config:"
    echo "  $INSTALL_DIR/game/csgo/cfg/server.cfg"
    echo
    echo "Firewall/NAT:"
    echo "  Open/forward $PORT/udp for the game."
    echo "  $PORT/tcp is required for RCON; externally, you should restrict RCON if possible"
    echo "  via firewall to trusted IP addresses."
    echo
    if [[ -z "$GSLT" ]]; then
        echo "NOTE: No GSLT was configured."
        echo "Add it later to $SECRET_DIR/gslt.token and then run:"
        echo "  systemctl restart cs2"
        echo
    fi
    echo "RCON password:"
    echo "  $RCON_PASSWORD"
    echo
    echo "Please store the password securely now. It is also stored in server.cfg"
    echo "and protected in $SECRET_DIR/rcon.password."
    echo

    if [[ "$START_NOW" == "yes" ]]; then
        info "Starting CS2"
        systemctl restart cs2.service
        sleep 3
        systemctl --no-pager --full status cs2.service || true
    else
        echo "The server has not been started yet."
        echo "Start: systemctl start cs2"
    fi
}

main() {
    require_root
    check_platform
    collect_settings
    install_packages
    create_user
    install_steamcmd
    install_cs2
    install_v8_compat_links
    install_steam_sdk_links
    write_runtime_config
    write_start_script
    write_workshop_helper
    write_rcon_helper
    write_updater
    write_systemd_units
    finish
}

main "$@"
