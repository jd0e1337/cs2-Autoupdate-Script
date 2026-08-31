#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APPID="730"
CONFIG_DIR="/etc/cs2"
RUNTIME_CONF="$CONFIG_DIR/runtime.conf"
UPDATE_MESSAGE_FILE="$CONFIG_DIR/update-message.txt"
START_SCRIPT="/usr/local/bin/cs2-start"
RCON_HELPER="/usr/local/libexec/cs2-rcon"
UPDATER_SCRIPT="/usr/local/sbin/cs2-autoupdate"
SERVICE_FILE="/etc/systemd/system/cs2.service"
UPDATE_SERVICE_FILE="/etc/systemd/system/cs2-autoupdate.service"
UPDATE_TIMER_FILE="/etc/systemd/system/cs2-autoupdate.timer"

die() {
    echo "FEHLER: $*" >&2
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

cfg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Bitte als root ausführen: sudo $0"
}

check_platform() {
    [[ "$(uname -s)" == "Linux" ]] || die "Dieses Script ist nur für Linux gedacht."

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "Dieses Script unterstützt aktuell nur x86_64/amd64." ;;
    esac

    [[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu) ;;
        *)
            if [[ "${ID_LIKE:-}" != *debian* ]]; then
                die "Unterstützt werden Debian/Ubuntu bzw. Debian-basierte Systeme."
            fi
            ;;
    esac
}

collect_settings() {
    echo "CS2 Dedicated Server Installer"
    echo "------------------------------"
    echo "Voreinstellung: 16-Slot Deathmatch, Port 27015, Update-Check alle 5 Minuten."
    echo

    SERVER_USER="$(ask "Linux-Benutzer für den CS2-Server" "steam")"
    [[ "$SERVER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Ungültiger Linux-Benutzername."

    if id "$SERVER_USER" >/dev/null 2>&1; then
        SERVER_HOME="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
        [[ -n "$SERVER_HOME" ]] || die "Home-Verzeichnis für $SERVER_USER konnte nicht ermittelt werden."
    else
        SERVER_HOME="/home/$SERVER_USER"
    fi

    [[ "$SERVER_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Das Home-Verzeichnis enthält nicht unterstützte Zeichen: $SERVER_HOME"

    INSTALL_DIR="$(ask "CS2 Installationsverzeichnis" "$SERVER_HOME/cs2")"
    [[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]         || die "Installationspfad muss absolut sein und darf nur Buchstaben, Zahlen, /, ., _ und - enthalten."

    HOSTNAME_VALUE="$(ask "Servername" "My CS2 Deathmatch")"

    PORT="$(ask "Game/RCON-Port" "27015")"
    valid_uint "$PORT" && (( PORT >= 1 && PORT <= 65535 )) || die "Ungültiger Port."

    MAXPLAYERS="$(ask "Maximale Slots" "16")"
    valid_uint "$MAXPLAYERS" && (( MAXPLAYERS >= 1 && MAXPLAYERS <= 64 )) || die "Slots müssen zwischen 1 und 64 liegen."

    echo
    echo "Spielmodus:"
    echo "  1) Deathmatch   (game_type 1 / game_mode 2)"
    echo "  2) Competitive  (0 / 1)"
    echo "  3) Casual       (0 / 0)"
    echo "  4) Eigene Werte"
    MODE_CHOICE="$(ask "Auswahl" "1")"

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
            valid_uint "$GAME_TYPE" || die "game_type muss numerisch sein."
            valid_uint "$GAME_MODE" || die "game_mode muss numerisch sein."
            ;;
        *)
            die "Ungültige Modus-Auswahl."
            ;;
    esac

    START_MAP="$(ask "Start-Map" "de_dust2")"
    [[ "$START_MAP" =~ ^[A-Za-z0-9_./-]+$ ]] || die "Ungültiger Map-Name."

    echo
    echo "GSLT wird für einen öffentlichen CS2-Server benötigt (App ID 730)."
    read -r -s -p "GSLT (leer lassen für später/LAN): " GSLT
    echo

    echo
    read -r -s -p "RCON-Passwort (leer = automatisch erzeugen): " RCON_PASSWORD
    echo
    if [[ -z "$RCON_PASSWORD" ]]; then
        RCON_PASSWORD="$(openssl rand -hex 24 2>/dev/null || true)"
        if [[ -z "$RCON_PASSWORD" ]]; then
            RCON_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
        fi
        echo "RCON-Passwort wurde automatisch erzeugt."
    fi
    [[ "$RCON_PASSWORD" != *$'\n'* && "$RCON_PASSWORD" != *$'\r'* ]] || die "RCON-Passwort darf keinen Zeilenumbruch enthalten."

    read -r -s -p "Server-Passwort (leer = öffentlich): " SV_PASSWORD
    echo
    [[ "$SV_PASSWORD" != *$'\n'* && "$SV_PASSWORD" != *$'\r'* ]] || die "Server-Passwort darf keinen Zeilenumbruch enthalten."

    UPDATE_INTERVAL_MINUTES="$(ask "Update-Check alle wie viele Minuten?" "5")"
    valid_uint "$UPDATE_INTERVAL_MINUTES" && (( UPDATE_INTERVAL_MINUTES >= 1 && UPDATE_INTERVAL_MINUTES <= 1440 )) \
        || die "Update-Intervall muss zwischen 1 und 1440 Minuten liegen."

    UPDATE_MESSAGE="$(ask "5-Minuten-RCON-Nachricht" "CS2 Released an Update - Restart in 5 minutes")"
    UPDATE_MESSAGE="${UPDATE_MESSAGE//$'\r'/}"
    UPDATE_MESSAGE="${UPDATE_MESSAGE//$'\n'/ }"

    START_NOW="no"
    if ask_yes_no "Server nach der Installation direkt starten?" "y"; then
        START_NOW="yes"
    fi
}

install_packages() {
    info "Installiere benötigte Pakete"
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
        info "Benutzer $SERVER_USER existiert bereits"
    else
        info "Lege Benutzer $SERVER_USER an"
        useradd --create-home --home-dir "$SERVER_HOME" --shell /bin/bash "$SERVER_USER"
    fi

    SERVER_HOME="$(getent passwd "$SERVER_USER" | cut -d: -f6)"
    SERVER_GROUP="$(id -gn "$SERVER_USER")"
    [[ -n "$SERVER_HOME" ]] || die "Home-Verzeichnis konnte nicht ermittelt werden."

    STEAMCMD_DIR="$SERVER_HOME/steamcmd"
    STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
    SECRET_DIR="$SERVER_HOME/.config/cs2"
}

install_steamcmd() {
    info "Installiere/aktualisiere SteamCMD"

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
    info "Installiere/aktualisiere Counter-Strike 2 (App ID $APPID)"

    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_GROUP" "$INSTALL_DIR"

    local manifest="$INSTALL_DIR/steamapps/appmanifest_${APPID}.acf"

    if systemctl is-active --quiet cs2.service 2>/dev/null; then
        systemctl stop cs2.service
    fi

    if [[ -f "$manifest" ]]; then
        echo "Bestehende Installation erkannt: normales app_update ohne validate."
        runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
            "$STEAMCMD" \
            +force_install_dir "$INSTALL_DIR" \
            +login anonymous \
            +app_update "$APPID" \
            +quit
    else
        echo "Neuinstallation erkannt: erster Download mit validate."
        runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
            "$STEAMCMD" \
            +force_install_dir "$INSTALL_DIR" \
            +login anonymous \
            +app_update "$APPID" validate \
            +quit
    fi

    [[ -x "$INSTALL_DIR/game/bin/linuxsteamrt64/cs2" ]] \
        || die "CS2-Binary wurde nicht gefunden: $INSTALL_DIR/game/bin/linuxsteamrt64/cs2"
}

install_steam_sdk_links() {
    info "Richte Steam-SDK-Libraries ein"

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
    info "Schreibe Konfiguration"

    install -d -m 0755 "$CONFIG_DIR"
    install -d -m 0700 -o "$SERVER_USER" -g "$SERVER_GROUP" "$SECRET_DIR"

    cat > "$RUNTIME_CONF" <<EOF
APPID=$APPID
SERVER_USER=$SERVER_USER
SERVER_HOME=$SERVER_HOME
INSTALL_DIR=$INSTALL_DIR
STEAMCMD=$STEAMCMD
PORT=$PORT
MAXPLAYERS=$MAXPLAYERS
START_MAP=$START_MAP
GAME_TYPE=$GAME_TYPE
GAME_MODE=$GAME_MODE
EOF
    chmod 0644 "$RUNTIME_CONF"

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

GSLT_FILE="$SERVER_HOME/.config/cs2/gslt.token"
GSLT=""
if [[ -r "$GSLT_FILE" ]]; then
    GSLT="$(<"$GSLT_FILE")"
fi

ARGS=(
    -dedicated
    -console
    -usercon
    -port "$PORT"
    -maxplayers_override "$MAXPLAYERS"
    +game_type "$GAME_TYPE"
    +game_mode "$GAME_MODE"
    +map "$START_MAP"
    +exec server.cfg
)

if [[ -n "$GSLT" ]]; then
    ARGS+=(+sv_setsteamaccount "$GSLT")
fi

exec "$INSTALL_DIR/game/bin/linuxsteamrt64/cs2" "${ARGS[@]}"
EOF
    chmod 0755 "$START_SCRIPT"
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

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Ein anderer Update-Check läuft bereits."
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
        log "Remote Build-ID konnte nicht aus SteamCMD gelesen werden." >&2
        return 1
    }

    printf '%s\n' "$build"
}

rcon_say() {
    local message="$1"

    if [[ ! -x "$RCON_HELPER" || ! -r "$RCON_PASSWORD_FILE" ]]; then
        log "RCON ist nicht verfügbar; Warnung '$message' konnte nicht gesendet werden."
        return 0
    fi

    if ! runuser -u "$SERVER_USER" -- \
        "$RCON_HELPER" \
        --host 127.0.0.1 \
        --port "$PORT" \
        --password-file "$RCON_PASSWORD_FILE" \
        "say $message" >/dev/null 2>&1; then
        log "RCON-Warnung konnte nicht gesendet werden: $message"
    else
        log "RCON: $message"
    fi
}

LOCAL_BUILD="$(get_local_build || true)"
[[ "$LOCAL_BUILD" =~ ^[0-9]+$ ]] || {
    log "Lokale Build-ID konnte nicht ermittelt werden: $MANIFEST"
    exit 1
}

REMOTE_BUILD="$(get_remote_build || true)"
[[ "$REMOTE_BUILD" =~ ^[0-9]+$ ]] || exit 1

log "Lokal: $LOCAL_BUILD | Steam public: $REMOTE_BUILD"

if [[ "$LOCAL_BUILD" == "$REMOTE_BUILD" ]]; then
    log "CS2 ist aktuell."
    exit 0
fi

log "CS2-Update erkannt."

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
    log "CS2 läuft nicht; überspringe 5-Minuten-Countdown."
fi

# Die Build-ID könnte sich während des Countdowns erneut geändert haben.
LATEST_REMOTE_BUILD="$(get_remote_build || true)"
if [[ "$LATEST_REMOTE_BUILD" =~ ^[0-9]+$ ]]; then
    REMOTE_BUILD="$LATEST_REMOTE_BUILD"
fi

log "Stoppe CS2."
systemctl stop cs2.service || true

log "Installiere CS2-Update auf Build $REMOTE_BUILD."
if ! runuser -u "$SERVER_USER" -- env HOME="$SERVER_HOME" \
    "$STEAMCMD" \
    +force_install_dir "$INSTALL_DIR" \
    +login anonymous \
    +app_update "$APPID" \
    +quit; then
    log "SteamCMD-Update fehlgeschlagen. Versuche den Server wieder zu starten."
    systemctl start cs2.service || true
    exit 1
fi

NEW_LOCAL_BUILD="$(get_local_build || true)"
log "Lokale Build-ID nach Update: ${NEW_LOCAL_BUILD:-unbekannt}"

log "Starte CS2."
systemctl start cs2.service

sleep 5

if systemctl is-active --quiet cs2.service; then
    log "CS2 läuft wieder."
else
    log "FEHLER: cs2.service ist nach dem Update nicht aktiv."
    systemctl status cs2.service --no-pager || true
    exit 1
fi
EOF
    chmod 0750 "$UPDATER_SCRIPT"
}

write_systemd_units() {
    info "Richte systemd-Services ein"

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
    echo "CS2 Installation abgeschlossen"
    echo "============================================================"
    echo "User:          $SERVER_USER"
    echo "Install dir:   $INSTALL_DIR"
    echo "Port:          $PORT/UDP (Game) + $PORT/TCP (RCON)"
    echo "Slots:         $MAXPLAYERS"
    echo "Start map:     $START_MAP"
    echo "game_type:     $GAME_TYPE"
    echo "game_mode:     $GAME_MODE"
    echo "Update check:  alle $UPDATE_INTERVAL_MINUTES Minuten"
    echo
    echo "Wichtige Befehle:"
    echo "  systemctl start cs2"
    echo "  systemctl stop cs2"
    echo "  systemctl restart cs2"
    echo "  systemctl status cs2"
    echo "  journalctl -fu cs2"
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
    echo "  Öffne/forwarde $PORT/udp für das Spiel."
    echo "  $PORT/tcp wird für RCON benötigt; extern solltest du RCON nach Möglichkeit"
    echo "  per Firewall auf vertrauenswürdige IPs beschränken."
    echo
    if [[ -z "$GSLT" ]]; then
        echo "HINWEIS: Es wurde kein GSLT gesetzt."
        echo "Später in $SECRET_DIR/gslt.token eintragen und anschließend:"
        echo "  systemctl restart cs2"
        echo
    fi
    echo "RCON-Passwort:"
    echo "  $RCON_PASSWORD"
    echo
    echo "Bitte das Passwort jetzt sicher speichern. Es steht außerdem in server.cfg"
    echo "und geschützt in $SECRET_DIR/rcon.password."
    echo

    if [[ "$START_NOW" == "yes" ]]; then
        info "Starte CS2"
        systemctl restart cs2.service
        sleep 3
        systemctl --no-pager --full status cs2.service || true
    else
        echo "Der Server wurde noch nicht gestartet."
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
    install_steam_sdk_links
    write_runtime_config
    write_start_script
    write_rcon_helper
    write_updater
    write_systemd_units
    finish
}

main "$@"
