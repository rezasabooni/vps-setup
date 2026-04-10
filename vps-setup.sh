#!/bin/bash
# =============================================================================
# VPS Automated Setup Script
# Version: 4.0 (April 2026)
# Author: Reza Sabooni — https://github.com/rezasabooni/vps-setup
#
# Usage:  sudo bash vps-setup.sh [--dry-run]
#
# Features:
#   • 6-category menu system with sub-menus
#   • Smart root/user split: system installs as root, configs go to REAL_USER
#   • Fastest APT mirror via latency test — writes sources.list automatically
#   • Full browser suite with Xorg low-RAM optimizations
#   • VPN: dnstm, SlipGate, NoizDNS, reality-ezpz, 3x-ui, cloudflared, ttyd
#   • Proxy/net: proxychains-ng (auto-config from tunnel), tun2socks, UFW, fail2ban, Docker
#   • Browsers: Epiphany, Midori, NetSurf, Dillo, Firefox ESR, Chromium, Lynx, w3m
#   • Xorg: disable compositing/MIT-SHM, force swrast, Openbox WM (low-RAM)
#   • AI: aichat, Grok CLI, Gemini CLI
#   • Security: SSH hardening, sudo user creation, CrowdSec, credential archive
#   • Logging to /var/log/vps-setup.log | Outputs to /root/vps-setup-output/
# =============================================================================

set -uo pipefail

# ─── FLAGS ────────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) echo "Usage: sudo bash vps-setup.sh [--dry-run]"; exit 0 ;;
    esac
done

# ─── ROOT CHECK ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run as root.  Use: sudo bash vps-setup.sh"
    exit 1
fi

# ─── REAL USER DETECTION ──────────────────────────────────────────────────────
# Find the actual human user even when invoked via sudo
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER=$(getent passwd | awk -F: '$3>=1000 && $7!~/nologin|false/ {print $1; exit}')
fi
REAL_USER="${REAL_USER:-root}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "0")
CONDA_ENV="$REAL_USER"

# ─── CONSTANTS ────────────────────────────────────────────────────────────────
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
VERSION="4.0"
LOG_FILE="/var/log/vps-setup.log"
OUTPUT_DIR="/root/vps-setup-output"

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ─── INIT ─────────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR" && chmod 700 "$OUTPUT_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== VPS Setup v${VERSION} started $(date) | REAL_USER=${REAL_USER} ===" >> "$LOG_FILE"

# ─── HELPERS ──────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }
info()    { echo -e "${CYAN}ℹ  $*${RESET}";   log "INFO: $*"; }
ok()      { echo -e "${GREEN}✓  $*${RESET}";  log "OK:   $*"; }
warn()    { echo -e "${YELLOW}⚠  $*${RESET}"; log "WARN: $*"; }
err()     { echo -e "${RED}✗  $*${RESET}";    log "ERR:  $*"; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${RESET}"; log "=== $* ==="; }

run() {
    log "RUN: $*"
    if $DRY_RUN; then echo -e "${DIM}  [dry-run] $*${RESET}"; return 0; fi
    "$@" >> "$LOG_FILE" 2>&1
}

run_user() {
    log "RUN_USER($REAL_USER): $*"
    if $DRY_RUN; then echo -e "${DIM}  [dry-run as $REAL_USER] $*${RESET}"; return 0; fi
    su - "$REAL_USER" -s /bin/bash -c "$*" >> "$LOG_FILE" 2>&1
}

spin() {
    local desc="$1"; shift
    if $DRY_RUN; then echo -e "${DIM}  [dry-run] $desc${RESET}"; return 0; fi
    local pid chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    log "SPIN: $desc"
    "$@" >> "$LOG_FILE" 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${RESET} %s" "${chars:$((i%10)):1}" "$desc"
        sleep 0.1; ((i++)) || true
    done
    printf "\r"
    wait "$pid" && ok "$desc" || { err "$desc failed — see $LOG_FILE"; return 1; }
}

check_cmd() { command -v "$1" &>/dev/null; }

confirm() {
    echo -ne "${YELLOW}${1:-Continue?} [y/N] ${RESET}"
    read -r ans; [[ "$ans" =~ ^[Yy]$ ]]
}

pause() { echo -e "\n${DIM}Press Enter to return...${RESET}"; read -r; }

detect_socks_port() {
    ss -tlnp 2>/dev/null | grep -oP '(?<=:)(1080|1081|8080|9050|10808)(?=\s)' | head -1
}

# ─── SUBMENU HELPER ───────────────────────────────────────────────────────────
run_submenu() {
    local title="$1"; shift
    local -a items=("$@")
    while true; do
        echo -e "\n${BOLD}${MAGENTA}╔══ ${title} ══╗${RESET}"
        local i=1
        for item in "${items[@]}"; do
            echo -e "  ${CYAN}${i})${RESET} ${item}"; ((i++))
        done
        echo -e "  ${RED}0)${RESET} Back"
        echo -ne "Choice: "; read -r c
        # Dispatch: item N calls function at index N from _SUBMENU_FUNCS
        # Caller sets _SUBMENU_FUNCS before calling run_submenu
        if [[ "$c" == "0" ]]; then return; fi
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -le "${#_SUBMENU_FUNCS[@]}" ]]; then
            "${_SUBMENU_FUNCS[$((c-1))]}" || true
            pause
        else
            err "Invalid choice."
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# STATUS
# ═════════════════════════════════════════════════════════════════════════════
show_status() {
    section "Status"
    echo -e "  RAM: ${RAM_MB}MB | User: ${REAL_USER} (uid=${REAL_UID}) | Home: ${REAL_HOME}"
    echo -e "\n  ${BOLD}Tools:${RESET}"
    local -A checks=(
        [dnstm]=dnstm [slipgate]=slipgate [noizdns]=noizdns [3x-ui]=x-ui
        [cloudflared]=cloudflared [ttyd]=ttyd [proxychains]=proxychains4
        [tun2socks]=tun2socks [fail2ban]=fail2ban-client [docker]=docker
        [ufw]=ufw [fish]=fish [aichat]=aichat [gemini]=gemini [grok]=grok
        [epiphany]=epiphany [midori]=midori [firefox-esr]=firefox-esr
        [chromium]=chromium [netsurf]=netsurf-gtk [dillo]=dillo [lynx]=lynx [w3m]=w3m
    )
    for label in "${!checks[@]}"; do
        local cmd="${checks[$label]}"
        check_cmd "$cmd" \
            && echo -e "    ${GREEN}✓${RESET} $label" \
            || echo -e "    ${DIM}–${RESET} $label"
    done | sort

    echo -e "\n  ${BOLD}Memory:${RESET}"
    free -h | grep -E 'Mem|Swap' | awk '{printf "    %-6s total=%-8s used=%-8s free=%s\n",$1,$2,$3,$4}'
    [[ -f /swapfile ]] && echo -e "    ${GREEN}✓${RESET} swapfile" || echo -e "    ${DIM}–${RESET} swapfile"

    local sp; sp=$(detect_socks_port)
    [[ -n "$sp" ]] \
        && echo -e "\n  ${GREEN}✓${RESET} Active SOCKS tunnel on port $sp" \
        || echo -e "\n  ${DIM}–${RESET} No SOCKS tunnel detected"

    echo -e "\n  ${BOLD}Services:${RESET}"
    for svc in ufw fail2ban docker x-ui cloudflared; do
        systemctl is-active --quiet "$svc" 2>/dev/null \
            && echo -e "    ${GREEN}✓${RESET} $svc" \
            || echo -e "    ${DIM}–${RESET} $svc"
    done
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# CAT 1: VPN / TUNNEL
# ═════════════════════════════════════════════════════════════════════════════
t_dnstm() {
    section "dnstm — SamNet-dev"
    info "https://github.com/SamNet-dev/dnstm-setup (updated days ago)"
    info "Protocols: Slipstream, DNSTT, NoizDNS, VayDNS. Press h for help."
    if ! $DRY_RUN; then
        curl -fsSL -o /tmp/dnstm-setup.sh \
            https://raw.githubusercontent.com/SamNet-dev/dnstm-setup/master/dnstm-setup.sh
        chmod +x /tmp/dnstm-setup.sh && /tmp/dnstm-setup.sh
    else echo -e "${DIM}  [dry-run]${RESET}"; fi
}

t_slipgate() {
    section "SlipGate — unified tunnel manager"
    info "https://github.com/anonvector/slipgate"
    spin "Installing SlipGate" bash -c \
        "curl -fsSL https://raw.githubusercontent.com/anonvector/slipgate/main/install.sh | bash"
    ok "Run: slipgate --help"
}

t_noizdns() {
    section "NoizDNS deploy"
    info "https://github.com/anonvector/noizdns-deploy"
    warn "Requires domain with A + NS records pointing to this server IP."
    if ! $DRY_RUN; then
        bash <(curl -Ls \
            https://raw.githubusercontent.com/anonvector/noizdns-deploy/main/noizdns-deploy.sh)
    else echo -e "${DIM}  [dry-run]${RESET}"; fi
}

t_realityez() {
    section "reality-ezpz (VLESS/Reality + sing-box)"
    info "https://github.com/aleskxyz/reality-ezpz | 1.5k stars, actively maintained"
    if ! $DRY_RUN; then
        bash <(curl -sL https://bit.ly/realityez) || \
        bash <(curl -sL https://raw.githubusercontent.com/aleskxyz/reality-ezpz/master/reality-ezpz.sh)
    else echo -e "${DIM}  [dry-run]${RESET}"; fi
}

t_3xui() {
    section "3x-ui — Xray web panel"
    info "https://github.com/MHSanaei/3x-ui | Supports VMess, VLESS, Trojan, Shadowsocks, WireGuard"
    info "Web panel on port 2053. Change default credentials immediately after install."
    if ! $DRY_RUN; then
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
        echo "3x-ui panel: http://$(curl -4s ifconfig.me 2>/dev/null):2053" \
            > "$OUTPUT_DIR/3xui-access.txt"
        chmod 600 "$OUTPUT_DIR/3xui-access.txt"
    else echo -e "${DIM}  [dry-run]${RESET}"; fi
    ok "Access: http://YOUR_IP:2053 — saved to $OUTPUT_DIR/3xui-access.txt"
}

t_cloudflared() {
    section "cloudflared — Cloudflare tunnel"
    info "No open ports needed. Exposes local services via Cloudflare."
    spin "Installing cloudflared" bash -c "
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
            https://pkg.cloudflare.com/cloudflared any main' \
            > /etc/apt/sources.list.d/cloudflared.list
        apt update -qq && apt install -y cloudflared
    "
    ok "Quick tunnel: cloudflared tunnel --url http://localhost:PORT"
    ok "Named tunnel: cloudflared tunnel login && cloudflared tunnel create myname"
}

t_ttyd() {
    section "ttyd — terminal as HTTPS webpage"
    info "https://github.com/tsl0922/ttyd — pair with cloudflared for remote terminal"
    if ! $DRY_RUN; then
        local URL
        URL=$(curl -fsSL https://api.github.com/repos/tsl0922/ttyd/releases/latest \
            | grep browser_download_url | grep linux.x86_64 | head -1 | cut -d'"' -f4)
        curl -fsSL "$URL" -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd
    else echo -e "${DIM}  [dry-run]${RESET}"; fi
    ok "Start: ttyd -p 7681 bash"
    info "Tunnel: cloudflared tunnel --url http://localhost:7681"
}

menu_vpn() {
    local _SUBMENU_FUNCS=(t_dnstm t_slipgate t_noizdns t_realityez t_3xui t_cloudflared t_ttyd)
    local items=(
        "dnstm wizard — Slipstream/DNSTT/NoizDNS/VayDNS (SamNet-dev)"
        "SlipGate — unified DNS tunnel manager (anonvector)"
        "NoizDNS — standalone DNSTT + NoizDNS deploy"
        "reality-ezpz — VLESS/Reality + sing-box (aleskxyz)"
        "3x-ui — Xray web panel (VMess/VLESS/Trojan/SS/WG)"
        "cloudflared — Cloudflare tunnel (no firewall ports needed)"
        "ttyd — terminal-as-HTTPS-webpage"
    )
    run_submenu "VPN / TUNNEL" "${items[@]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# CAT 2: PROXY / NETWORK
# ═════════════════════════════════════════════════════════════════════════════
t_proxychains() {
    section "proxychains-ng"
    spin "Installing proxychains4" apt install -y proxychains4
    local PORT; PORT=$(detect_socks_port); PORT="${PORT:-1080}"
    ok "Auto-detected SOCKS port: $PORT"
    if ! $DRY_RUN; then
        local CONF="/etc/proxychains4.conf"
        cp "$CONF" "${CONF}.bak" 2>/dev/null || true
        cat > "$CONF" <<EOF
# proxychains-ng — auto-configured by vps-setup v${VERSION}
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
localnet 127.0.0.0/255.0.0.0
localnet 10.0.0.0/255.0.0.0
localnet 172.16.0.0/255.240.0.0
localnet 192.168.0.0/255.255.0.0

[ProxyList]
socks5  127.0.0.1 ${PORT}
EOF
    fi
    ok "Config written. Usage: proxychains4 <command>"
    info "Example: proxychains4 epiphany-browser"
}

t_tun2socks() {
    section "tun2socks — system-wide SOCKS routing"
    info "Routes ALL traffic through SOCKS5. Run after your tunnel is up."
    local PORT; PORT=$(detect_socks_port); PORT="${PORT:-1080}"
    spin "Installing tun2socks" bash -c "
        URL=\$(curl -fsSL https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest \
            | grep browser_download_url | grep linux-amd64 | grep -v sha | head -1 | cut -d'\"' -f4)
        if [[ -n \"\$URL\" ]]; then
            curl -fsSL \"\$URL\" -o /tmp/tun2socks.zip
            unzip -qo /tmp/tun2socks.zip -d /tmp/t2s/
            install -m755 /tmp/t2s/tun2socks* /usr/local/bin/tun2socks 2>/dev/null || \
                install -m755 /tmp/t2s/* /usr/local/bin/tun2socks
            rm -rf /tmp/tun2socks.zip /tmp/t2s/
        fi
    "
    if ! $DRY_RUN; then
        cat > /usr/local/bin/start-tun2socks.sh <<EOF
#!/bin/bash
# System-wide SOCKS5 routing via tun2socks
# Requires: tunnel running on 127.0.0.1:${PORT}
ip tuntap add mode tun dev tun0 2>/dev/null || true
ip addr add 198.18.0.1/15 dev tun0 2>/dev/null || true
ip link set dev tun0 up
ip route add default dev tun0 metric 1
exec tun2socks -device tun0 -proxy socks5://127.0.0.1:${PORT}
EOF
        chmod +x /usr/local/bin/start-tun2socks.sh
    fi
    ok "Script: /usr/local/bin/start-tun2socks.sh"
    warn "This replaces the default route. Kill with Ctrl+C and reset routes manually."
}

t_ufw() {
    section "UFW firewall"
    spin "Installing UFW" apt install -y ufw
    local SSH_PORT
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oP '(?<=:)\d+' | head -1)
    SSH_PORT="${SSH_PORT:-22}"
    [[ "$SSH_PORT" != "22" ]] && warn "SSH on non-standard port $SSH_PORT — adding rule."
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow "${SSH_PORT}/tcp"  comment "SSH"
    run ufw allow 443/tcp            comment "HTTPS"
    run ufw allow 53/udp             comment "DNS-tunnel"
    run ufw allow 53/tcp             comment "DNS-tunnel-TCP"
    run ufw --force enable
    ok "UFW active. SSH port ${SSH_PORT} allowed."
}

t_fail2ban() {
    section "fail2ban — SSH brute-force protection"
    spin "Installing fail2ban" apt install -y fail2ban
    if ! $DRY_RUN; then
        cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
EOF
        systemctl enable --now fail2ban >> "$LOG_FILE" 2>&1
    fi
    ok "fail2ban: 5 failed attempts = 1h ban."
}

t_docker() {
    section "Docker"
    check_cmd docker && { warn "Already installed: $(docker --version)"; return; }
    spin "Installing Docker" bash -c "curl -fsSL https://get.docker.com | bash"
    run usermod -aG docker "$REAL_USER"
    ok "Docker installed. Re-login as $REAL_USER to use without sudo."
}

menu_proxy() {
    local _SUBMENU_FUNCS=(t_proxychains t_tun2socks t_ufw t_fail2ban t_docker)
    local items=(
        "proxychains-ng — route apps through SOCKS (auto-detect tunnel port)"
        "tun2socks — route ALL traffic through SOCKS5 (system-wide)"
        "UFW firewall — ports 22/443/53 (SSH port auto-detected)"
        "fail2ban — SSH brute-force protection"
        "Docker — install from get.docker.com"
    )
    run_submenu "PROXY / NETWORK" "${items[@]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# CAT 3: BROWSER / GUI
# ═════════════════════════════════════════════════════════════════════════════
t_xorg_base() {
    section "Xorg + Openbox WM (low-RAM base)"
    warn "Install this first before any GUI browser."
    spin "Installing minimal Xorg + Openbox" \
        apt install -y --no-install-recommends xorg xinit openbox xterm dbus-x11
    if ! $DRY_RUN; then
        cat > "${REAL_HOME}/.xinitrc" <<'EOF'
#!/bin/sh
xset s off; xset -dpms; xset b off
exec openbox-session
EOF
        chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.xinitrc"
        chmod +x "${REAL_HOME}/.xinitrc"
    fi
    ok "Start X: run 'startx' as $REAL_USER. Right-click desktop for Openbox menu."
}

t_xorg_optimize() {
    section "Xorg low-RAM optimizations"
    info "Applies: disable MIT-SHM, disable compositing, force software rendering (swrast)."
    info "Fix for Xorg eating RAM on VPS — confirmed working by community."
    if ! $DRY_RUN; then
        mkdir -p /etc/X11/xorg.conf.d/
        cat > /etc/X11/xorg.conf.d/10-vps-low-ram.conf <<'EOF'
# VPS low-RAM config — vps-setup
# Disable MIT-SHM: known cause of Xorg RAM bloat on VPS
Section "Extensions"
    Option "MIT-SHM"   "disable"
    Option "Composite" "disable"
EndSection

Section "ServerFlags"
    Option "Xinerama" "false"
    Option "AIGLX"    "false"
EndSection

# Use fbdev or vesa (software) — avoids GPU driver memory overhead
Section "Device"
    Identifier "VPS-Display"
    Driver     "fbdev"
    Option     "AccelMethod" "none"
EndSection
EOF
        # Force software OpenGL rendering (no GPU driver needed)
        grep -q LIBGL_ALWAYS_SOFTWARE /etc/environment 2>/dev/null || \
            echo 'LIBGL_ALWAYS_SOFTWARE=1' >> /etc/environment
        echo 'export LIBGL_ALWAYS_SOFTWARE=1' >> "${REAL_HOME}/.profile"
        chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.profile"

        # Openbox: no animations, no effects
        mkdir -p "${REAL_HOME}/.config/openbox"
        cat > "${REAL_HOME}/.config/openbox/rc.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <n>Bear2</n>
    <titleLayout>NLIMC</titleLayout>
    <keepBorder>yes</keepBorder>
    <animateIconify>no</animateIconify>
  </theme>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <applications/>
</openbox_config>
EOF
        chown -R "$REAL_USER:$REAL_USER" "${REAL_HOME}/.config"
    fi
    ok "Xorg optimized: MIT-SHM off, compositing off, swrast, Openbox animations off."
    warn "Restart X for changes to take effect."
}

t_b_epiphany() {
    section "Epiphany (GNOME Web)"
    info "Best for 1C/1G VPS. WebKit engine. ~80MB RAM. Works with claude.ai."
    spin "Installing Epiphany" \
        apt install -y --no-install-recommends epiphany-browser gstreamer1.0-libav
    ok "Launch: DISPLAY=:0 epiphany-browser"
    info "With proxy: proxychains4 epiphany-browser"
}

t_b_midori() {
    section "Midori browser"
    info "WebKit-based. ~100MB RAM. Modern JS. claude.ai works. Good Epiphany alternative."
    spin "Installing Midori" apt install -y midori 2>/dev/null || {
        warn "Not in apt — trying flatpak..."
        apt install -y flatpak >> "$LOG_FILE" 2>&1
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo >> "$LOG_FILE" 2>&1
        flatpak install -y flathub org.midori_browser.Midori >> "$LOG_FILE" 2>&1
    }
    ok "Launch: DISPLAY=:0 midori"
}

t_b_netsurf() {
    section "NetSurf browser"
    info "Own rendering engine. ~35MB RAM. Very limited JS. Good for static sites, NOT claude.ai."
    spin "Installing NetSurf" apt install -y netsurf-gtk
    ok "Launch: DISPLAY=:0 netsurf-gtk"
}

t_b_dillo() {
    section "Dillo browser"
    info "~10MB RAM. No JS at all. Fastest GUI browser. Static HTML only."
    spin "Installing Dillo" apt install -y dillo
    ok "Launch: DISPLAY=:0 dillo"
}

t_b_firefox() {
    section "Firefox ESR"
    warn "~300MB RAM. Needs 2GB+ for comfortable use. Full claude.ai support."
    info "Installing from Mozilla's official APT repo (not Snap)."
    spin "Adding Mozilla repo + installing Firefox ESR" bash -c "
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
            -o /etc/apt/keyrings/packages.mozilla.org.asc
        echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] \
            https://packages.mozilla.org/apt mozilla main' \
            > /etc/apt/sources.list.d/mozilla.list
        printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
            > /etc/apt/preferences.d/mozilla
        apt update -qq && apt install -y firefox-esr
    "
    # Low-RAM user.js tuning
    if ! $DRY_RUN; then
        mkdir -p "${REAL_HOME}/.mozilla/firefox"
        cat > "${REAL_HOME}/.mozilla/firefox/user.js" <<'EOF'
// Firefox VPS low-RAM tweaks
user_pref("browser.sessionstore.interval", 180000);
user_pref("browser.cache.disk.capacity", 51200);
user_pref("browser.cache.memory.capacity", 32768);
user_pref("gfx.webrender.enabled", false);
user_pref("layers.acceleration.disabled", true);
user_pref("media.hardware-video-decoding.enabled", false);
EOF
        chown -R "$REAL_USER:$REAL_USER" "${REAL_HOME}/.mozilla"
    fi
    ok "Launch: DISPLAY=:0 firefox-esr"
    info "Low-RAM user.js applied (WebRender off, limited cache)."
}

t_b_chromium() {
    section "Chromium browser"
    warn "~350MB RAM. Needs 2GB+. Full claude.ai support."
    spin "Installing Chromium" apt install -y chromium
    ok "Launch: DISPLAY=:0 chromium --no-sandbox --disable-gpu"
    info "With proxy: chromium --no-sandbox --proxy-server=socks5://127.0.0.1:1080"
}

t_b_lynx() {
    section "Lynx (terminal text browser)"
    info "No JS, no GUI. Good for checking pages, APIs, config UIs in terminal."
    spin "Installing Lynx" apt install -y lynx
    ok "Usage: lynx https://example.com"
}

t_b_w3m() {
    section "w3m (terminal browser with image support)"
    info "Better than Lynx for readability. Shows images in compatible terminals."
    spin "Installing w3m" apt install -y w3m w3m-img
    ok "Usage: w3m https://example.com"
}

t_launch_proxy_browser() {
    section "Launch browser via proxychains"
    local PORT; PORT=$(detect_socks_port)
    if [[ -z "$PORT" ]]; then
        err "No active SOCKS tunnel detected. Start a tunnel first."
        return 1
    fi
    ok "Tunnel detected on port $PORT"
    local browsers=("epiphany-browser" "midori" "firefox-esr" "chromium")
    local found=""
    for b in "${browsers[@]}"; do check_cmd "$b" && { found="$b"; break; }; done
    if [[ -z "$found" ]]; then
        err "No GUI browser installed. Install one first."; return 1
    fi
    info "Launching $found through proxychains (port $PORT)..."
    if ! $DRY_RUN; then
        su - "$REAL_USER" -s /bin/bash -c \
            "DISPLAY=:0 proxychains4 $found &" >> "$LOG_FILE" 2>&1
    fi
    ok "Launched $found via proxychains."
}

menu_browser() {
    local _SUBMENU_FUNCS=(
        t_xorg_base t_xorg_optimize
        t_b_epiphany t_b_midori t_b_netsurf t_b_dillo
        t_b_firefox t_b_chromium t_b_lynx t_b_w3m
        t_launch_proxy_browser
    )
    local items=(
        "Xorg + Openbox WM — low-RAM base (install this first)"
        "Xorg low-RAM optimizations (MIT-SHM off, swrast, Openbox no-effects)"
        "Epiphany (GNOME Web) — WebKit, ~80MB, best for claude.ai on 1C/1G"
        "Midori — WebKit, ~100MB, modern JS, good claude.ai alternative"
        "NetSurf — own engine, ~35MB, limited JS (no claude.ai)"
        "Dillo — ~10MB RAM, NO JS (static pages only — fastest)"
        "Firefox ESR — full browser, ~300MB (needs 2GB+)"
        "Chromium — full browser, ~350MB (needs 2GB+)"
        "Lynx — terminal text browser (no GUI, no JS)"
        "w3m — terminal browser with image support"
        "Launch installed browser through proxychains (auto-detect tunnel)"
    )
    run_submenu "BROWSER / GUI" "${items[@]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# CAT 4: SYSTEM & PACKAGES
# ═════════════════════════════════════════════════════════════════════════════
t_fast_mirror() {
    section "Fastest APT mirror"
    info "Testing latency to top mirrors (~30s). Will write sources.list."
    local OS_ID; OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    local CODENAME; CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"')
    CODENAME="${CODENAME:-$(lsb_release -cs 2>/dev/null)}"

    # Try netselect-apt first (Ubuntu only)
    if [[ "$OS_ID" == "ubuntu" ]] && apt-get install -y netselect-apt -qq >> "$LOG_FILE" 2>&1; then
        if ! $DRY_RUN; then
            cp /etc/apt/sources.list /etc/apt/sources.list.bak
            netselect-apt -n -o /etc/apt/sources.list.d/fast-mirror.list \
                "$CODENAME" >> "$LOG_FILE" 2>&1
            apt update -qq >> "$LOG_FILE" 2>&1
        fi
        ok "netselect-apt found best mirror → /etc/apt/sources.list.d/fast-mirror.list"
        return
    fi

    # Manual latency test (works for both Ubuntu + Debian)
    local mirrors=()
    if [[ "$OS_ID" == "ubuntu" ]]; then
        mirrors=(
            "https://archive.ubuntu.com/ubuntu"
            "https://mirror.nl.leaseweb.net/ubuntu"
            "https://ftp.tu-berlin.de/ubuntu"
            "https://mirrors.edge.kernel.org/ubuntu"
            "https://ftp.halifax.rwth-aachen.de/ubuntu"
            "https://ubuntu.mirror.tudos.de/ubuntu"
            "https://mirror.i3d.net/ubuntu"
        )
    else
        mirrors=(
            "https://deb.debian.org/debian"
            "https://ftp.nl.debian.org/debian"
            "https://ftp.de.debian.org/debian"
            "https://mirror.nl.leaseweb.net/debian"
            "https://mirrors.edge.kernel.org/debian"
            "https://debian.mirror.nl.eu.org/debian"
        )
    fi

    local best_url="" best_ms=99999
    echo ""
    for m in "${mirrors[@]}"; do
        local ms
        ms=$(curl -o /dev/null -s -w "%{time_connect}" \
             --connect-timeout 3 "$m" 2>/dev/null | awk '{printf "%.0f", $1*1000}')
        ms="${ms:-9999}"
        printf "    %6sms  %s\n" "$ms" "$m"
        if [[ "$ms" -lt "$best_ms" ]]; then best_ms="$ms"; best_url="$m"; fi
    done

    echo ""
    ok "Best: ${best_url} (${best_ms}ms)"

    if ! $DRY_RUN && [[ -n "$best_url" ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        if [[ "$OS_ID" == "ubuntu" ]]; then
            cat > /etc/apt/sources.list <<EOF
deb ${best_url} ${CODENAME} main restricted universe multiverse
deb ${best_url} ${CODENAME}-updates main restricted universe multiverse
deb ${best_url} ${CODENAME}-security main restricted universe multiverse
EOF
        else
            cat > /etc/apt/sources.list <<EOF
deb ${best_url} ${CODENAME} main contrib non-free non-free-firmware
deb ${best_url} ${CODENAME}-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security ${CODENAME}-security main contrib non-free
EOF
        fi
        apt update -qq >> "$LOG_FILE" 2>&1
        ok "sources.list updated. Backup: /etc/apt/sources.list.bak"
    fi
}

t_swap_zram() {
    section "Swap + ZRAM"
    local SWAP_SIZE ZRAM_SIZE
    if   [[ "$RAM_MB" -le 1024 ]]; then SWAP_SIZE="2G"; ZRAM_SIZE="512M"
    elif [[ "$RAM_MB" -le 2048 ]]; then SWAP_SIZE="3G"; ZRAM_SIZE="768M"
    else                                 SWAP_SIZE="4G"; ZRAM_SIZE="50%"
    fi
    info "RAM=${RAM_MB}MB → Swap=${SWAP_SIZE}, ZRAM=${ZRAM_SIZE}"
    if [[ -f /swapfile ]]; then
        warn "Swapfile already exists — skipping."
    else
        spin "Creating ${SWAP_SIZE} swapfile" bash -c "
            fallocate -l $SWAP_SIZE /swapfile
            chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        "
    fi
    spin "Installing systemd-zram-generator" apt install -y systemd-zram-generator
    if ! $DRY_RUN; then
        cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF
        modprobe zstd 2>/dev/null || true
        systemctl daemon-reload
        systemctl restart systemd-zram-generator.service 2>/dev/null || true
    fi
    ok "Swap + ZRAM configured."
}

t_performance() {
    section "Performance tweaks (BBR + kernel)"
    if ! $DRY_RUN; then
        cat > /etc/sysctl.d/99-vps-performance.conf <<'EOF'
vm.swappiness = 20
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
EOF
        modprobe tcp_bbr 2>/dev/null || true
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-vps-performance.conf >> "$LOG_FILE" 2>&1
    fi
    ok "BBR + VM/TCP tuning applied."
}

t_miniconda() {
    section "Miniconda 3"
    if [[ -x "${REAL_HOME}/miniconda3/bin/conda" ]]; then
        warn "Already installed at ${REAL_HOME}/miniconda3"
    else
        spin "Downloading Miniconda" wget -q \
            "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
            -O /tmp/miniconda.sh
        spin "Installing for $REAL_USER" \
            su - "$REAL_USER" -s /bin/bash -c \
            "bash /tmp/miniconda.sh -b -p ~/miniconda3 && ~/miniconda3/bin/conda init bash"
    fi
    spin "Creating env '$CONDA_ENV' (Python 3.12)" \
        su - "$REAL_USER" -s /bin/bash -c "
            source ~/miniconda3/bin/activate
            conda create -n $CONDA_ENV python=3.12 -y 2>/dev/null || true
            grep -q 'conda activate $CONDA_ENV' ~/.bashrc || \
                echo 'conda activate $CONDA_ENV' >> ~/.bashrc
        "
    ok "Miniconda + env '$CONDA_ENV' ready."
}

t_essentials() {
    section "Essential tools"
    spin "Installing htop ncdu tmux curl git unzip wget jq net-tools" \
        apt install -y htop ncdu tmux curl git unzip wget jq net-tools dnsutils lsof
    ok "Essential tools installed."
}

t_fish() {
    section "Fish shell + Fisher + plugins"
    spin "Installing Fish" apt install -y fish
    if ! $DRY_RUN; then
        chsh -s /usr/bin/fish "$REAL_USER" 2>/dev/null || \
            warn "chsh failed — run manually: chsh -s /usr/bin/fish"
    fi
    spin "Installing Fisher + plugins" \
        su - "$REAL_USER" -s /usr/bin/fish -c '
            curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish \
                | source && fisher install jorgebucaran/fisher
            fisher install \
                PatrickF1/fzf.fish \
                jhillyerd/plugin-git \
                jorgebucaran/fish-bass \
                franciscolourenco/done \
                jethrokuan/z \
                IlanCosman/tide@v6 \
                decors/fish-colored-man
        '
    ok "Fish + plugins ready. Run: exec fish"
}

t_unattended() {
    section "unattended-upgrades"
    spin "Installing" apt install -y unattended-upgrades
    if ! $DRY_RUN; then
        dpkg-reconfigure -plow unattended-upgrades >> "$LOG_FILE" 2>&1 || true
    fi
    ok "Auto security patches enabled."
}

menu_system() {
    local _SUBMENU_FUNCS=(t_fast_mirror t_swap_zram t_performance t_miniconda t_essentials t_fish t_unattended)
    local items=(
        "Fastest APT mirror — latency test + auto-write sources.list"
        "Swap + ZRAM (RAM-aware: ${RAM_MB}MB detected)"
        "Performance tweaks — BBR congestion control + VM/TCP tuning"
        "Miniconda 3 + Python 3.12 env for $REAL_USER"
        "Essential tools — htop, ncdu, tmux, git, curl, jq, dnsutils"
        "Fish shell + Fisher + plugins (fzf, z, tide, git)"
        "unattended-upgrades — auto security patches"
    )
    run_submenu "SYSTEM & PACKAGES" "${items[@]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# CAT 5: AI TOOLS
# ═════════════════════════════════════════════════════════════════════════════
t_aichat() {
    section "aichat — multi-provider AI CLI"
    info "https://github.com/sigoden/aichat | Rust binary, ~0 RAM overhead"
    info "Providers: Anthropic, OpenAI, Groq, Gemini, Ollama, OpenRouter"
    local URL
    URL=$(curl -fsSL "https://api.github.com/repos/sigoden/aichat/releases/latest" 2>/dev/null \
        | grep browser_download_url | grep "x86_64-unknown-linux-musl" \
        | head -1 | cut -d'"' -f4)
    if [[ -z "$URL" ]]; then err "Could not fetch aichat. Check https://github.com/sigoden/aichat"; return 1; fi
    spin "Downloading + installing aichat" bash -c "
        curl -fsSL '$URL' -o /tmp/aichat.tar.gz
        tar -xzf /tmp/aichat.tar.gz -C /tmp/
        install -m755 /tmp/aichat /usr/local/bin/aichat
        rm -f /tmp/aichat.tar.gz /tmp/aichat
    "
    ok "aichat installed. Config: ~/.config/aichat/config.yaml"
    info "Example: aichat --model claude:claude-sonnet-4-6 'Hello!'"
}

t_grok_cli() {
    section "Grok CLI (superagent-ai)"
    info "https://github.com/superagent-ai/grok-cli | 2.3k stars"
    warn "Requires: Bun runtime + free API key from https://x.ai"
    if ! check_cmd bun; then
        spin "Installing Bun runtime" bash -c "curl -fsSL https://bun.sh/install | bash"
        export PATH="$HOME/.bun/bin:$PATH"
        run_user 'echo "export PATH=\"\$HOME/.bun/bin:\$PATH\"" >> ~/.bashrc'
    fi
    spin "Installing grok-cli" \
        su - "$REAL_USER" -s /bin/bash -c \
        'export PATH="$HOME/.bun/bin:$PATH"; bun add -g grok-dev'
    ok "Set GROK_API_KEY then run: grok"
}

t_gemini_cli() {
    section "Gemini CLI (@google/gemini-cli)"
    info "Requires Node.js 18+."
    local NODE_VER; NODE_VER=$(node --version 2>/dev/null | grep -oP 'v\K[0-9]+' || echo 0)
    if [[ "$NODE_VER" -lt 18 ]]; then
        spin "Installing Node.js 20 via NodeSource" bash -c "
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt install -y nodejs
        "
    else ok "Node.js $NODE_VER already OK."; fi
    spin "Installing @google/gemini-cli" npm install -g @google/gemini-cli
    ok "Run: gemini (sign in with Google)"
}

menu_ai() {
    local _SUBMENU_FUNCS=(t_aichat t_grok_cli t_gemini_cli)
    local items=(
        "aichat — multi-provider AI CLI (Anthropic/OpenAI/Groq/Gemini)"
        "Grok CLI — xAI coding agent (requires GROK_API_KEY)"
        "Gemini CLI — @google/gemini-cli (Node.js 20)"
    )
    run_submenu "AI TOOLS" "${items[@]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# CAT 6: SECURITY / HARDENING
# ═════════════════════════════════════════════════════════════════════════════
t_ssh_harden() {
    section "SSH hardening"
    warn "Disables password auth. Ensure your SSH public key is in authorized_keys first!"
    confirm "Proceed?" || { info "Skipped."; return 0; }
    local SSHD="/etc/ssh/sshd_config"
    if ! $DRY_RUN; then
        cp "$SSHD" "${SSHD}.bak.$(date +%Y%m%d%H%M%S)"
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD"
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD"
        sed -i 's/^#*X11Forwarding.*/X11Forwarding yes/' "$SSHD"
        grep -q "MaxAuthTries" "$SSHD" || echo -e "\nMaxAuthTries 3\nClientAliveInterval 300" >> "$SSHD"
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    fi
    ok "SSH hardened (no password auth, root only via key)."
    warn "Test in a NEW terminal before closing this session!"
}

t_save_creds() {
    section "Save system info & credentials"
    if ! $DRY_RUN; then
        local OUT="$OUTPUT_DIR/system-$(date +%Y%m%d-%H%M%S).txt"
        {
            echo "=== VPS Setup v${VERSION} — $(date) ==="
            echo "Hostname: $(hostname)"
            echo "Public IP: $(curl -4s ifconfig.me 2>/dev/null)"
            echo "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
            echo "RAM: ${RAM_MB}MB"
            echo "REAL_USER: $REAL_USER (uid=$REAL_UID)"
            echo ""
            echo "=== Active services ==="
            for svc in ufw fail2ban docker x-ui cloudflared ttyd; do
                systemctl is-active --quiet "$svc" 2>/dev/null \
                    && echo "  $svc: ACTIVE" || echo "  $svc: inactive"
            done
            echo ""
            echo "=== Listening ports ==="
            ss -tlnp 2>/dev/null || true
        } > "$OUT"
        chmod 600 "$OUT"
        ok "Saved: $OUT"
    fi
    info "All output files in $OUTPUT_DIR/:"
    ls -lh "$OUTPUT_DIR/" 2>/dev/null || true
}

t_create_user() {
    section "Create non-root sudo user"
    echo -ne "New username: "; read -r NEW_USER
    [[ -z "$NEW_USER" ]] && { err "Empty username."; return 1; }
    id "$NEW_USER" &>/dev/null && { warn "User $NEW_USER already exists."; return 0; }
    if ! $DRY_RUN; then
        adduser --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        if [[ -f /root/.ssh/authorized_keys ]]; then
            mkdir -p "/home/$NEW_USER/.ssh"
            cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/"
            chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
            chmod 700 "/home/$NEW_USER/.ssh"
            chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
            ok "Root's authorized_keys copied to $NEW_USER."
        fi
    fi
    ok "User $NEW_USER created with sudo access."
}

t_crowdsec() {
    section "CrowdSec — community-driven security"
    info "https://www.crowdsec.net — modern fail2ban alternative"
    spin "Installing CrowdSec" bash -c "
        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
        apt install -y crowdsec crowdsec-firewall-bouncer-iptables
    "
    ok "Run: cscli hub update && cscli collections install crowdsecurity/linux"
}

menu_security() {
    local _SUBMENU_FUNCS=(t_ssh_harden t_save_creds t_create_user t_crowdsec)
    local items=(
        "SSH hardening (disable password auth, root login via key only)"
        "Save credentials & system info to $OUTPUT_DIR/"
        "Create non-root sudo user (copies root SSH keys)"
        "CrowdSec — community-driven intrusion prevention"
    )
    run_submenu "SECURITY / HARDENING" "${items[@]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# RUN ALL (recommended non-interactive core)
# ═════════════════════════════════════════════════════════════════════════════
run_all() {
    warn "Running recommended core tasks. Failures are logged but won't stop the chain."
    local tasks=(t_essentials t_fast_mirror t_swap_zram t_performance t_ufw t_fail2ban t_proxychains t_fish t_aichat)
    for t in "${tasks[@]}"; do $t 2>/dev/null || err "$t failed — continuing."; sleep 1; done
    t_save_creds 2>/dev/null || true
    ok "Core setup done. Log: $LOG_FILE | Output: $OUTPUT_DIR/"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN MENU + STARTUP
# ═════════════════════════════════════════════════════════════════════════════
show_main_menu() {
    local dry_tag=""; $DRY_RUN && dry_tag="${YELLOW} [DRY-RUN]${RESET}"
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗"
    echo -e "║  VPS Setup v${VERSION}  |  RAM: ${RAM_MB}MB  |  User: ${REAL_USER}${dry_tag}"
    echo -e "╠═══════════════════════════════════════════════════════════════╣${RESET}"
    echo -e " ${MAGENTA}1)${RESET}  🔒 VPN / Tunnel      dnstm · SlipGate · reality-ezpz · 3x-ui · cloudflared"
    echo -e " ${MAGENTA}2)${RESET}  🌐 Proxy / Network   proxychains · tun2socks · UFW · fail2ban · Docker"
    echo -e " ${MAGENTA}3)${RESET}  🖥  Browser / GUI     Epiphany · Midori · Firefox · Chromium + Xorg tweaks"
    echo -e " ${MAGENTA}4)${RESET}  ⚙️  System            mirror · swap · fish · miniconda · performance"
    echo -e " ${MAGENTA}5)${RESET}  🤖 AI Tools          aichat · Grok CLI · Gemini CLI"
    echo -e " ${MAGENTA}6)${RESET}  🛡  Security          SSH hardening · user creation · CrowdSec"
    echo -e "${BOLD}╠═══════════════════════════════════════════════════════════════╣${RESET}"
    echo -e " ${GREEN}A)${RESET}  Run recommended core tasks (non-interactive)"
    echo -e " ${CYAN}S)${RESET}  Status — show installed tools & active services"
    echo -e " ${RED}0)${RESET}  Exit"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo -ne "Choice: "
}

# Startup
echo -e "\n${BOLD}🚀 VPS Setup v${VERSION}${RESET}"
echo -e "   Root: $(whoami) | Real user: ${REAL_USER} (${REAL_HOME})"
echo -e "   RAM: ${RAM_MB}MB | Log: ${LOG_FILE} | Output: ${OUTPUT_DIR}/"
$DRY_RUN && warn "DRY-RUN mode — no changes will be made."

if ! $DRY_RUN; then
    echo -ne "\n${DIM}Running apt update...${RESET}"
    apt update -qq >> "$LOG_FILE" 2>&1 && echo -e "\r${GREEN}✓${RESET} apt updated.    " \
        || echo -e "\r${YELLOW}⚠${RESET} apt update had issues (check log)."
fi

while true; do
    show_main_menu
    read -r choice
    case "${choice^^}" in
        1) menu_vpn ;;
        2) menu_proxy ;;
        3) menu_browser ;;
        4) menu_system ;;
        5) menu_ai ;;
        6) menu_security ;;
        A) run_all; pause ;;
        S) show_status; pause ;;
        0) echo -e "\n${GREEN}Done. Log: ${LOG_FILE} | Output: ${OUTPUT_DIR}/${RESET}"; exit 0 ;;
        *) err "Invalid choice '$choice'." ;;
    esac
done
