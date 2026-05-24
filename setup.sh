#!/usr/bin/env bash
# ============================================================
#  DNS Tunnel Kit — Multi-Tunnel Setup Script
#  Supports: MasterDnsVPN + Slipstream + dnstt + VayDNS + StormDNS
#  Credits : https://github.com/mrvcoder
# ============================================================

set -euo pipefail

# ════════════════════════════════════════════════════════════
#  DEFAULTS (overridable via env vars or interactive menu)
# ════════════════════════════════════════════════════════════

SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"

TUNNEL_USER="${TUNNEL_USER:-}"
TUNNEL_PASS="${TUNNEL_PASS:-}"

MDNS_DOMAIN="${MDNS_DOMAIN:-a.example.com}"
SLIP_DOMAIN="${SLIP_DOMAIN:-b.example.com}"
DNSTT_DOMAIN="${DNSTT_DOMAIN:-c.example.com}"
VAYDNS_DOMAIN="${VAYDNS_DOMAIN:-d.example.com}"
STORMDNS_DOMAIN="${STORMDNS_DOMAIN:-e.example.com}"

MDNS_INSTALL_DIR="/opt/masterdnsvpn"
MDNS_PORT="5312"
MDNS_ENCRYPTION="2"   # 2=ChaCha20

SLIP_CERT_DIR="/etc/dnstm/tunnels/slip-socks"
SLIP_PORT="5310"

DNSTT_PORT="5313"
DNSTT_KEY_DIR="/opt/dnstt"

VAYDNS_PORT="5314"
VAYDNS_KEY_DIR="/opt/vaydns"

STORMDNS_PORT="5315"
STORMDNS_INSTALL_DIR="/opt/stormdns"
STORMDNS_ENCRYPTION="2"   # 2=ChaCha20 (matches MasterDnsVPN default)

SOCKS_PORT="58076"        # private/internal microsocks
SOCKS_SLIP_PORT="58077"   # public/Slipstream microsocks
SOCKS_NOAUTH_PORT="58078" # dnstt no-auth backend
SSLH_MUX_PORT="59000"     # sslh protocol multiplexer (SSH+SOCKS5)

DNSTM_CONFIG="/etc/dnstm/config.json"
MDNS_GH_BASE="https://github.com/masterking32/MasterDnsVPN/releases/latest/download"

# Cloudflare DNS auto-provisioning (optional)
# Either a scoped API token (preferred) OR global API key + email.
CF_API_TOKEN="${CF_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
CF_EMAIL="${CF_EMAIL:-${CLOUDFLARE_EMAIL:-}}"
CF_API_KEY="${CF_API_KEY:-${CLOUDFLARE_API_KEY:-}}"
CF_NS_GLUE_LABEL="${CF_NS_GLUE_LABEL:-dns}"   # shared NS host = <label>.<apex>
CF_RECORD_TTL="${CF_RECORD_TTL:-60}"
CF_PROVISION=0   # set to 1 by wizard / standalone mode

# Derived after input (set by wizard or env)
SOCKS_USER="${TUNNEL_USER:-}"
SOCKS_PASS="${TUNNEL_PASS:-}"

# ════════════════════════════════════════════════════════════
#  COLORS & UI HELPERS
# ════════════════════════════════════════════════════════════

C_RESET="\e[0m"
C_BOLD="\e[1m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_CYAN="\e[36m"
C_WHITE="\e[97m"
C_DIM="\e[2m"

info()    { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
error()   { echo -e "${C_RED}[-]${C_RESET} $*"; exit 1; }
section() { echo -e "\n${C_CYAN}${C_BOLD}━━━ $* ━━━${C_RESET}"; }
hr()      { echo -e "${C_DIM}────────────────────────────────────────────────────${C_RESET}"; }
require() { command -v "$1" >/dev/null 2>&1 || error "Missing: $1. Install it first."; }

# ask VAR "Prompt" "default"
ask() {
    local var="$1" prompt="$2" default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${C_DIM}[${default}]${C_RESET}"
    echo -en "  ${C_WHITE}${prompt}${C_RESET}${display_default}: "
    local val
    read -r val
    [[ -z "$val" ]] && val="$default"
    printf -v "$var" '%s' "$val"
}

# ask_pass VAR "Prompt"
ask_pass() {
    local var="$1" prompt="$2"
    echo -en "  ${C_WHITE}${prompt}${C_RESET}: "
    local val
    read -rs val
    echo ""
    printf -v "$var" '%s' "$val"
}

# ask_yn "Question" → returns 0=yes 1=no
ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint
    [[ "$default" == "y" ]] && hint="${C_GREEN}Y${C_RESET}/n" || hint="y/${C_GREEN}N${C_RESET}"
    echo -en "  ${C_WHITE}${prompt}${C_RESET} [${hint}]: "
    local ans
    read -r ans
    [[ -z "$ans" ]] && ans="$default"
    [[ "${ans,,}" == "y" ]]
}

# numbered menu: pick_menu RESULT_VAR "Title" "opt1" "opt2" ...
pick_menu() {
    local var="$1"; shift
    local title="$1"; shift
    local options=("$@")
    echo ""
    echo -e "  ${C_CYAN}${C_BOLD}${title}${C_RESET}"
    echo ""
    local i=1
    for opt in "${options[@]}"; do
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n" "$i" "$opt"
        ((i++))
    done
    echo ""
    local choice
    while true; do
        echo -en "  ${C_WHITE}Choose [1-${#options[@]}]${C_RESET}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf -v "$var" '%s' "${options[$((choice-1))]}"
            break
        fi
        echo -e "  ${C_RED}Invalid choice. Enter a number between 1 and ${#options[@]}.${C_RESET}"
    done
}

draw_banner() {
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║          DNS TUNNEL KIT  —  Setup & Manager          ║
  ║   MasterDnsVPN  ·  Slipstream  ·  dnstt  ·  VayDNS  ║
  ║   Credits: github.com/mrvcoder                        ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${C_RESET}"
}

press_enter() {
    echo ""
    echo -en "  ${C_DIM}Press Enter to continue...${C_RESET}"
    read -r
}

# ════════════════════════════════════════════════════════════
#  INSTALL HELPERS
# ════════════════════════════════════════════════════════════

install_deps() {
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y curl wget unzip python3 openssl sslh 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════
#  SLIPNET SHARE-URI GENERATOR  (issue #1, item 6)
# ════════════════════════════════════════════════════════════
#
# Builds a slipnet://<base64> URI per SlipNet's documented v24
# pipe-delimited schema (anonvector/SlipNet:ConfigExporter.kt).
# Newer SlipNet versions parse v24 forward-compatibly (additive
# schema). Supports the tunnel types this kit ships: dnstt, vaydns,
# and sayedns (NoizDNS-compatible dnstt).
#
# Usage:
#   make_slipnet_uri <mode> <name> <domain> <pubkey>
#   mode ∈ { dnstt | vaydns | sayedns }

make_slipnet_uri() {
    local mode="$1" name="$2" domain="$3" pubkey="$4"
    local resolvers="1.1.1.1:53:0,8.8.8.8:53:0"
    local vay_compat=0
    [[ "$mode" == "vaydns" ]] && vay_compat=1

    # 62-field v24 schema (see anonvector/SlipNet:ConfigExporter.kt
    # buildProfileData). One field per array entry — empty slot = "".
    local f=(
        "24"            #  1 VERSION
        "${mode}"       #  2 tunnelType (dnstt | vaydns | sayedns)
        "${name}"       #  3 name
        "${domain}"     #  4 domain
        "${resolvers}"  #  5 resolvers
        "0"             #  6 authoritativeMode
        "60"            #  7 keepAliveInterval
        "default"       #  8 congestionControl
        "1080"          #  9 tcpListenPort
        "127.0.0.1"     # 10 tcpListenHost
        "0"             # 11 gsoEnabled
        "${pubkey}"     # 12 dnsttPublicKey
        ""              # 13 socksUsername
        ""              # 14 socksPassword
        "0"             # 15 sshEnabled
        ""              # 16 sshUsername
        ""              # 17 sshPassword
        "22"            # 18 sshPort
        "0"             # 19 forwardDnsThroughSsh
        ""              # 20 sshHost
        "0"             # 21 (was useServerDns)
        ""              # 22 dohUrl
        "udp"           # 23 dnsTransport
        "password"      # 24 sshAuthType
        ""              # 25 sshPrivateKey (b64)
        ""              # 26 sshKeyPassphrase (b64)
        ""              # 27 torBridgeLines (b64)
        "0"             # 28 dnsttAuthoritative
        "0"             # 29 naivePort
        ""              # 30 naiveUsername
        ""              # 31 naivePassword (b64)
        "0"             # 32 isLocked
        ""              # 33 lockPasswordHash
        "0"             # 34 expirationDate
        "0"             # 35 allowSharing
        ""              # 36 boundDeviceId
        "0"             # 37 resolversHidden
        ""              # 38 hiddenResolvers
        "0"             # 39 noizdnsStealth
        "0"             # 40 dnsPayloadSize
        "0"             # 41 socks5ServerPort
        "${vay_compat}" # 42 vaydnsDnsttCompat
        "txt"           # 43 vaydnsRecordType
        "0"             # 44 vaydnsMaxQnameLen
        "0"             # 45 vaydnsRps
        "10"            # 46 vaydnsIdleTimeout
        "2"             # 47 vaydnsKeepalive
        "500"           # 48 vaydnsUdpTimeout
        "0"             # 49 vaydnsMaxNumLabels
        "2"             # 50 vaydnsClientIdSize
        "0"             # 51 sshTlsEnabled
        ""              # 52 sshTlsSni
        ""              # 53 sshHttpProxyHost
        "0"             # 54 sshHttpProxyPort
        ""              # 55 sshHttpProxyCustomHost
        "0"             # 56 sshWsEnabled
        ""              # 57 sshWsPath
        "0"             # 58 sshWsUseTls
        ""              # 59 sshWsCustomHost
        ""              # 60 sshPayload (b64)
        "reliable"      # 61 resolverMode
        "3"             # 62 rrSpreadCount
    )
    local IFS='|'
    printf 'slipnet://%s\n' "$(printf '%s' "${f[*]}" | base64 -w0)"
}

install_bundled_binaries() {
    section "Installing bundled binaries"
    local ARCH; ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local bin_dir="${script_dir}/bin"

    # dnstm — try local bin/ first, then download from GitHub releases
    if [[ -f "${bin_dir}/dnstm" ]]; then
        install -m 0755 "${bin_dir}/dnstm" "/usr/local/bin/dnstm"
        info "Installed: dnstm (bundled)"
    elif ! command -v dnstm >/dev/null 2>&1; then
        info "Downloading dnstm..."
        local dnstm_url="https://github.com/net2share/dnstm/releases/latest/download/dnstm-linux-${ARCH}"
        if curl -fSL -o /tmp/dnstm "${dnstm_url}" 2>/dev/null; then
            install -m 0755 /tmp/dnstm /usr/local/bin/dnstm
            rm -f /tmp/dnstm
            info "Installed: dnstm"
        else
            warn "Failed to download dnstm"
        fi
    else
        info "dnstm already installed: $(dnstm version 2>/dev/null || echo ok)"
    fi

    # microsocks — try local bin/ first, then build from source or download
    if [[ -f "${bin_dir}/microsocks" ]]; then
        install -m 0755 "${bin_dir}/microsocks" "/usr/local/bin/microsocks"
        info "Installed: microsocks (bundled)"
    elif ! command -v microsocks >/dev/null 2>&1; then
        info "Downloading microsocks..."
        local msocks_url="https://github.com/rofl0r/microsocks/releases/latest/download/microsocks-linux-${ARCH}"
        if curl -fSL -o /tmp/microsocks "${msocks_url}" 2>/dev/null && file /tmp/microsocks | grep -q ELF; then
            install -m 0755 /tmp/microsocks /usr/local/bin/microsocks
            rm -f /tmp/microsocks
            info "Installed: microsocks"
        else
            # Build from source as fallback
            rm -f /tmp/microsocks
            info "Building microsocks from source..."
            apt-get install -y gcc make git 2>/dev/null | tail -1
            git clone --depth=1 https://github.com/rofl0r/microsocks /tmp/microsocks-src 2>/dev/null
            make -C /tmp/microsocks-src 2>/dev/null
            install -m 0755 /tmp/microsocks-src/microsocks /usr/local/bin/microsocks
            rm -rf /tmp/microsocks-src
            info "Installed: microsocks (built from source)"
        fi
    else
        info "microsocks already installed"
    fi

    # slipstream-server — try local bin/ first, then download
    if [[ -f "${bin_dir}/slipstream-server" ]]; then
        install -m 0755 "${bin_dir}/slipstream-server" "/usr/local/bin/slipstream-server"
        info "Installed: slipstream-server (bundled)"
    elif ! command -v slipstream-server >/dev/null 2>&1; then
        info "Downloading slipstream-server..."
        local slip_url="https://github.com/endpositive/slipstream/releases/latest/download/slipstream-server-linux-${ARCH}"
        if curl -fSL -o /tmp/slipstream-server "${slip_url}" 2>/dev/null && file /tmp/slipstream-server | grep -q ELF; then
            install -m 0755 /tmp/slipstream-server /usr/local/bin/slipstream-server
            rm -f /tmp/slipstream-server
            info "Installed: slipstream-server"
        else
            warn "Failed to download slipstream-server — please install manually"
        fi
    else
        info "slipstream-server already installed"
    fi

    # vaydns-server — bundled in bin/ or downloadable
    if [[ -f "${bin_dir}/vaydns-server" ]]; then
        install -m 0755 "${bin_dir}/vaydns-server" "/usr/local/bin/vaydns-server"
        info "Installed: vaydns-server (bundled)"
    elif ! command -v vaydns-server >/dev/null 2>&1; then
        info "Downloading vaydns-server..."
        local vaydns_url="https://github.com/net2share/vaydns/releases/latest/download/vaydns-server-linux-${ARCH}"
        if curl -fSL -o /tmp/vaydns-server "${vaydns_url}" 2>/dev/null && file /tmp/vaydns-server | grep -q ELF; then
            install -m 0755 /tmp/vaydns-server /usr/local/bin/vaydns-server
            rm -f /tmp/vaydns-server
            info "Installed: vaydns-server"
        else
            warn "Failed to download vaydns-server — VayDNS setup will be skipped"
        fi
    else
        info "vaydns-server already installed"
    fi

    # NoizDNS dnstt-server (supports both dnstt + NoizDNS clients).
    # The upstream release URL was historically flaky / 404, so we
    # fall back to the bundled bin/dnstt-server (issue #1).
    if ! command -v dnstt-server-noizdns >/dev/null 2>&1; then
        info "Installing dnstt-server-noizdns..."
        local noizdns_url="https://github.com/anonvector/noizdns-deploy/releases/latest/download/dnstt-server-linux-${ARCH}"
        if curl -fSL -o /tmp/dnstt-server-noizdns "${noizdns_url}" 2>/dev/null \
                && file /tmp/dnstt-server-noizdns | grep -q ELF; then
            install -m 0755 /tmp/dnstt-server-noizdns /usr/local/bin/dnstt-server-noizdns
            rm -f /tmp/dnstt-server-noizdns
            info "Installed: dnstt-server-noizdns (upstream)"
        else
            rm -f /tmp/dnstt-server-noizdns
            if [[ -f "${bin_dir}/dnstt-server" ]]; then
                install -m 0755 "${bin_dir}/dnstt-server" /usr/local/bin/dnstt-server-noizdns
                info "Installed: dnstt-server-noizdns (from bundled bin/dnstt-server)"
            elif command -v dnstt-server >/dev/null 2>&1; then
                ln -sf "$(command -v dnstt-server)" /usr/local/bin/dnstt-server-noizdns
                info "Installed: dnstt-server-noizdns (symlink to dnstt-server)"
            else
                warn "Failed to install dnstt-server-noizdns"
            fi
        fi
    else
        info "dnstt-server-noizdns already installed"
    fi

    # StormDNS — released as a zipped per-arch binary on GitHub.
    if [[ ! -x "${STORMDNS_INSTALL_DIR}/stormdns-server" ]]; then
        local sd_arch sd_prefix
        case "$ARCH" in
            amd64) sd_arch="AMD64" ;;
            arm64) sd_arch="ARM64" ;;
            *)     sd_arch=""      ;;
        esac
        if [[ -n "$sd_arch" ]]; then
            info "Downloading StormDNS server..."
            sd_prefix="StormDNS_Server_Linux_${sd_arch}"
            local sd_url="https://github.com/nullroute1970/StormDNS/releases/latest/download/${sd_prefix}.zip"
            if curl -fSL -o /tmp/stormdns.zip "${sd_url}" 2>/dev/null; then
                mkdir -p "${STORMDNS_INSTALL_DIR}"
                unzip -oq /tmp/stormdns.zip -d /tmp/stormdns-extract
                local sd_bin
                sd_bin=$(find /tmp/stormdns-extract -maxdepth 2 -type f -name "${sd_prefix}*" 2>/dev/null | head -n1)
                if [[ -n "$sd_bin" ]]; then
                    install -m 0755 "$sd_bin" "${STORMDNS_INSTALL_DIR}/stormdns-server"
                    info "Installed: stormdns-server → ${STORMDNS_INSTALL_DIR}/"
                else
                    warn "StormDNS binary not found inside ${sd_prefix}.zip"
                fi
                rm -rf /tmp/stormdns.zip /tmp/stormdns-extract
            else
                warn "Failed to download StormDNS — install will be skipped"
            fi
        else
            warn "StormDNS: unsupported arch '${ARCH}' (only amd64/arm64 published)"
        fi
    else
        info "stormdns-server already installed"
    fi
}

# ════════════════════════════════════════════════════════════
#  MASTERDNSVPN
# ════════════════════════════════════════════════════════════

download_masterdnsvpn() {
    section "Downloading MasterDnsVPN Server"
    local arch; arch=$(uname -m)
    local asset asset_legacy
    case "$arch" in
        x86_64)  asset="MasterDnsVPN_Server_Linux_AMD64.tar.gz"
                 asset_legacy="MasterDnsVPN_Server_Linux-Legacy_AMD64.tar.gz" ;;
        aarch64) asset="MasterDnsVPN_Server_Linux_ARM64.tar.gz"
                 asset_legacy="MasterDnsVPN_Server_Linux-Legacy_ARM64.tar.gz" ;;
        *)       error "Unsupported architecture: $arch" ;;
    esac

    info "Fetching latest release info from GitHub..."
    local api_url="https://api.github.com/repos/masterking32/MasterDnsVPN/releases/latest"
    local release_json
    release_json=$(curl -sf --connect-timeout 15 --max-time 30 \
        -H "Accept: application/vnd.github+json" "$api_url") \
        || { warn "GitHub API unreachable — using fallback URL"; release_json=""; }

    get_asset_url() {
        local name="$1"
        [[ -z "$release_json" ]] && return
        echo "$release_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    if a['name'] == '${name}':
        print(a['browser_download_url']); break
" 2>/dev/null
    }

    local url; url=$(get_asset_url "$asset")
    [[ -z "$url" ]] && url="${MDNS_GH_BASE}/${asset}"

    mkdir -p "$MDNS_INSTALL_DIR"
    local tmp; tmp=$(mktemp -d)

    info "Downloading ${asset} (~42MB)..."
    if ! curl -L --retry 3 --retry-delay 3 --connect-timeout 30 --max-time 600 \
              --progress-bar -o "${tmp}/server.tar.gz" "$url"; then
        warn "Trying legacy build..."
        local url_legacy; url_legacy=$(get_asset_url "$asset_legacy")
        [[ -z "$url_legacy" ]] && url_legacy="${MDNS_GH_BASE}/${asset_legacy}"
        curl -L --retry 3 --retry-delay 3 --connect-timeout 30 --max-time 600 \
             --progress-bar -o "${tmp}/server.tar.gz" "$url_legacy" \
             || { rm -rf "$tmp"; error "Download failed"; }
    fi

    info "Extracting..."
    tar xf "${tmp}/server.tar.gz" -C "${tmp}"
    local bin; bin=$(find "${tmp}" -type f -name 'MasterDnsVPN_Server*' \
        ! -name '*.gz' ! -name '*.zip' ! -name '*.toml' ! -name '*.txt' | head -1)
    [[ -z "$bin" ]] && error "Server binary not found in archive"

    mv "$bin" "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server"
    chmod +x "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server"
    rm -rf "$tmp"

    if file "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server" | grep -q "statically linked"; then
        info "MasterDnsVPN installed — native Go binary ($(du -sh "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server" | cut -f1))"
    else
        warn "MasterDnsVPN binary is dynamically linked (legacy PyInstaller). This may not work with the latest client."
        warn "Re-run setup or manually replace with the latest release from GitHub."
    fi
}

write_masterdnsvpn_config() {
    section "Writing MasterDnsVPN config"
    local key_file="${MDNS_INSTALL_DIR}/encrypt_key.txt"
    local enc_key
    if [[ -f "$key_file" ]]; then
        enc_key=$(cat "$key_file")
        info "Reusing existing encrypt key."
    else
        enc_key=$(openssl rand -hex 32)
        echo "$enc_key" > "$key_file"
        chmod 600 "$key_file"
        info "Generated new encrypt key → ${key_file}"
    fi

    local socks5_auth socks5_user socks5_pass
    if [[ -n "${TUNNEL_USER}" ]]; then
        socks5_auth="true"
        socks5_user="${TUNNEL_USER}"
        socks5_pass="${TUNNEL_PASS}"
    else
        socks5_auth="false"
        socks5_user="admin"
        socks5_pass="unused"
    fi

    cat > "${MDNS_INSTALL_DIR}/server_config.toml" << TOML
# MasterDnsVPN Server Config — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")

UDP_HOST = "127.0.0.1"
UDP_PORT = ${MDNS_PORT}
DOMAIN = ["${MDNS_DOMAIN}"]

PROTOCOL_TYPE = "SOCKS5"
USE_EXTERNAL_SOCKS5 = false
FORWARD_IP = "127.0.0.1"
FORWARD_PORT = 1080
SOCKS5_AUTH = ${socks5_auth}
SOCKS5_USER = "${socks5_user}"
SOCKS5_PASS = "${socks5_pass}"
SOCKS_HANDSHAKE_TIMEOUT = 120.0

DATA_ENCRYPTION_METHOD = ${MDNS_ENCRYPTION}
SUPPORTED_UPLOAD_COMPRESSION_TYPES   = [0, 1, 2, 3]
SUPPORTED_DOWNLOAD_COMPRESSION_TYPES = [0, 1, 2, 3]

ARQ_WINDOW_SIZE         = 256
ARQ_INITIAL_RTO         = 0.4
ARQ_MAX_RTO             = 1.2
ARQ_CONTROL_INITIAL_RTO = 0.4
ARQ_CONTROL_MAX_RTO     = 1.2
ARQ_CONTROL_MAX_RETRIES = 200

SESSION_TIMEOUT          = 300
SESSION_CLEANUP_INTERVAL = 30
MAX_SESSIONS             = 255
MAX_CONCURRENT_REQUESTS  = 500
CPU_WORKER_THREADS       = 0
MAX_PACKETS_PER_BATCH    = 1000
SOCKET_BUFFER_SIZE       = 8388608

LOG_LEVEL      = "INFO"
CONFIG_VERSION = 3.0
TOML
    info "Config written → ${MDNS_INSTALL_DIR}/server_config.toml"
}

install_masterdnsvpn_service() {
    cat > /etc/systemd/system/masterdnsvpn.service << UNIT
[Unit]
Description=MasterDnsVPN Server (${MDNS_DOMAIN})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${MDNS_INSTALL_DIR}
ExecStart=${MDNS_INSTALL_DIR}/MasterDnsVPN_Server
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${MDNS_INSTALL_DIR}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

setup_masterdnsvpn() {
    install_deps
    download_masterdnsvpn
    write_masterdnsvpn_config
    install_masterdnsvpn_service
    systemctl enable --now masterdnsvpn
    sleep 2
    systemctl is-active --quiet masterdnsvpn \
        && info "masterdnsvpn ✓ running" \
        || warn "Check logs: journalctl -u masterdnsvpn -n 30"
}

# ════════════════════════════════════════════════════════════
#  SLIPSTREAM
# ════════════════════════════════════════════════════════════

setup_slipstream() {
    section "Setting up Slipstream (${SLIP_DOMAIN})"
    require slipstream-server
    require microsocks

    mkdir -p "$SLIP_CERT_DIR"
    # Generate or load reset-seed (32 hex chars = 16 bytes — must persist across reinstalls)
    local seed_file="${SLIP_CERT_DIR}/reset-seed"
    if [[ -f "$seed_file" ]]; then
        SLIP_RESET_SEED="$(cat "$seed_file")"
    else
        SLIP_RESET_SEED="$(openssl rand -hex 16)"
        echo "$SLIP_RESET_SEED" > "$seed_file"
        chmod 600 "$seed_file"
    fi
    if [[ ! -f "${SLIP_CERT_DIR}/cert.pem" ]]; then
        info "Generating self-signed TLS cert..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "${SLIP_CERT_DIR}/key.pem" -out "${SLIP_CERT_DIR}/cert.pem" \
            -days 3650 -nodes -subj "/CN=${SLIP_DOMAIN}" 2>/dev/null
        chmod 600 "${SLIP_CERT_DIR}/key.pem"
        info "Cert → ${SLIP_CERT_DIR}/cert.pem"
    else
        info "Reusing existing cert."
    fi

    local slip_user="${SOCKS_USER:-}"
    local slip_pass="${SOCKS_PASS:-}"

    # Build auth args — empty if no-auth mode
    local auth_args=""
    if [[ -n "$slip_user" && -n "$slip_pass" ]]; then
        auth_args="-u ${slip_user} -P ${slip_pass}"
        info "SOCKS auth enabled: user=${slip_user}"
    else
        info "SOCKS no-auth mode"
    fi

    # Slipstream backend port: use 58077 if auth, 58078 (shared noauth) if no-auth
    local slip_backend_port="${SOCKS_SLIP_PORT}"
    [[ -z "$slip_user" ]] && slip_backend_port="${SOCKS_NOAUTH_PORT}"

    # Private/internal microsocks on SOCKS_PORT (58076)
    cat > /etc/systemd/system/microsocks.service << UNIT
[Unit]
Description=Microsocks SOCKS5 — private/internal backend (:${SOCKS_PORT})
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -i 127.0.0.1 -p ${SOCKS_PORT} ${auth_args}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    # Public/Slipstream microsocks on SOCKS_SLIP_PORT (58077) — only if auth enabled
    if [[ -n "$slip_user" ]]; then
        cat > /etc/systemd/system/microsocks-slip-public.service << UNIT
[Unit]
Description=Microsocks SOCKS5 auth — Slipstream + public backend (:${SOCKS_SLIP_PORT})
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -i 127.0.0.1 -p ${SOCKS_SLIP_PORT} ${auth_args}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    fi

    # Slipstream depends on the correct microsocks backend
    local slip_after_svc="microsocks-noauth.service"
    [[ -n "$slip_user" ]] && slip_after_svc="microsocks-slip-public.service"

    cat > /etc/systemd/system/dnstm-slip-socks.service << UNIT
[Unit]
Description=Slipstream DNS Tunnel (${SLIP_DOMAIN})
After=network-online.target ${slip_after_svc}

[Service]
Type=simple
ExecStart=/usr/local/bin/slipstream-server \\
    -d ${SLIP_DOMAIN} \\
    --dns-listen-host 127.0.0.1 \\
    --dns-listen-port ${SLIP_PORT} \\
    -c ${SLIP_CERT_DIR}/cert.pem \\
    -k ${SLIP_CERT_DIR}/key.pem \\
    -a 127.0.0.1:${slip_backend_port} \\
    --reset-seed ${SLIP_CERT_DIR}/reset-seed \\
    --idle-timeout-seconds 1200
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now microsocks
    [[ -n "$slip_user" ]] && systemctl enable --now microsocks-slip-public
    systemctl enable --now dnstm-slip-socks
    sleep 2
    systemctl is-active --quiet dnstm-slip-socks \
        && info "Slipstream ✓ running (backend: 127.0.0.1:${slip_backend_port})" \
        || warn "Check logs: journalctl -u dnstm-slip-socks -n 30"
}

# ════════════════════════════════════════════════════════════
#  DNSTT
# ════════════════════════════════════════════════════════════

setup_dnstt() {
    section "Setting up dnstt (${DNSTT_DOMAIN})"
    require dnstt-server-noizdns
    require microsocks

    mkdir -p "$DNSTT_KEY_DIR"
    if [[ ! -f "${DNSTT_KEY_DIR}/server.key" ]]; then
        info "Generating dnstt keypair..."
        /usr/local/bin/dnstt-server-noizdns -gen-key \
            -privkey-file "${DNSTT_KEY_DIR}/server.key" \
            -pubkey-file  "${DNSTT_KEY_DIR}/server.pub"
        chmod 600 "${DNSTT_KEY_DIR}/server.key"
    else
        info "Reusing existing dnstt keypair."
    fi

    local pubkey; pubkey=$(cat "${DNSTT_KEY_DIR}/server.pub")
    local dnstt_upstream_port
    local dnstt_after_svc

    if [[ "${INSTALL_SSLH_MUX:-0}" == "1" ]]; then
        dnstt_upstream_port="${SSLH_MUX_PORT}"
        dnstt_after_svc="sslh-mux.service"
        info "dnstt will use sslh multiplexer on :${SSLH_MUX_PORT} (SSH + SOCKS5 auto-detect)"
    else
        dnstt_upstream_port="${SOCKS_NOAUTH_PORT}"
        dnstt_after_svc="microsocks-noauth.service"
        info "dnstt uses no-auth SOCKS5 backend on :${SOCKS_NOAUTH_PORT}"
    fi
    cat > /etc/systemd/system/microsocks-noauth.service << UNIT
[Unit]
Description=microsocks SOCKS5 no-auth — dnstt backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -i 127.0.0.1 -p ${SOCKS_NOAUTH_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now microsocks-noauth

    # dnstt-server-noizdns CLI:  -udp ADDR -privkey-file KEY [-mtu N] DOMAIN UPSTREAMADDR
    # (issue #1 — earlier versions of this unit dropped the -udp flag
    # and the trailing UPSTREAMADDR, and appended a stray "x" to the
    # domain.)
    cat > /etc/systemd/system/dnstm-dnstt.service << UNIT
[Unit]
Description=dnstt/NoizDNS Tunnel (${DNSTT_DOMAIN})
After=network-online.target ${dnstt_after_svc}

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server-noizdns \\
    -udp 127.0.0.1:${DNSTT_PORT} \\
    -privkey-file ${DNSTT_KEY_DIR}/server.key \\
    -mtu 1232 \\
    ${DNSTT_DOMAIN} 127.0.0.1:${dnstt_upstream_port}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now dnstm-dnstt
    sleep 2
    systemctl is-active --quiet dnstm-dnstt \
        && info "dnstt ✓ running  pubkey: ${pubkey}" \
        || warn "Check logs: journalctl -u dnstm-dnstt -n 30"
}

# ════════════════════════════════════════════════════════════
#  VAYDNS
# ════════════════════════════════════════════════════════════

setup_vaydns() {
    section "Setting up VayDNS (${VAYDNS_DOMAIN})"

    if ! command -v vaydns-server >/dev/null 2>&1; then
        warn "vaydns-server not found — skipping VayDNS setup"
        return 0
    fi
    require microsocks

    mkdir -p "$VAYDNS_KEY_DIR"

    # Generate keypair if not present
    if [[ ! -f "${VAYDNS_KEY_DIR}/server.key" ]]; then
        info "Generating VayDNS keypair..."
        /usr/local/bin/vaydns-server -gen-key \
            -privkey-file "${VAYDNS_KEY_DIR}/server.key" \
            -pubkey-file  "${VAYDNS_KEY_DIR}/server.pub"
        chmod 600 "${VAYDNS_KEY_DIR}/server.key"
        info "Keypair saved → ${VAYDNS_KEY_DIR}/"
    else
        info "Reusing existing VayDNS keypair."
    fi

    local pubkey; pubkey=$(cat "${VAYDNS_KEY_DIR}/server.pub")

    # VayDNS always uses the auth microsocks backend (same as Slipstream).
    # If no-auth mode is active, use the noauth backend.
    local vaydns_upstream_port="${SOCKS_SLIP_PORT}"
    [[ -z "${SOCKS_USER:-}" ]] && vaydns_upstream_port="${SOCKS_NOAUTH_PORT}"

    # -dnstt-compat: enables DNSTT wire-format compatibility on the
    # VayDNS server so SlipNet's DNSTT/NoizDNS clients can connect
    # without switching profile types (issue #1). The native VayDNS
    # client still works because the server speaks both formats.
    cat > /etc/systemd/system/vaydns-server.service << UNIT
[Unit]
Description=VayDNS Server (${VAYDNS_DOMAIN})
After=network-online.target microsocks.service microsocks-noauth.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vaydns-server \\
    -udp 127.0.0.1:${VAYDNS_PORT} \\
    -privkey-file ${VAYDNS_KEY_DIR}/server.key \\
    -domain ${VAYDNS_DOMAIN} \\
    -upstream 127.0.0.1:${vaydns_upstream_port} \\
    -dnstt-compat
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now vaydns-server
    sleep 2
    systemctl is-active --quiet vaydns-server \
        && info "VayDNS ✓ running  pubkey: ${pubkey}" \
        || warn "Check logs: journalctl -u vaydns-server -n 30"
}

# ════════════════════════════════════════════════════════════
#  STORMDNS
# ════════════════════════════════════════════════════════════
#
# StormDNS in SOCKS5 mode is itself a SOCKS server — the client
# tunnels in over DNS and picks its own destinations. So unlike
# MasterDnsVPN/Slipstream/VayDNS we don't need a microsocks
# backend; dnstm just forwards the UDP DNS traffic to StormDNS's
# listener and StormDNS handles outbound dialling itself.

setup_stormdns() {
    section "Setting up StormDNS (${STORMDNS_DOMAIN})"

    if [[ ! -x "${STORMDNS_INSTALL_DIR}/stormdns-server" ]]; then
        warn "stormdns-server not found at ${STORMDNS_INSTALL_DIR}/ — skipping"
        return 0
    fi

    mkdir -p "$STORMDNS_INSTALL_DIR"

    cat > "${STORMDNS_INSTALL_DIR}/server_config.toml" << TOML
# StormDNS server config — generated by dns-tunnel-kit setup.sh
DOMAIN = ["${STORMDNS_DOMAIN}"]
PROTOCOL_TYPE = "SOCKS5"
SUPPORTED_UPLOAD_COMPRESSION_TYPES = [0, 1, 2, 3]
SUPPORTED_DOWNLOAD_COMPRESSION_TYPES = [0, 1, 2, 3]

UDP_HOST = "127.0.0.1"
UDP_PORT = ${STORMDNS_PORT}
UDP_READERS = 7
DNS_REQUEST_WORKERS = 7
MAX_CONCURRENT_REQUESTS = 16384
SOCKET_BUFFER_SIZE = 8388608
MAX_PACKET_SIZE = 65535
DROP_LOG_INTERVAL_SECONDS = 2.0

DEFERRED_SESSION_WORKERS = 4
DEFERRED_SESSION_QUEUE_LIMIT = 4096
SESSION_ORPHAN_QUEUE_INITIAL_CAPACITY = 128
STREAM_QUEUE_INITIAL_CAPACITY = 256
DNS_FRAGMENT_STORE_CAPACITY = 512
SOCKS5_FRAGMENT_STORE_CAPACITY = 1024
MAX_STREAMS_PER_SESSION = 4096
MAX_DNS_RESPONSE_BYTES = 32768

INVALID_COOKIE_WINDOW_SECONDS = 2.0
INVALID_COOKIE_ERROR_THRESHOLD = 10
SESSION_TIMEOUT_SECONDS = 300.0
SESSION_CLEANUP_INTERVAL_SECONDS = 30.0
CLOSED_SESSION_RETENTION_SECONDS = 600.0
SESSION_INIT_REUSE_TTL_SECONDS = 600.0
RECENTLY_CLOSED_STREAM_TTL_SECONDS = 600.0
RECENTLY_CLOSED_STREAM_CAP = 2000
TERMINAL_STREAM_RETENTION_SECONDS = 45.0

DNS_UPSTREAM_SERVERS = ["1.1.1.1:53", "1.0.0.1:53"]
DNS_UPSTREAM_TIMEOUT = 4.0
DNS_INFLIGHT_WAIT_TIMEOUT_SECONDS = 15.0
DNS_FRAGMENT_ASSEMBLY_TIMEOUT = 300.0
DNS_CACHE_MAX_RECORDS = 50000
DNS_CACHE_TTL_SECONDS = 300.0

SOCKS_CONNECT_TIMEOUT = 120.0
USE_EXTERNAL_SOCKS5 = false
SOCKS5_AUTH = false
SOCKS5_USER = ""
SOCKS5_PASS = ""
FORWARD_IP = ""
FORWARD_PORT = 0

DATA_ENCRYPTION_METHOD = ${STORMDNS_ENCRYPTION}
ENCRYPTION_KEY_FILE = "${STORMDNS_INSTALL_DIR}/encrypt_key.txt"

MAX_PACKETS_PER_BATCH = 10
PACKET_BLOCK_CONTROL_DUPLICATION = 1
STREAM_SETUP_ACK_TTL_SECONDS = 400.0
STREAM_RESULT_PACKET_TTL_SECONDS = 300.0
STREAM_FAILURE_PACKET_TTL_SECONDS = 120.0
ARQ_WINDOW_SIZE = 1000
ARQ_INITIAL_RTO_SECONDS = 0.6
ARQ_MAX_RTO_SECONDS = 3.0
ARQ_CONTROL_INITIAL_RTO_SECONDS = 0.5
ARQ_CONTROL_MAX_RTO_SECONDS = 2.0
ARQ_MAX_CONTROL_RETRIES = 120
ARQ_INACTIVITY_TIMEOUT_SECONDS = 1800.0
ARQ_DATA_PACKET_TTL_SECONDS = 2400.0
ARQ_CONTROL_PACKET_TTL_SECONDS = 1200.0
TOML

    chmod 600 "${STORMDNS_INSTALL_DIR}/server_config.toml"
    # Server auto-generates encrypt_key.txt on first start if missing.
    info "Wrote ${STORMDNS_INSTALL_DIR}/server_config.toml"

    cat > /etc/systemd/system/stormdns.service << UNIT
[Unit]
Description=StormDNS Server (${STORMDNS_DOMAIN})
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${STORMDNS_INSTALL_DIR}
ExecStart=${STORMDNS_INSTALL_DIR}/stormdns-server --config ${STORMDNS_INSTALL_DIR}/server_config.toml
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now stormdns
    sleep 3

    local sd_key="(generated on first start — check ${STORMDNS_INSTALL_DIR}/encrypt_key.txt)"
    [[ -f "${STORMDNS_INSTALL_DIR}/encrypt_key.txt" ]] && \
        sd_key=$(cat "${STORMDNS_INSTALL_DIR}/encrypt_key.txt")

    systemctl is-active --quiet stormdns \
        && info "StormDNS ✓ running  key: ${sd_key}" \
        || warn "Check logs: journalctl -u stormdns -n 30"
}

# ════════════════════════════════════════════════════════════
#  CLOUDFLARE DNS PROVISIONING
# ════════════════════════════════════════════════════════════
#
# Given a list of tunnel subdomains and a server IP, ensures the
# parent Cloudflare zone has:
#   <CF_NS_GLUE_LABEL>.<apex>   A   <server_ip>     (shared NS glue)
#   <subdomain>                 NS  <CF_NS_GLUE_LABEL>.<apex>   (per tunnel)
# Idempotent: skips records already correct, updates wrong content.
# Auth: scoped API token (preferred) OR global API key + email.

cf_has_creds() {
    [[ -n "$CF_API_TOKEN" ]] || { [[ -n "$CF_EMAIL" && -n "$CF_API_KEY" ]]; }
}

cf_api() {
    # cf_api METHOD PATH [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    local url="https://api.cloudflare.com/client/v4${path}"
    local -a hdrs=(-H "Content-Type: application/json")
    if [[ -n "$CF_API_TOKEN" ]]; then
        hdrs+=(-H "Authorization: Bearer ${CF_API_TOKEN}")
    else
        hdrs+=(-H "X-Auth-Email: ${CF_EMAIL}" -H "X-Auth-Key: ${CF_API_KEY}")
    fi
    if [[ -n "$body" ]]; then
        curl -fsS -X "$method" "$url" "${hdrs[@]}" --data "$body"
    else
        curl -fsS -X "$method" "$url" "${hdrs[@]}"
    fi
}

# Find the Cloudflare zone whose name is the longest suffix of $1.
# Echoes "<zone_id>|<zone_name>", returns 1 if no match.
cf_find_zone() {
    local fqdn="$1"
    local labels="$fqdn"
    while [[ "$labels" == *.* ]]; do
        labels="${labels#*.}"
        local resp; resp=$(cf_api GET "/zones?name=${labels}" 2>/dev/null) || return 1
        local zid; zid=$(printf '%s' "$resp" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result") or []
print(r[0]["id"] if r else "")' 2>/dev/null)
        if [[ -n "$zid" ]]; then
            printf '%s|%s' "$zid" "$labels"
            return 0
        fi
    done
    return 1
}

# Look up existing record. Echoes "<id>|<content>", empty if none.
cf_find_record() {
    local zone_id="$1" rtype="$2" name="$3"
    cf_api GET "/zones/${zone_id}/dns_records?type=${rtype}&name=${name}" 2>/dev/null \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=(d.get("result") or [])
if r:
    print("{}|{}".format(r[0]["id"], r[0]["content"]))'
}

# Idempotent upsert. Returns 0 on no-op or success, 1 on failure.
cf_ensure_record() {
    local zone_id="$1" rtype="$2" name="$3" content="$4" ttl="${5:-$CF_RECORD_TTL}"
    local existing; existing=$(cf_find_record "$zone_id" "$rtype" "$name")
    local body
    body=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s}' \
            "$rtype" "$name" "$content" "$ttl")
    if [[ -z "$existing" ]]; then
        local resp; resp=$(cf_api POST "/zones/${zone_id}/dns_records" "$body") || return 1
        info "  + ${rtype} ${name} → ${content}"
    else
        local rec_id="${existing%%|*}" cur="${existing#*|}"
        if [[ "$cur" == "$content" ]]; then
            info "  = ${rtype} ${name} → ${content} (already correct)"
        else
            local resp; resp=$(cf_api PUT "/zones/${zone_id}/dns_records/${rec_id}" "$body") || return 1
            info "  ~ ${rtype} ${name} → ${content} (was: ${cur})"
        fi
    fi
}

# cf_provision_dns "<server_ip>" "<sub1>" "<sub2>" ...
cf_provision_dns() {
    local server_ip="$1"; shift
    local domains=("$@")
    section "Cloudflare DNS provisioning"
    if ! cf_has_creds; then
        warn "No Cloudflare credentials set. Set CF_API_TOKEN (or CF_EMAIL + CF_API_KEY)."
        return 1
    fi
    if [[ ${#domains[@]} -eq 0 ]]; then
        warn "No tunnel domains to provision."
        return 0
    fi
    require python3
    require curl

    # Group subdomains by zone so we only set up each glue record once.
    declare -A ZONE_BY_APEX=()
    declare -A SUBS_BY_APEX=()
    local d zone zid apex
    for d in "${domains[@]}"; do
        [[ -z "$d" || "$d" == *example.com ]] && continue
        zone=$(cf_find_zone "$d") || { warn "  no Cloudflare zone found for $d — skipping"; continue; }
        zid="${zone%%|*}"; apex="${zone#*|}"
        ZONE_BY_APEX["$apex"]="$zid"
        SUBS_BY_APEX["$apex"]+="${d} "
    done

    if [[ ${#ZONE_BY_APEX[@]} -eq 0 ]]; then
        warn "No tunnel domains map to a Cloudflare zone on this account."
        return 1
    fi

    for apex in "${!ZONE_BY_APEX[@]}"; do
        zid="${ZONE_BY_APEX[$apex]}"
        local glue="${CF_NS_GLUE_LABEL}.${apex}"
        info "Zone ${apex} (${zid})"
        cf_ensure_record "$zid" "A"  "$glue"  "$server_ip" || warn "  failed to upsert glue ${glue}"
        for d in ${SUBS_BY_APEX[$apex]}; do
            [[ "$d" == "$glue" ]] && continue
            cf_ensure_record "$zid" "NS" "$d" "$glue" || warn "  failed to upsert NS ${d}"
        done
    done
    info "Cloudflare DNS provisioning complete."
}

# Collects (server_ip, [domains]) from the currently-selected INSTALL_* flags
# and runs cf_provision_dns. Used by the wizard and standalone mode.
cf_provision_from_selection() {
    local selected=()
    [[ "${INSTALL_MDNS:-0}"     == 1 ]] && selected+=("$MDNS_DOMAIN")
    [[ "${INSTALL_SLIP:-0}"     == 1 ]] && selected+=("$SLIP_DOMAIN")
    [[ "${INSTALL_DNSTT:-0}"    == 1 ]] && selected+=("$DNSTT_DOMAIN")
    [[ "${INSTALL_VAYDNS:-0}"   == 1 ]] && selected+=("$VAYDNS_DOMAIN")
    [[ "${INSTALL_STORMDNS:-0}" == 1 ]] && selected+=("$STORMDNS_DOMAIN")
    cf_provision_dns "$SERVER_IP" "${selected[@]}"
}

# ════════════════════════════════════════════════════════════
#  DNSTM ROUTER
# ════════════════════════════════════════════════════════════

setup_dnstm() {
    section "Configuring dnstm DNS router"
    require dnstm
    mkdir -p /etc/dnstm

    cat > "$DNSTM_CONFIG" << JSON
{
  "log": { "level": "info" },
  "listen": { "address": "0.0.0.0:53" },
  "proxy": { "port": ${SOCKS_PORT} },
  "backends": [
    { "tag": "socks", "type": "socks", "address": "127.0.0.1:${SOCKS_PORT}" },
    { "tag": "socks-public", "type": "socks", "address": "127.0.0.1:${SOCKS_SLIP_PORT}" }
  ],
  "tunnels": [
    {
      "tag": "mdns-forward",
      "enabled": true,
      "transport": "forward",
      "domain": "${MDNS_DOMAIN}",
      "port": ${MDNS_PORT},
      "forward": { "address": "127.0.0.1:${MDNS_PORT}" }
    },
    {
      "tag": "slip-socks",
      "enabled": true,
      "transport": "slipstream",
      "backend": "socks-public",
      "domain": "${SLIP_DOMAIN}",
      "port": ${SLIP_PORT},
      "slipstream": {
        "cert": "${SLIP_CERT_DIR}/cert.pem",
        "key": "${SLIP_CERT_DIR}/key.pem"
      }
    },
    {
      "tag": "dnstt-tunnel",
      "enabled": true,
      "transport": "forward",
      "domain": "${DNSTT_DOMAIN}",
      "port": ${DNSTT_PORT},
      "forward": { "address": "127.0.0.1:${DNSTT_PORT}" }
    },
    {
      "tag": "vaydns-tunnel",
      "enabled": true,
      "transport": "forward",
      "domain": "${VAYDNS_DOMAIN}",
      "port": ${VAYDNS_PORT},
      "forward": { "address": "127.0.0.1:${VAYDNS_PORT}" }
    },
    {
      "tag": "stormdns-tunnel",
      "enabled": true,
      "transport": "forward",
      "domain": "${STORMDNS_DOMAIN}",
      "port": ${STORMDNS_PORT},
      "forward": { "address": "127.0.0.1:${STORMDNS_PORT}" }
    }
  ],
  "route": { "mode": "multi", "active": "slip-socks", "default": "slip-socks" }
}
JSON

    cat > /etc/systemd/system/dnstm-dnsrouter.service << UNIT
[Unit]
Description=dnstm DNS Traffic Router
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstm dnsrouter serve
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warn "Disabling systemd-resolved stub on :53..."
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' \
            > /etc/systemd/resolved.conf.d/no-stub.conf
        systemctl restart systemd-resolved
    fi

    systemctl daemon-reload
    systemctl enable --now dnstm-dnsrouter
    sleep 2
    systemctl is-active --quiet dnstm-dnsrouter \
        && info "dnstm-dnsrouter ✓ running on :53" \
        || warn "Check logs: journalctl -u dnstm-dnsrouter -n 30"
}

# ════════════════════════════════════════════════════════════
#  SSLH PROTOCOL MULTIPLEXER (SSH + SOCKS5 on one port)
# ════════════════════════════════════════════════════════════

setup_sslh_mux() {
    section "Setting up sslh protocol multiplexer"
    require sslh

    # Disable the default sslh service if present (we use our own unit)
    systemctl disable --now sslh 2>/dev/null || true
    systemctl disable --now sslh-fork 2>/dev/null || true

    cat > /etc/systemd/system/sslh-mux.service << UNIT
[Unit]
Description=sslh protocol multiplexer (SSH + SOCKS5) for DNS tunnels
After=network-online.target sshd.service microsocks-noauth.service
Wants=network-online.target
Requires=microsocks-noauth.service

[Service]
Type=simple
ExecStart=/usr/sbin/sslh-select \\
    --foreground \\
    --listen 127.0.0.1:${SSLH_MUX_PORT} \\
    --ssh 127.0.0.1:22 \\
    --socks5 127.0.0.1:${SOCKS_NOAUTH_PORT} \\
    --on-timeout=socks5
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now sslh-mux
    sleep 1
    systemctl is-active --quiet sslh-mux \
        && info "sslh-mux ✓ running on :${SSLH_MUX_PORT}  (SSH→:22  SOCKS5→:${SOCKS_NOAUTH_PORT})" \
        || warn "Check logs: journalctl -u sslh-mux -n 20"
}

# ════════════════════════════════════════════════════════════
#  SSH TUNNEL USER
# ════════════════════════════════════════════════════════════

setup_ssh_tunnel_user() {
    section "Setting up SSH tunnel user"

    local tpass="${TUNNEL_PASS:-}"
    if [[ -z "$tpass" ]]; then
        ask_pass TUNNEL_PASS "Password for tunneluser"
        tpass="${TUNNEL_PASS}"
    fi

    # Create system user with no shell and no home dir
    if id tunneluser &>/dev/null; then
        info "tunneluser already exists — updating password."
    else
        useradd --system --no-create-home --shell /bin/false tunneluser
        info "Created system user: tunneluser"
    fi

    echo "tunneluser:${tpass}" | chpasswd
    info "Password set for tunneluser."

    # Ensure PasswordAuthentication is enabled globally (required for Match block to work)
    local sshd_conf="/etc/ssh/sshd_config"
    if grep -qE "^PasswordAuthentication\s+no" "$sshd_conf"; then
        sed -i 's/^PasswordAuthentication\s\+no/PasswordAuthentication yes/' "$sshd_conf"
        info "Enabled PasswordAuthentication in sshd_config."
    elif ! grep -qE "^PasswordAuthentication\s+yes" "$sshd_conf"; then
        echo "PasswordAuthentication yes" >> "$sshd_conf"
        info "Added PasswordAuthentication yes to sshd_config."
    fi

    # Add Match block if not already present
    if ! grep -q "Match User tunneluser" "$sshd_conf"; then
        cat >> "$sshd_conf" << 'SSHD'

Match User tunneluser
    AllowTcpForwarding yes
    AllowStreamLocalForwarding yes
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication yes
SSHD
        info "Added tunneluser Match block to sshd_config."
    else
        info "tunneluser Match block already present in sshd_config."
    fi

    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        && info "sshd reloaded." \
        || warn "Could not reload sshd — check manually."
}

# ════════════════════════════════════════════════════════════
#  STATUS
# ════════════════════════════════════════════════════════════

show_status() {
    draw_banner
    section "Service Status"

    local services=(
        "masterdnsvpn:🔵 MasterDnsVPN      :${MDNS_PORT} (${MDNS_DOMAIN})"
        "dnstm-slip-socks:🟢 Slipstream        :${SLIP_PORT} (${SLIP_DOMAIN})"
        "microsocks-slip-public:   microsocks auth    :${SOCKS_SLIP_PORT} (Slipstream backend)"
        "microsocks:   microsocks auth    :${SOCKS_PORT} (private/internal)"
        "dnstm-dnstt:🟡 dnstt              :${DNSTT_PORT} (${DNSTT_DOMAIN})"
        "microsocks-noauth:   microsocks no-auth :${SOCKS_NOAUTH_PORT} (dnstt backend)"
        "sslh-mux:   sslh multiplexer   :${SSLH_MUX_PORT} (SSH+SOCKS5 auto-detect)"
        "vaydns-server:🔴 VayDNS            :${VAYDNS_PORT} (${VAYDNS_DOMAIN})"
        "stormdns:⚡ StormDNS          :${STORMDNS_PORT} (${STORMDNS_DOMAIN})"
        "dnstm-dnsrouter:⚙️  dnstm router       :53"
    )

    echo ""
    for entry in "${services[@]}"; do
        local svcs="${entry%%:*}" label="${entry#*:}"
        local running=false active_svc="${svcs%%|*}"
        IFS='|' read -ra svc_list <<< "$svcs"
        for s in "${svc_list[@]}"; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                running=true; active_svc="$s"; break
            fi
        done
        if $running; then
            printf "  ${C_GREEN}●${C_RESET} %-30s  %s\n" "$active_svc" "$label"
        else
            printf "  ${C_RED}○${C_RESET} %-30s  ${C_DIM}%s${C_RESET}\n" "${svc_list[0]}" "$label"
        fi
    done

    echo ""
    echo -e "  ${C_DIM}DNS router :53 →${C_RESET}"
    ss -lnup sport = :53 2>/dev/null | grep -v Netid | \
        awk '{print "    " $5 "  " $NF}' | head -3 || true
    echo ""
}

# ════════════════════════════════════════════════════════════
#  CLIENT CONFIGS
# ════════════════════════════════════════════════════════════

print_client_configs() {
    section "Client Configurations"

    local mdns_key
    mdns_key=$(cat "${MDNS_INSTALL_DIR}/encrypt_key.txt" 2>/dev/null \
        || echo "run: cat ${MDNS_INSTALL_DIR}/encrypt_key.txt")
    local dnstt_pub
    dnstt_pub=$(cat "${DNSTT_KEY_DIR}/server.pub" 2>/dev/null \
        || echo "run: cat ${DNSTT_KEY_DIR}/server.pub")
    local vaydns_pub
    vaydns_pub=$(cat "${VAYDNS_KEY_DIR}/server.pub" 2>/dev/null \
        || echo "run: cat ${VAYDNS_KEY_DIR}/server.pub")
    local stormdns_key
    stormdns_key=$(cat "${STORMDNS_INSTALL_DIR}/encrypt_key.txt" 2>/dev/null \
        || echo "run: cat ${STORMDNS_INSTALL_DIR}/encrypt_key.txt")

    local cred_note
    if [[ -n "${TUNNEL_USER}" ]]; then
        cred_note="user=${TUNNEL_USER}  pass=${TUNNEL_PASS}"
    else
        cred_note="(no auth)"
    fi

    hr
    echo -e "\n  ${C_BLUE}${C_BOLD}🔵 MasterDnsVPN${C_RESET}  ${C_DIM}${MDNS_DOMAIN}${C_RESET}"
    echo "  Download: https://github.com/masterking32/MasterDnsVPN/releases/latest"
    echo ""
    echo "  client_config.toml:"
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ SOCKS5_HOST = \"127.0.0.1\""
    echo "  │ SOCKS5_PORT = 1080"
    [[ -n "${TUNNEL_USER}" ]] && {
        echo "  │ SOCKS5_AUTH = true"
        echo "  │ SOCKS5_USER = \"${TUNNEL_USER}\""
        echo "  │ SOCKS5_PASS = \"${TUNNEL_PASS}\""
    }
    echo "  │ DOMAINS = [\"${MDNS_DOMAIN}\"]"
    echo "  │ DATA_ENCRYPTION_METHOD = ${MDNS_ENCRYPTION}  # ChaCha20"
    echo "  │ ENCRYPT_KEY = \"${mdns_key}\""
    echo "  │ ARQ_WINDOW_SIZE = 256"
    echo "  │ PROTOCOL_TYPE = \"SOCKS5\""
    echo "  └─────────────────────────────────────────────────"
    echo "  Commands:  ./MasterDnsVPN_Client --scan"
    echo "             ./MasterDnsVPN_Client"
    echo -e "  SOCKS5:    ${C_GREEN}127.0.0.1:1080${C_RESET}  ${C_DIM}${cred_note}${C_RESET}"

    hr
    echo -e "\n  ${C_GREEN}${C_BOLD}🟢 Slipstream${C_RESET}  ${C_DIM}${SLIP_DOMAIN}${C_RESET}"
    echo "  Client: SlipNet Android app — profile type: SLIPSTREAM_SOCKS"
    echo "  ${C_DIM}(No user/pass needed — auth is internal between server↔microsocks)${C_RESET}"
    echo ""
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ Domain  : ${SLIP_DOMAIN}"
    echo "  │ Cert    : ${SLIP_CERT_DIR}/cert.pem  (copy to device)"
    echo "  │ No client auth required"
    echo "  └─────────────────────────────────────────────────"

    hr
    echo -e "\n  ${C_YELLOW}${C_BOLD}🟡 dnstt / NoizDNS${C_RESET}  ${C_DIM}${DNSTT_DOMAIN}${C_RESET}"
    echo "  Clients: dnstt-client, SlipNet (NoizDNS profile)"

    local sslh_active=false
    systemctl is-active --quiet sslh-mux 2>/dev/null && sslh_active=true

    if $sslh_active; then
        echo -e "  ${C_GREEN}Protocol multiplexer active — supports both SOCKS5 and SSH${C_RESET}"
        echo ""
        echo "  ┌─────────────────────────────────────────────────"
        echo "  │ Domain  : ${DNSTT_DOMAIN}"
        echo "  │ Pubkey  : ${dnstt_pub}"
        echo "  │"
        echo "  │ Mode 1: SOCKS5 (no auth)"
        echo "  │   Connect via dnstt-client → get a SOCKS5 proxy"
        echo "  │"
        echo "  │ Mode 2: SSH tunnel"
        echo "  │   Connect via dnstt-client, then SSH through it:"
        echo "  │   ssh -o ProxyCommand='nc -x 127.0.0.1:1080 %h %p' \\"
        echo "  │       -D 8080 tunneluser@${SERVER_IP}"
        echo "  │   (auto-detected — same tunnel, sslh routes by protocol)"
        echo "  └─────────────────────────────────────────────────"
    else
        echo "  ${C_DIM}(No user/pass needed — dnstt backend is no-auth on server side)${C_RESET}"
        echo ""
        echo "  ┌─────────────────────────────────────────────────"
        echo "  │ Domain  : ${DNSTT_DOMAIN}"
        echo "  │ Pubkey  : ${dnstt_pub}"
        echo "  │ No client auth required"
        echo "  └─────────────────────────────────────────────────"
    fi
    echo "  Command (dnstt-client):"
    echo "    ./dnstt-client -udp 8.8.8.8:53 \\"
    echo "      -pubkey ${dnstt_pub} \\"
    echo "      ${DNSTT_DOMAIN} 127.0.0.1:1080"
    if [[ -n "$dnstt_pub" && "$dnstt_pub" != run:* ]]; then
        echo ""
        echo "  SlipNet share URI (dnstt):"
        echo "    $(make_slipnet_uri dnstt "dnstt-${DNSTT_DOMAIN}" "${DNSTT_DOMAIN}" "${dnstt_pub}")"
        echo "  SlipNet share URI (NoizDNS):"
        echo "    $(make_slipnet_uri sayedns "noizdns-${DNSTT_DOMAIN}" "${DNSTT_DOMAIN}" "${dnstt_pub}")"
    fi

    hr
    echo -e "\n  ${C_RED}${C_BOLD}🔴 VayDNS${C_RESET}  ${C_DIM}${VAYDNS_DOMAIN}${C_RESET}"
    echo "  Clients: SlipNet Android app (VayDNS profile), vaydns-client CLI"
    echo ""
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ DNS server : ${SERVER_IP}:53"
    echo "  │ Domain     : ${VAYDNS_DOMAIN}"
    echo "  │ Public key : ${vaydns_pub}"
    echo "  └─────────────────────────────────────────────────"
    echo "  CLI client:"
    echo "    ./vaydns-client -udp ${SERVER_IP}:53 \\"
    echo "      -pubkey ${vaydns_pub} \\"
    echo "      -domain ${VAYDNS_DOMAIN} \\"
    echo "      -listen 127.0.0.1:1080"
    echo "  Then: curl -x socks5://127.0.0.1:1080 https://ifconfig.me"
    echo ""
    echo "  SlipNet profile:"
    echo "    Type   : VAYDNS"
    echo "    Domain : ${VAYDNS_DOMAIN}"
    echo "    Pubkey : ${vaydns_pub}"
    if [[ -n "$vaydns_pub" && "$vaydns_pub" != run:* ]]; then
        echo ""
        echo "  SlipNet share URI (VayDNS, dnstt-compat on):"
        echo "    $(make_slipnet_uri vaydns "vaydns-${VAYDNS_DOMAIN}" "${VAYDNS_DOMAIN}" "${vaydns_pub}")"
    fi

    hr
    echo -e "\n  ${C_WHITE}${C_BOLD}⚡ StormDNS${C_RESET}  ${C_DIM}${STORMDNS_DOMAIN}${C_RESET}"
    echo "  Clients: StormDNS client CLI, WhiteDNS Android app (StormDNS backend)"
    echo "  Download: https://github.com/nullroute1970/StormDNS/releases/latest"
    echo ""
    echo "  client_config.toml:"
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ DOMAINS = [\"${STORMDNS_DOMAIN}\"]"
    echo "  │ PROTOCOL_TYPE = \"SOCKS5\""
    echo "  │ DATA_ENCRYPTION_METHOD = ${STORMDNS_ENCRYPTION}  # ChaCha20"
    echo "  │ ENCRYPT_KEY = \"${stormdns_key}\""
    echo "  │ SOCKS5_HOST = \"127.0.0.1\""
    echo "  │ SOCKS5_PORT = 1080"
    echo "  └─────────────────────────────────────────────────"
    echo "  Resolvers: any public open resolvers (1.1.1.1, 8.8.8.8, etc.)"
    echo -e "  SOCKS5:    ${C_GREEN}127.0.0.1:1080${C_RESET}  ${C_DIM}(client picks dest — server doesn't auth)${C_RESET}"
    hr
    echo ""
}

# ════════════════════════════════════════════════════════════
#  MIDDLE PROXY
# ════════════════════════════════════════════════════════════

setup_middle_proxy() {
    section "Middle-proxy (dnsmasq DNS multiplexer)"
    require dnsmasq
    cat > /etc/dnsmasq.d/tunnel-kit.conf << DNSCONF
server=/${MDNS_DOMAIN}/8.8.8.8
server=/${MDNS_DOMAIN}/1.1.1.1
server=/${SLIP_DOMAIN}/8.8.8.8
server=/${SLIP_DOMAIN}/1.1.1.1
server=/${DNSTT_DOMAIN}/8.8.8.8
server=/${DNSTT_DOMAIN}/1.1.1.1
server=/${VAYDNS_DOMAIN}/8.8.8.8
server=/${VAYDNS_DOMAIN}/1.1.1.1
server=/${STORMDNS_DOMAIN}/8.8.8.8
server=/${STORMDNS_DOMAIN}/1.1.1.1
DNSCONF
    systemctl restart dnsmasq
    info "dnsmasq configured. Point client DNS to this VPS IP."
}

# ════════════════════════════════════════════════════════════
#  INTERACTIVE WIZARD
# ════════════════════════════════════════════════════════════

wizard_collect_inputs() {
    draw_banner
    echo -e "  ${C_CYAN}${C_BOLD}Install Wizard${C_RESET}  — configure your tunnels\n"

    # ── Server IP ──────────────────────────────────────────
    echo -e "  ${C_BOLD}── Server ─────────────────────────────────────────${C_RESET}"
    ask SERVER_IP "Server public IP" "${SERVER_IP}"

    # ── Which tunnels ─────────────────────────────────────
    echo ""
    echo -e "  ${C_BOLD}── Tunnels to install ─────────────────────────────${C_RESET}"
    ask_yn "Install MasterDnsVPN  (a.domain)" "y" && INSTALL_MDNS=1 || INSTALL_MDNS=0
    ask_yn "Install Slipstream    (b.domain)" "y" && INSTALL_SLIP=1 || INSTALL_SLIP=0
    ask_yn "Install dnstt         (c.domain)" "y" && INSTALL_DNSTT=1 || INSTALL_DNSTT=0
    ask_yn "Install VayDNS        (d.domain)" "y" && INSTALL_VAYDNS=1 || INSTALL_VAYDNS=0
    ask_yn "Install StormDNS      (e.domain)" "y" && INSTALL_STORMDNS=1 || INSTALL_STORMDNS=0

    if (( INSTALL_MDNS + INSTALL_SLIP + INSTALL_DNSTT + INSTALL_VAYDNS + INSTALL_STORMDNS == 0 )); then
        warn "No tunnels selected. Exiting."
        exit 0
    fi

    ask_yn "Set up SSH tunnel user (tunneluser)" "y" && INSTALL_SSH_TUNNEL=1 || INSTALL_SSH_TUNNEL=0

    INSTALL_SSLH_MUX=0
    if [[ $INSTALL_DNSTT == 1 && $INSTALL_SSH_TUNNEL == 1 ]]; then
        echo -e "  ${C_DIM}sslh auto-detects SSH vs SOCKS5 on dnstt tunnel — one tunnel, two protocols${C_RESET}"
        ask_yn "Enable SSH+SOCKS5 multiplexer on dnstt (sslh)" "y" && INSTALL_SSLH_MUX=1 || INSTALL_SSLH_MUX=0
    fi

    # ── Domains ───────────────────────────────────────────
    echo ""
    echo -e "  ${C_BOLD}── Domains ────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_DIM}NS delegation must point these subdomains to ${SERVER_IP}${C_RESET}"
    echo ""
    [[ $INSTALL_MDNS     == 1 ]] && ask MDNS_DOMAIN     "MasterDnsVPN domain" "${MDNS_DOMAIN}"
    [[ $INSTALL_SLIP     == 1 ]] && ask SLIP_DOMAIN     "Slipstream domain  " "${SLIP_DOMAIN}"
    [[ $INSTALL_DNSTT    == 1 ]] && ask DNSTT_DOMAIN    "dnstt domain       " "${DNSTT_DOMAIN}"
    [[ $INSTALL_VAYDNS   == 1 ]] && ask VAYDNS_DOMAIN   "VayDNS domain      " "${VAYDNS_DOMAIN}"
    [[ $INSTALL_STORMDNS == 1 ]] && ask STORMDNS_DOMAIN "StormDNS domain    " "${STORMDNS_DOMAIN}"

    # ── Cloudflare DNS auto-provisioning ──────────────────
    echo ""
    echo -e "  ${C_BOLD}── Cloudflare DNS (optional) ──────────────────────${C_RESET}"
    echo -e "  ${C_DIM}Auto-creates the NS delegation for each tunnel domain.${C_RESET}"
    echo -e "  ${C_DIM}Pattern: <tunnel-sub> NS ${CF_NS_GLUE_LABEL}.<apex>  +  ${CF_NS_GLUE_LABEL}.<apex> A ${SERVER_IP}${C_RESET}"
    echo ""
    local _cf_default="n"
    cf_has_creds && _cf_default="y"
    if ask_yn "Provision DNS via Cloudflare API" "$_cf_default"; then
        CF_PROVISION=1
        if [[ -z "$CF_API_TOKEN" && ( -z "$CF_EMAIL" || -z "$CF_API_KEY" ) ]]; then
            echo -e "  ${C_DIM}Prefer a scoped API token (Permissions: Zone:DNS:Edit + Zone:Zone:Read).${C_RESET}"
            ask_pass CF_API_TOKEN "Cloudflare API token (blank to use global key + email)"
            if [[ -z "$CF_API_TOKEN" ]]; then
                ask      CF_EMAIL    "Cloudflare account email" "$CF_EMAIL"
                ask_pass CF_API_KEY  "Cloudflare global API key"
            fi
        fi
        if ! cf_has_creds; then
            warn "No Cloudflare credentials provided — skipping DNS auto-provisioning."
            CF_PROVISION=0
        fi
        if [[ "$CF_PROVISION" == 1 ]]; then
            ask CF_NS_GLUE_LABEL "Shared NS glue label (creates <label>.<apex>)" "$CF_NS_GLUE_LABEL"
        fi
    fi

    # ── Credentials ───────────────────────────────────────
    echo ""
    echo -e "  ${C_BOLD}── SOCKS5 Authentication ──────────────────────────${C_RESET}"
    echo -e "  ${C_DIM}Set credentials to require username+password on all tunnels.${C_RESET}"
    echo -e "  ${C_DIM}Leave username empty for no-auth (open proxy).${C_RESET}"
    echo ""
    ask TUNNEL_USER "Username" ""
    if [[ -n "$TUNNEL_USER" ]]; then
        ask_pass TUNNEL_PASS "Password"
        if [[ -z "$TUNNEL_PASS" ]]; then
            warn "Empty password — switching to no-auth."
            TUNNEL_USER=""
        fi
    fi

    # Update derived vars
    SOCKS_USER="${TUNNEL_USER:-changeme}"
    SOCKS_PASS="${TUNNEL_PASS:-changeme123}"

    # ── Confirmation ──────────────────────────────────────
    echo ""
    hr
    echo -e "\n  ${C_BOLD}${C_WHITE}Configuration Summary${C_RESET}\n"
    printf "  %-22s  %s\n" "Server IP:"   "${SERVER_IP}"
    [[ $INSTALL_MDNS     == 1 ]] && printf "  %-22s  %s\n" "MasterDnsVPN:" "${MDNS_DOMAIN}"
    [[ $INSTALL_SLIP     == 1 ]] && printf "  %-22s  %s\n" "Slipstream:"   "${SLIP_DOMAIN}"
    [[ $INSTALL_DNSTT    == 1 ]] && printf "  %-22s  %s\n" "dnstt:"        "${DNSTT_DOMAIN}"
    [[ $INSTALL_VAYDNS   == 1 ]] && printf "  %-22s  %s\n" "VayDNS:"       "${VAYDNS_DOMAIN}"
    [[ $INSTALL_STORMDNS == 1 ]] && printf "  %-22s  %s\n" "StormDNS:"     "${STORMDNS_DOMAIN}"
    if [[ -n "$TUNNEL_USER" ]]; then
        printf "  %-22s  %s\n" "Auth:" "user=${TUNNEL_USER}  pass=****"
    else
        printf "  %-22s  %s\n" "Auth:" "none (open proxy)"
    fi
    [[ "${INSTALL_SSH_TUNNEL:-0}" == 1 ]] && printf "  %-22s  %s\n" "SSH tunnel user:" "tunneluser"
    [[ "${INSTALL_SSLH_MUX:-0}" == 1 ]]  && printf "  %-22s  %s\n" "Protocol mux:" "sslh (SSH+SOCKS5 on dnstt)"
    if [[ "${CF_PROVISION:-0}" == 1 ]]; then
        local _cf_mode="API token"
        [[ -z "$CF_API_TOKEN" ]] && _cf_mode="global key + ${CF_EMAIL}"
        printf "  %-22s  %s\n" "Cloudflare DNS:" "auto (${_cf_mode}, glue=${CF_NS_GLUE_LABEL}.<apex>)"
    fi
    echo ""
    hr
    echo ""

    if ! ask_yn "Proceed with installation?" "y"; then
        echo "  Aborted."
        exit 0
    fi
}

cleanup_legacy_services() {
    local legacy_svcs=(
        "dnstm"                  # replaced by dnstm-dnsrouter
        "dnstm-dnstt-socks"      # replaced by dnstm-dnstt
        "microsocks-slip"        # replaced by microsocks-slip-public
    )
    for svc in "${legacy_svcs[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null \
           && systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            warn "Disabling legacy service: ${svc}"
            systemctl disable --now "${svc}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        fi
    done
    systemctl daemon-reload 2>/dev/null || true
}

wizard_run_install() {
    install_deps
    install_bundled_binaries
    cleanup_legacy_services

    [[ $INSTALL_MDNS   == 1 ]] && setup_masterdnsvpn
    [[ $INSTALL_SLIP   == 1 ]] && setup_slipstream
    [[ "${INSTALL_SSH_TUNNEL:-0}" == 1 ]] && setup_ssh_tunnel_user
    [[ "${INSTALL_SSLH_MUX:-0}" == 1 ]]  && setup_sslh_mux
    [[ $INSTALL_DNSTT  == 1 ]] && setup_dnstt
    [[ $INSTALL_VAYDNS == 1 ]] && setup_vaydns
    [[ $INSTALL_STORMDNS == 1 ]] && setup_stormdns

    # Always set up dnstm router
    setup_dnstm

    [[ "${CF_PROVISION:-0}" == 1 ]] && cf_provision_from_selection

    echo ""
    section "Installation Complete"
    print_client_configs
}

# ════════════════════════════════════════════════════════════
#  SERVICE CONTROL MENU
# ════════════════════════════════════════════════════════════

service_control_menu() {
    local services=(
        "masterdnsvpn"
        "dnstm-slip-socks"
        "microsocks-slip-public"
        "microsocks"
        "dnstm-dnstt"
        "microsocks-noauth"
        "sslh-mux"
        "vaydns-server"
        "stormdns"
        "dnstm-dnsrouter"
    )

    while true; do
        draw_banner
        section "Service Control"
        echo ""
        local i=1
        for svc in "${services[@]}"; do
            local state; state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            local icon
            [[ "$state" == "active" ]] && icon="${C_GREEN}●${C_RESET}" || icon="${C_RED}○${C_RESET}"
            printf "  ${icon} %2d) %-32s ${C_DIM}%s${C_RESET}\n" "$i" "$svc" "$state"
            ((i++))
        done
        echo ""
        printf "  ${C_DIM}%3s) %s${C_RESET}\n" "b" "Back to main menu"
        echo ""
        echo -en "  ${C_WHITE}Select service [1-${#services[@]}]:${C_RESET} "
        local choice; read -r choice
        [[ "$choice" == "b" || "$choice" == "B" ]] && break
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#services[@]} )); then
            local svc="${services[$((choice-1))]}"
            echo ""
            echo -e "  ${C_BOLD}${svc}${C_RESET}"
            echo ""
            printf "  1) Start    2) Stop    3) Restart    4) Logs    5) Back\n"
            echo ""
            echo -en "  ${C_WHITE}Action:${C_RESET} "
            local action; read -r action
            case "$action" in
                1) systemctl start   "$svc" && info "Started $svc" || warn "Failed" ;;
                2) systemctl stop    "$svc" && info "Stopped $svc" || warn "Failed" ;;
                3) systemctl restart "$svc" && info "Restarted $svc" || warn "Failed" ;;
                4) echo ""; journalctl -u "$svc" -n 40 --no-pager; echo "" ;;
                *) ;;
            esac
            press_enter
        fi
    done
}

# ════════════════════════════════════════════════════════════
#  CREDENTIALS UPDATE MENU
# ════════════════════════════════════════════════════════════

update_credentials_menu() {
    draw_banner
    section "Update SOCKS5 Credentials"
    echo ""
    echo -e "  ${C_DIM}Changes will be applied to all running tunnels.${C_RESET}"
    echo ""

    ask TUNNEL_USER "New username (empty = remove auth)" ""
    if [[ -n "$TUNNEL_USER" ]]; then
        ask_pass TUNNEL_PASS "New password"
        if [[ -z "$TUNNEL_PASS" ]]; then
            warn "Empty password — no-auth will be used."
            TUNNEL_USER=""
        fi
    fi

    SOCKS_USER="${TUNNEL_USER:-changeme}"
    SOCKS_PASS="${TUNNEL_PASS:-changeme123}"

    echo ""
    if ask_yn "Apply credentials and restart tunnel services?" "y"; then
        # Rewrite MasterDnsVPN config
        if [[ -f "${MDNS_INSTALL_DIR}/server_config.toml" ]]; then
            write_masterdnsvpn_config
            systemctl restart masterdnsvpn 2>/dev/null && info "masterdnsvpn restarted" || true
        fi

        # Slipstream uses authenticated microsocks-slip-public on :58077
        # Restart both private and public microsocks instances with new credentials
        for svc in microsocks microsocks-slip-public; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                # Update credentials in unit file ExecStart
                sed -i "s/-u [^ ]* -P [^ ]*/-u ${SOCKS_USER} -P ${SOCKS_PASS}/" \
                    "/etc/systemd/system/${svc}.service" 2>/dev/null || true
                systemctl daemon-reload
                systemctl restart "$svc" 2>/dev/null && info "${svc} restarted" || true
            fi
        done

        # dnstt always uses no-auth microsocks (microsocks-noauth on :58078) — no credential update needed

        info "Credentials updated on all tunnels."
    fi
    press_enter
}

# ════════════════════════════════════════════════════════════
#  MAIN MENU
# ════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        draw_banner

        # Quick status bar
        local mdns_st slip_st dnstt_st vaydns_st stormdns_st router_st sslh_st
        systemctl is-active --quiet masterdnsvpn    2>/dev/null && mdns_st="${C_GREEN}●${C_RESET}" || mdns_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet dnstm-slip-socks 2>/dev/null && slip_st="${C_GREEN}●${C_RESET}" || slip_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet dnstm-dnstt      2>/dev/null && dnstt_st="${C_GREEN}●${C_RESET}" || dnstt_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet vaydns-server    2>/dev/null && vaydns_st="${C_GREEN}●${C_RESET}" || vaydns_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet stormdns         2>/dev/null && stormdns_st="${C_GREEN}●${C_RESET}" || stormdns_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet dnstm-dnsrouter  2>/dev/null && router_st="${C_GREEN}●${C_RESET}" || router_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet sslh-mux         2>/dev/null && sslh_st="${C_GREEN}●${C_RESET}" || sslh_st="${C_RED}○${C_RESET}"

        echo -e "  ${C_DIM}Tunnels: ${mdns_st} MasterDnsVPN  ${slip_st} Slipstream  ${dnstt_st} dnstt  ${vaydns_st} VayDNS  ${stormdns_st} StormDNS  ${router_st} Router  ${sslh_st} sslh${C_RESET}"
        echo ""
        hr
        echo ""
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  1  "Install / Reinstall tunnels  (wizard)"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  2  "Show service status"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  3  "Manage services  (start / stop / logs)"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  4  "Show client configs"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  5  "Update SOCKS5 credentials"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  6  "Install MasterDnsVPN only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  7  "Install Slipstream only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  8  "Install dnstt only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  9  "Install VayDNS only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n" 10  "Install StormDNS only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n" 11  "Set up middle-proxy  (Iranian VPS)"
        printf "  ${C_DIM}%3s) %s${C_RESET}\n"    "q" "Quit"
        echo ""
        hr
        echo ""
        echo -en "  ${C_WHITE}Choose [1-11 / q]:${C_RESET} "
        local choice; read -r choice

        case "$choice" in
            1)
                wizard_collect_inputs
                wizard_run_install
                press_enter
                ;;
            2)
                show_status
                press_enter
                ;;
            3)
                service_control_menu
                ;;
            4)
                print_client_configs
                press_enter
                ;;
            5)
                update_credentials_menu
                ;;
            6)
                draw_banner
                echo ""
                ask MDNS_DOMAIN  "MasterDnsVPN domain" "${MDNS_DOMAIN}"
                ask TUNNEL_USER  "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-changeme}"
                SOCKS_PASS="${TUNNEL_PASS:-changeme123}"
                install_deps
                setup_masterdnsvpn
                print_client_configs
                press_enter
                ;;
            7)
                draw_banner
                echo ""
                ask SLIP_DOMAIN  "Slipstream domain" "${SLIP_DOMAIN}"
                ask TUNNEL_USER  "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-changeme}"
                SOCKS_PASS="${TUNNEL_PASS:-changeme123}"
                install_deps
                install_bundled_binaries
                setup_slipstream
                press_enter
                ;;
            8)
                draw_banner
                echo ""
                ask DNSTT_DOMAIN "dnstt domain" "${DNSTT_DOMAIN}"
                ask TUNNEL_USER  "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-changeme}"
                SOCKS_PASS="${TUNNEL_PASS:-changeme123}"
                INSTALL_SSLH_MUX=0
                echo -e "  ${C_DIM}sslh auto-detects SSH vs SOCKS5 — one tunnel, two protocols${C_RESET}"
                ask_yn "Enable SSH+SOCKS5 multiplexer (sslh)" "y" && INSTALL_SSLH_MUX=1 || INSTALL_SSLH_MUX=0
                if [[ $INSTALL_SSLH_MUX == 1 ]]; then
                    ask_yn "Set up SSH tunnel user (tunneluser)" "y" && {
                        setup_ssh_tunnel_user
                    }
                    setup_sslh_mux
                fi
                install_deps
                install_bundled_binaries
                setup_dnstt
                print_client_configs
                press_enter
                ;;
            9)
                draw_banner
                echo ""
                ask VAYDNS_DOMAIN "VayDNS domain" "${VAYDNS_DOMAIN}"
                ask TUNNEL_USER   "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-}"
                SOCKS_PASS="${TUNNEL_PASS:-}"
                install_deps
                install_bundled_binaries
                setup_vaydns
                print_client_configs
                press_enter
                ;;
            10)
                draw_banner
                echo ""
                ask STORMDNS_DOMAIN "StormDNS domain" "${STORMDNS_DOMAIN}"
                install_deps
                install_bundled_binaries
                setup_stormdns
                print_client_configs
                press_enter
                ;;
            11)
                draw_banner
                echo ""
                ask MDNS_DOMAIN     "MasterDnsVPN domain" "${MDNS_DOMAIN}"
                ask SLIP_DOMAIN     "Slipstream domain"   "${SLIP_DOMAIN}"
                ask DNSTT_DOMAIN    "dnstt domain"        "${DNSTT_DOMAIN}"
                ask VAYDNS_DOMAIN   "VayDNS domain"       "${VAYDNS_DOMAIN}"
                ask STORMDNS_DOMAIN "StormDNS domain"     "${STORMDNS_DOMAIN}"
                setup_middle_proxy
                press_enter
                ;;
            q|Q)
                echo ""
                echo -e "  ${C_DIM}Bye.${C_RESET}"
                echo ""
                exit 0
                ;;
            *)
                ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════

MODE="${1:-menu}"

case "$MODE" in
    menu)                main_menu ;;
    install)             wizard_collect_inputs; wizard_run_install ;;
    masterdnsvpn)        install_deps; cleanup_legacy_services; setup_masterdnsvpn; print_client_configs ;;
    slipstream)          install_deps; install_bundled_binaries; cleanup_legacy_services; setup_slipstream ;;
    dnstt)               install_deps; install_bundled_binaries; cleanup_legacy_services; setup_dnstt; print_client_configs ;;
    vaydns)              install_deps; install_bundled_binaries; cleanup_legacy_services; setup_vaydns; print_client_configs ;;
    stormdns)            install_deps; install_bundled_binaries; cleanup_legacy_services; setup_stormdns; print_client_configs ;;
    dnstm)               install_deps; install_bundled_binaries; cleanup_legacy_services; setup_dnstm ;;
    status)              show_status ;;
    client-config)       print_client_configs ;;
    middle-proxy)        setup_middle_proxy ;;
    cloudflare-dns)
        # Provision Cloudflare NS delegations for tunnel domains.
        # Usage:
        #   CF_API_TOKEN=... ./setup.sh cloudflare-dns <sub1> [sub2 ...]
        #   CF_EMAIL=... CF_API_KEY=... ./setup.sh cloudflare-dns a.foo.com b.foo.com
        # With no args, falls back to the MDNS/SLIP/DNSTT/VAYDNS/STORMDNS env defaults
        # (skipping any still set to *.example.com).
        shift
        if ! cf_has_creds; then
            error "Set CF_API_TOKEN (or CF_EMAIL + CF_API_KEY) before running this mode."
        fi
        if [[ $# -gt 0 ]]; then
            cf_provision_dns "$SERVER_IP" "$@"
        else
            local _doms=()
            [[ "$MDNS_DOMAIN"     != *example.com ]] && _doms+=("$MDNS_DOMAIN")
            [[ "$SLIP_DOMAIN"     != *example.com ]] && _doms+=("$SLIP_DOMAIN")
            [[ "$DNSTT_DOMAIN"    != *example.com ]] && _doms+=("$DNSTT_DOMAIN")
            [[ "$VAYDNS_DOMAIN"   != *example.com ]] && _doms+=("$VAYDNS_DOMAIN")
            [[ "$STORMDNS_DOMAIN" != *example.com ]] && _doms+=("$STORMDNS_DOMAIN")
            [[ ${#_doms[@]} -eq 0 ]] && error "No domains. Pass them as args or set *_DOMAIN env vars."
            cf_provision_dns "$SERVER_IP" "${_doms[@]}"
        fi
        ;;
    *)
        echo ""
        echo "  DNS Tunnel Kit — Credits: github.com/mrvcoder"
        echo ""
        echo "  Usage:  $0 [mode]"
        echo "  No mode → interactive menu"
        echo ""
        echo "  Modes:"
        printf "    %-18s  %s\n" "menu"          "Interactive menu (default)"
        printf "    %-18s  %s\n" "install"        "Guided install wizard"
        printf "    %-18s  %s\n" "masterdnsvpn"   "Install MasterDnsVPN only"
        printf "    %-18s  %s\n" "slipstream"     "Install Slipstream only"
        printf "    %-18s  %s\n" "dnstt"          "Install dnstt only"
        printf "    %-18s  %s\n" "vaydns"         "Install VayDNS only"
        printf "    %-18s  %s\n" "stormdns"       "Install StormDNS only"
        printf "    %-18s  %s\n" "status"         "Show service status"
        printf "    %-18s  %s\n" "client-config"  "Print all client configs"
        printf "    %-18s  %s\n" "middle-proxy"   "Iranian VPS DNS multiplexer"
        printf "    %-18s  %s\n" "cloudflare-dns" "Provision NS delegations on Cloudflare"
        echo ""
        echo "  Env overrides: TUNNEL_USER, TUNNEL_PASS, MDNS_DOMAIN, SLIP_DOMAIN, DNSTT_DOMAIN, VAYDNS_DOMAIN, STORMDNS_DOMAIN"
        echo "  Cloudflare:    CF_API_TOKEN  (or CF_EMAIL + CF_API_KEY), CF_NS_GLUE_LABEL (default 'dns'), CF_RECORD_TTL (default 60)"
        echo ""
        ;;
esac
