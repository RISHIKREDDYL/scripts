#!/bin/bash
set -euo pipefail

# ============================================================
# setup_mediastack.sh
# One-shot media server setup for Ubuntu 24.04
# Installs: qBittorrent-nox, Radarr, Sonarr, Prowlarr, Jellyfin
# ============================================================

SCRIPT_VERSION="1.0.0"

# ---- Configurable variables ---------------------------------
QBITTORRENT_WEBUI_PORT="${QBITTORRENT_WEBUI_PORT:-8080}"
RADARR_PORT="${RADARR_PORT:-7878}"
SONARR_PORT="${SONARR_PORT:-8989}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"
JELLYFIN_PORT="${JELLYFIN_PORT:-8096}"

QBITTORRENT_VERSION="${QBITTORRENT_VERSION:-}"
RADARR_VERSION="${RADARR_VERSION:-6.1.1.10360}"
SONARR_VERSION="${SONARR_VERSION:-4.0.17.2952}"
PROWLARR_VERSION="${PROWLARR_VERSION:-2.3.5.5327}"

DOWNLOAD_BASE="/home/qbtuser/Downloads"
MEDIA_GROUP="media"

# ---- Colors -------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
NC='\033[0m' # No Color
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*" >&2; }

# ---- Sanity checks ------------------------------------------
check_sanity() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
    if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        warn "This script is designed for Ubuntu/Debian. Proceeding anyway..."
    fi
    if ! command -v apt &>/dev/null; then
        err "apt not found. This script requires a Debian-based system."
        exit 1
    fi
}

# ---- Helper: create user if not exists -----------------------
ensure_user() {
    local user="$1"
    local home="$2"
    local groups="$3"
    if id "$user" &>/dev/null; then
        log "User '$user' already exists, skipping creation."
    else
        useradd --system --no-create-home --home-dir "$home" --shell /bin/false "$user"
        log "Created system user '$user'."
    fi
    if [[ -n "$groups" ]]; then
        IFS=',' read -ra garr <<< "$groups"
        for g in "${garr[@]}"; do
            if getent group "$g" &>/dev/null; then
                usermod -aG "$g" "$user"
            fi
        done
    fi
    if [[ -d "$home" ]]; then
        chown -R "$user:$user" "$home" 2>/dev/null || true
    fi
}

# ---- Helper: download & extract tarball ----------------------
install_tarball() {
    local name="$1"       # e.g. "Radarr"
    local version="$2"
    local url="$3"
    local target_dir="/opt/${name}"
    local user="$4"

    if [[ -f "${target_dir}/${name}" ]] || [[ -f "${target_dir}/${name}.dll" ]]; then
        log "${name} already installed at ${target_dir}, skipping."
        return 0
    fi

    local archive="/tmp/${name,,}.tar.gz"
    log "Downloading ${name} ${version}..."
    curl -fsSL "$url" -o "$archive"
    log "Extracting ${name} to ${target_dir}..."
    mkdir -p "$target_dir"
    tar xzf "$archive" -C "/opt/"
    chown -R "${user}:${user}" "$target_dir"
    rm -f "$archive"
    log "${name} installed successfully."
}

# ---- Helper: create systemd service --------------------------
install_systemd_service() {
    local name="$1"          # service name
    local user="$2"
    local group="$3"
    local exec_start="$4"
    local description="$5"
    local extra_lines="${6:-}"

    local service_file="/etc/systemd/system/${name}.service"
    if [[ -f "$service_file" ]]; then
        log "Systemd service '${name}' already exists, skipping."
        return 0
    fi

    cat > "$service_file" <<SERVICEEOF
[Unit]
Description=${description}
After=network.target

[Service]
Type=simple
User=${user}
Group=${group}
UMask=0002
ExecStart=${exec_start}
TimeoutStopSec=20
KillMode=process
Restart=on-failure
RestartSec=10
${extra_lines}

[Install]
WantedBy=multi-user.target
SERVICEEOF
    log "Created systemd service '${name}'."
}

# ============================================================
# PHASE 1: System Preparation
# ============================================================
phase1_system_prep() {
    log "==== Phase 1: System Preparation ===="
    apt update && apt upgrade -y
    apt install -y curl wget gnupg ca-certificates tzdata

    getent group "$MEDIA_GROUP" &>/dev/null || groupadd "$MEDIA_GROUP"
    log "Ensured group '${MEDIA_GROUP}' exists."

    # Service users
    ensure_user "prowlarr"  "/home/prowlarr"   "$MEDIA_GROUP"
    ensure_user "radarr"    "/home/radarr"     "$MEDIA_GROUP"
    ensure_user "sonarr"    "/var/lib/sonarr"  "$MEDIA_GROUP"
    ensure_user "qbtuser"   "/home/qbtuser"    "$MEDIA_GROUP"
    ensure_user "jellyfin"  "/var/lib/jellyfin" "$MEDIA_GROUP"

    log "Phase 1 complete."
}

# ============================================================
# PHASE 2: qBittorrent-nox
# ============================================================
phase2_qbittorrent() {
    log "==== Phase 2: qBittorrent-nox ===="
    if command -v qbittorrent-nox &>/dev/null; then
        log "qBittorrent-nox already installed, skipping apt install."
    else
        apt install -y qbittorrent-nox
    fi

    # Create download directories
    mkdir -p "$DOWNLOAD_BASE"/{movies,tv}
    chown -R qbtuser:qbtuser "$DOWNLOAD_BASE"

    # systemd service
    if [[ ! -f "/etc/systemd/system/qbittorrent.service" ]]; then
        cat > /etc/systemd/system/qbittorrent.service <<SERVICEEOF
[Unit]
Description=qBittorrent-nox service
After=network.target

[Service]
Type=simple
User=qbtuser
Group=qbtuser
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

        mkdir -p /etc/systemd/system/qbittorrent.service.d
        cat > /etc/systemd/system/qbittorrent.service.d/umask.conf <<'UMASKEOF'
[Service]
UMask=0002
UMASKEOF
        log "Created systemd service 'qbittorrent'."
    else
        log "qbittorrent systemd service already exists."
    fi

    # Write config (only if not already present, to avoid overwriting)
    local qbt_conf="/home/qbtuser/.config/qBittorrent/qBittorrent.conf"
    if [[ ! -f "$qbt_conf" ]]; then
        mkdir -p "$(dirname "$qbt_conf")"
        cat > "$qbt_conf" <<QBTEOF
[Application]
FileLogger\Age=1
FileLogger\AgeType=1
FileLogger\Backup=true
FileLogger\DeleteOld=true
FileLogger\Enabled=true
FileLogger\MaxSizeBytes=66560
FileLogger\Path=/home/qbtuser/.local/share/qBittorrent/logs

[BitTorrent]
Session\AlternativeGlobalDLSpeedLimit=0
Session\AlternativeGlobalUPSpeedLimit=0
Session\DHTEnabled=true
Session\Encryption=1
Session\ExcludedFileNames=
Session\LSDEnabled=true
Session\PEXEnabled=true
Session\Port=56830
Session\QueueingSystemEnabled=true
Session\UPnPEnabled=true

[Core]
AutoDeleteAddedTorrentFile=Never

[LegalNotice]
Accepted=true

[Meta]
MigrationVersion=6

[Preferences]
General\Locale=en
MailNotification\req_auth=true

[WebUI]
LocalHostAuth=0
Port\Port=${QBITTORRENT_WEBUI_PORT}
QBTEOF
        chown -R qbtuser:qbtuser /home/qbtuser/.config
        log "qBittorrent config written."
    else
        log "qBittorrent config already exists, skipping."
    fi

    log "Phase 2 complete."
}

# ============================================================
# PHASE 3: Radarr
# ============================================================
phase3_radarr() {
    log "==== Phase 3: Radarr ===="
    local name="Radarr"
    local user="radarr"
    local target_dir="/opt/${name}"
    local data_dir="/var/lib/radarr"

    if [[ -z "$RADARR_VERSION" ]]; then
        RADARR_VERSION=$(curl -s "https://api.github.com/repos/Radarr/Radarr/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
    fi
    local version="${RADARR_VERSION#v}"

    install_tarball "$name" "$version" \
        "https://github.com/Radarr/Radarr/releases/download/v${version}/Radarr.master.${version}.linux-core-x64.tar.gz" \
        "$user"

    mkdir -p "$data_dir"
    chown -R "${user}:${user}" "$data_dir"

    if [[ ! -L "/usr/bin/radarr" ]]; then
        ln -sf "${target_dir}/Radarr" /usr/bin/radarr
        log "Created symlink /usr/bin/radarr -> ${target_dir}/Radarr"
    fi

    local svc_name="${name,,}"
    install_systemd_service "$svc_name" "$user" "$user" \
        "/opt/Radarr/Radarr -nobrowser -data=${data_dir}" \
        "Radarr Daemon"

    log "Phase 3 complete."
}

# ============================================================
# PHASE 4: Sonarr
# ============================================================
phase4_sonarr() {
    log "==== Phase 4: Sonarr ===="
    local name="Sonarr"
    local user="sonarr"
    local target_dir="/opt/${name}"
    local data_dir="/var/lib/sonarr"

    if [[ -z "$SONARR_VERSION" ]]; then
        SONARR_VERSION=$(curl -s "https://api.github.com/repos/Sonarr/Sonarr/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
    fi
    local version="${SONARR_VERSION#v}"

    install_tarball "$name" "$version" \
        "https://github.com/Sonarr/Sonarr/releases/download/v${version}/Sonarr.main.${version}.linux-core-x64.tar.gz" \
        "$user"

    mkdir -p "$data_dir"
    chown -R "${user}:${user}" "$data_dir"

    local svc_name="${name,,}"
    install_systemd_service "$svc_name" "$user" "$user" \
        "/opt/Sonarr/Sonarr -nobrowser -data=${data_dir}" \
        "Sonarr Daemon"

    log "Phase 4 complete."
}

# ============================================================
# PHASE 5: Prowlarr
# ============================================================
phase5_prowlarr() {
    log "==== Phase 5: Prowlarr ===="
    local name="Prowlarr"
    local user="prowlarr"
    local target_dir="/opt/${name}"
    local data_dir="/var/lib/prowlarr"

    if [[ -z "$PROWLARR_VERSION" ]]; then
        PROWLARR_VERSION=$(curl -s "https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
    fi
    local version="${PROWLARR_VERSION#v}"

    install_tarball "$name" "$version" \
        "https://github.com/Prowlarr/Prowlarr/releases/download/v${version}/Prowlarr.master.${version}.linux-core-x64.tar.gz" \
        "$user"

    mkdir -p "$data_dir"
    chown -R "${user}:${user}" "$data_dir"

    local svc_name="${name,,}"
    install_systemd_service "$svc_name" "$user" "$user" \
        "/opt/Prowlarr/Prowlarr -nobrowser -data=${data_dir}" \
        "Prowlarr Daemon"

    log "Phase 5 complete."
}

# ============================================================
# PHASE 6: Jellyfin
# ============================================================
phase6_jellyfin() {
    log "==== Phase 6: Jellyfin ===="
    if command -v jellyfin &>/dev/null; then
        log "Jellyfin already installed, skipping apt install."
    else
        # Add Jellyfin repo
        local keyring="/usr/share/keyrings/jellyfin.gpg"
        if [[ ! -f "$keyring" ]]; then
            curl -fsSL "https://repo.jellyfin.org/jellyfin.asc" | gpg --dearmor -o "$keyring"
        fi
        local codename
        codename=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release 2>/dev/null || echo "noble")
        if [[ ! -f "/etc/apt/sources.list.d/jellyfin.sources" ]]; then
            cat > /etc/apt/sources.list.d/jellyfin.sources <<SRCEOF
Types: deb
URIs: https://repo.jellyfin.org/ubuntu
Suites: ${codename}
Components: main
Architectures: amd64
Signed-By: ${keyring}
SRCEOF
        fi
        apt update
        apt install -y jellyfin jellyfin-ffmpeg
    fi

    # Add jellyfin user to media group
    usermod -aG "$MEDIA_GROUP" jellyfin 2>/dev/null || true

    log "Phase 6 complete."
}

# ============================================================
# PHASE 7: Finalize
# ============================================================
phase7_finalize() {
    log "==== Phase 7: Finalize ===="
    systemctl daemon-reload

    local services=("qbittorrent" "radarr" "sonarr" "prowlarr" "jellyfin")
    for svc in "${services[@]}"; do
        systemctl enable "$svc" 2>/dev/null || true
        if systemctl is-active --quiet "$svc"; then
            log "${svc} is running."
        else
            systemctl start "$svc" 2>/dev/null || warn "Could not start ${svc} (may need config)."
        fi
    done

    log ""
    log "============================================"
    log " Setup complete!"
    log "============================================"
    log ""
    log " Access your services:"
    log "   qBittorrent: http://$(hostname -I | awk '{print $1}'):${QBITTORRENT_WEBUI_PORT}"
    log "   Radarr:      http://$(hostname -I | awk '{print $1}'):${RADARR_PORT}"
    log "   Sonarr:      http://$(hostname -I | awk '{print $1}'):${SONARR_PORT}"
    log "   Prowlarr:    http://$(hostname -I | awk '{print $1}'):${PROWLARR_PORT}"
    log "   Jellyfin:    http://$(hostname -I | awk '{print $1}'):${JELLYFIN_PORT}"
    log ""
    log " Data directories:"
    log "   Downloads:  ${DOWNLOAD_BASE}/"
    log "   Radarr:     /var/lib/radarr/"
    log "   Sonarr:     /var/lib/sonarr/"
    log "   Prowlarr:   /var/lib/prowlarr/"
    log "   Jellyfin:   /var/lib/jellyfin/"
    log ""
    log " qBittorrent default creds: admin / adminadmin"
    log " All other services: configure via web UI on first visit."
    log "============================================"
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo "  setup_mediastack.sh v${SCRIPT_VERSION}"
    echo "  Media Server Setup for Ubuntu 24.04"
    echo "  ---------------------------------------"
    echo ""

    check_sanity
    phase1_system_prep
    phase2_qbittorrent
    phase3_radarr
    phase4_sonarr
    phase5_prowlarr
    phase6_jellyfin
    phase7_finalize
}

main "$@"
