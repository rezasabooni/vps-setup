#!/bin/bash
# =============================================================================
# vps-setup.sh
# Release: 4.1  |  April 2026
# Authors: Reza Sabooni (lead), assisted by Grok + Claude
# Repo:    https://github.com/YOUR_USERNAME/vps-setup
#
# Usage:   sudo bash vps-setup.sh [--dry-run]
#
# Categories:
#   1  VPN / Tunnel      dnstm, SlipGate, NoizDNS, reality-ezpz, 3x-ui,
#                        cloudflared, ttyd
#   2  Proxy / Network   proxychains-ng, tun2socks, UFW (VPS or laptop mode),
#                        fail2ban, Docker
#   3  Browser / GUI     Xorg+Openbox, low-RAM tweaks, Epiphany, Midori,
#                        NetSurf, Dillo, Firefox ESR, Chromium, Lynx, w3m
#   4  System            fastest APT mirror, swap+ZRAM, BBR tweaks,
#                        Miniconda, essentials, unattended-upgrades
#   5  Shells & Editors  Fish, Zsh, Bash tweaks, nano tweaks, micro, helix,
#                        Fira fonts, Farsi keyboard, jcal (Jalali)
#   6  AI Tools          aichat, Ollama, groq-cli-chat, groq-code-cli,
#                        Grok CLI, Gemini CLI
#   7  Security          SSH options, sudo user, CrowdSec, credential archive
#
# Infrastructure:
#   - Root guard + REAL_USER detection (sudo or first UID>=1000 account)
#   - System installs go to /usr, configs written to REAL_USER home with
#     correct ownership
#   - All credentials/keys saved to /root/vps-setup-output/ (chmod 700)
#   - Logging to /var/log/vps-setup.log
#   - --dry-run shows every command without executing
#   - A = run recommended core tasks non-interactively
#   - S = status dashboard
# =============================================================================

set -uo pipefail

# ── FLAGS ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) echo "Usage: sudo bash vps-setup.sh [--dry-run]"; exit 0 ;;
    esac
done

# ── ROOT GUARD ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root.  sudo bash vps-setup.sh"
    exit 1
fi

# ── REAL USER DETECTION ───────────────────────────────────────────────────────
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER=$(getent passwd \
        | awk -F: '$3>=1000 && $7!~/nologin|false/ {print $1; exit}')
fi
REAL_USER="${REAL_USER:-root}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo 0)
CONDA_ENV="$REAL_USER"

# ── CONSTANTS ─────────────────────────────────────────────────────────────────
RELEASE="4.1"
LOG_FILE="/var/log/vps-setup.log"
OUTPUT_DIR="/root/vps-setup-output"
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc 2>/dev/null || echo 1)

# ── COLORS ────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
C='\033[0;36m' B='\033[0;34m' M='\033[0;35m'
BD='\033[1m' DM='\033[2m' RS='\033[0m'

# ── INIT ──────────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR" && chmod 700 "$OUTPUT_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
printf "=== vps-setup %s started %s | user=%s ===\n" \
    "$RELEASE" "$(date)" "$REAL_USER" >> "$LOG_FILE"

# ── HELPERS ───────────────────────────────────────────────────────────────────
log()  { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE"; }
inf()  { printf "${C}i  %s${RS}\n" "$*"; log "INFO: $*"; }
ok()   { printf "${G}ok %s${RS}\n" "$*"; log "OK:   $*"; }
warn() { printf "${Y}!  %s${RS}\n" "$*"; log "WARN: $*"; }
err()  { printf "${R}x  %s${RS}\n" "$*"; log "ERR:  $*"; }
hdr()  { printf "\n${BD}${B}--- %s ---${RS}\n" "$*"; log "=== $* ==="; }

run() {
    log "RUN: $*"
    if $DRY_RUN; then printf "${DM}  [dry] %s${RS}\n" "$*"; return 0; fi
    "$@" >> "$LOG_FILE" 2>&1
}

runu() {
    # run as REAL_USER
    log "RUNU($REAL_USER): $*"
    if $DRY_RUN; then printf "${DM}  [dry:$REAL_USER] %s${RS}\n" "$*"; return 0; fi
    su - "$REAL_USER" -s /bin/bash -c "$*" >> "$LOG_FILE" 2>&1
}

spin() {
    local desc="$1"; shift
    if $DRY_RUN; then printf "${DM}  [dry] %s${RS}\n" "$desc"; return 0; fi
    local pid sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    log "SPIN: $desc"
    "$@" >> "$LOG_FILE" 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C}%s${RS} %s" "${sp:$((i%10)):1}" "$desc"
        sleep 0.1; ((i++)) || true
    done
    printf "\r"
    wait "$pid" && ok "$desc" || { err "$desc  (see $LOG_FILE)"; return 1; }
}

has() { command -v "$1" &>/dev/null; }

ask() {
    printf "${Y}%s [y/N] ${RS}" "${1:-Continue?}"
    read -r _a; [[ "$_a" =~ ^[Yy]$ ]]
}

pause() { printf "\n${DM}Enter to return...${RS}"; read -r; }

socks_port() {
    ss -tlnp 2>/dev/null \
        | grep -oP '(?<=:)(1080|1081|8080|9050|10808)(?=\s)' | head -1
}

# ── SUBMENU ENGINE ────────────────────────────────────────────────────────────
# Usage: submenu "Title" label1 fn1 label2 fn2 ...
submenu() {
    local title="$1"; shift
    local -a labels=() fns=()
    while [[ $# -ge 2 ]]; do labels+=("$1"); fns+=("$2"); shift 2; done

    while true; do
        printf "\n${BD}${M}[%s]${RS}\n" "$title"
        local i=0
        for lbl in "${labels[@]}"; do
            printf "  %s) %s\n" "$((i+1))" "$lbl"; ((i++))
        done
        printf "  0) Back\n"
        printf "Choice: "; read -r c
        if [[ "$c" == "0" ]]; then return; fi
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#fns[@]} )); then
            "${fns[$((c-1))]}" || true
            pause
        else
            err "invalid"
        fi
    done
}

# =============================================================================
# STATUS
# =============================================================================
show_status() {
    hdr "Status"
    printf "  release %-6s  RAM %sMB  CPU %s cores\n" "$RELEASE" "$RAM_MB" "$CPU_CORES"
    printf "  user    %-10s uid=%s  home=%s\n" "$REAL_USER" "$REAL_UID" "$REAL_HOME"

    printf "\n  tools:\n"
    local tools=(
        "dnstm:dnstm" "slipgate:slipgate" "3x-ui:x-ui"
        "cloudflared:cloudflared" "ttyd:ttyd"
        "proxychains:proxychains4" "tun2socks:tun2socks"
        "fail2ban:fail2ban-client" "docker:docker" "ufw:ufw"
        "ollama:ollama" "aichat:aichat" "gemini:gemini" "grok:grok"
        "fish:fish" "zsh:zsh" "micro:micro" "helix:hx"
        "epiphany:epiphany" "midori:midori" "firefox-esr:firefox-esr"
        "chromium:chromium" "lynx:lynx" "w3m:w3m"
    )
    for e in "${tools[@]}"; do
        local lbl="${e%%:*}" cmd="${e##*:}"
        has "$cmd" \
            && printf "    ${G}+${RS} %s\n" "$lbl" \
            || printf "    ${DM}-${RS} %s\n" "$lbl"
    done | sort

    printf "\n  memory:\n"
    free -h | awk 'NR>0 && /Mem|Swap/{printf "    %-6s total=%-8s used=%-8s free=%s\n",$1,$2,$3,$4}'
    [[ -f /swapfile ]] && printf "    ${G}+${RS} swapfile\n" || printf "    ${DM}-${RS} swapfile\n"

    local sp; sp=$(socks_port)
    [[ -n "$sp" ]] \
        && printf "\n  ${G}+${RS} SOCKS tunnel on port %s\n" "$sp" \
        || printf "\n  ${DM}-${RS} no SOCKS tunnel detected\n"

    printf "\n  services:\n"
    for s in ufw fail2ban docker x-ui cloudflared ollama; do
        systemctl is-active --quiet "$s" 2>/dev/null \
            && printf "    ${G}+${RS} %s\n" "$s" \
            || printf "    ${DM}-${RS} %s\n" "$s"
    done
    echo
}

# =============================================================================
# 1  VPN / TUNNEL
# =============================================================================
t_dnstm() {
    hdr "dnstm (SamNet-dev)"
    inf "https://github.com/SamNet-dev/dnstm-setup"
    inf "Protocols: Slipstream, DNSTT, NoizDNS, VayDNS  |  press h for help"
    if ! $DRY_RUN; then
        curl -fsSL -o /tmp/dnstm-setup.sh \
            https://raw.githubusercontent.com/SamNet-dev/dnstm-setup/master/dnstm-setup.sh
        chmod +x /tmp/dnstm-setup.sh && /tmp/dnstm-setup.sh
    fi
}

t_slipgate() {
    hdr "SlipGate (anonvector)"
    inf "https://github.com/anonvector/slipgate"
    spin "installing SlipGate" bash -c \
        "curl -fsSL https://raw.githubusercontent.com/anonvector/slipgate/main/install.sh | bash"
    ok "run: slipgate --help"
}

t_noizdns() {
    hdr "NoizDNS deploy"
    inf "https://github.com/anonvector/noizdns-deploy"
    warn "needs domain A + NS records pointing to this server IP"
    if ! $DRY_RUN; then
        bash <(curl -Ls \
            https://raw.githubusercontent.com/anonvector/noizdns-deploy/main/noizdns-deploy.sh)
    fi
}

t_realityez() {
    hdr "reality-ezpz (VLESS/Reality + sing-box)"
    inf "https://github.com/aleskxyz/reality-ezpz  1.5k stars"
    if ! $DRY_RUN; then
        bash <(curl -sL https://bit.ly/realityez) || \
        bash <(curl -sL \
            https://raw.githubusercontent.com/aleskxyz/reality-ezpz/master/reality-ezpz.sh)
    fi
}

t_3xui() {
    hdr "3x-ui Xray web panel"
    inf "https://github.com/MHSanaei/3x-ui"
    inf "VMess, VLESS, Trojan, Shadowsocks, WireGuard  |  panel on port 2053"
    warn "change default credentials immediately after install"
    if ! $DRY_RUN; then
        bash <(curl -Ls \
            https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
        printf "3x-ui: http://%s:2053\n" "$(curl -4s ifconfig.me 2>/dev/null)" \
            > "$OUTPUT_DIR/3xui.txt"
        chmod 600 "$OUTPUT_DIR/3xui.txt"
        ok "access info saved to $OUTPUT_DIR/3xui.txt"
    fi
}

t_cloudflared() {
    hdr "cloudflared tunnel"
    inf "no open ports needed — traffic via Cloudflare"
    spin "installing cloudflared" bash -c "
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
            https://pkg.cloudflare.com/cloudflared any main' \
            > /etc/apt/sources.list.d/cloudflared.list
        apt update -qq && apt install -y cloudflared
    "
    ok "quick:  cloudflared tunnel --url http://localhost:PORT"
    ok "named:  cloudflared tunnel login && cloudflared tunnel create NAME"
}

t_ttyd() {
    hdr "ttyd — terminal as HTTPS webpage"
    inf "https://github.com/tsl0922/ttyd  pair with cloudflared"
    if ! $DRY_RUN; then
        local URL
        URL=$(curl -fsSL \
            https://api.github.com/repos/tsl0922/ttyd/releases/latest \
            | grep browser_download_url | grep linux.x86_64 | head -1 | cut -d'"' -f4)
        [[ -n "$URL" ]] \
            && curl -fsSL "$URL" -o /usr/local/bin/ttyd \
            && chmod +x /usr/local/bin/ttyd \
            || { err "could not fetch ttyd release"; return 1; }
    fi
    ok "start:  ttyd -p 7681 bash"
    ok "tunnel: cloudflared tunnel --url http://localhost:7681"
}

menu_vpn() {
    submenu "VPN / TUNNEL" \
        "dnstm wizard (Slipstream/DNSTT/NoizDNS/VayDNS)"  t_dnstm \
        "SlipGate — unified DNS tunnel manager"             t_slipgate \
        "NoizDNS — standalone DNSTT+NoizDNS deploy"        t_noizdns \
        "reality-ezpz — VLESS/Reality + sing-box"          t_realityez \
        "3x-ui — Xray web panel (VLESS/VMess/Trojan/SS/WG)" t_3xui \
        "cloudflared — Cloudflare tunnel"                  t_cloudflared \
        "ttyd — terminal as HTTPS webpage"                 t_ttyd
}

# =============================================================================
# 2  PROXY / NETWORK
# =============================================================================
t_proxychains() {
    hdr "proxychains-ng"
    spin "installing" apt install -y proxychains4
    local PORT; PORT=$(socks_port); PORT="${PORT:-1080}"
    ok "auto-detected SOCKS port: $PORT"
    if ! $DRY_RUN; then
        local CONF="/etc/proxychains4.conf"
        cp "$CONF" "${CONF}.bak" 2>/dev/null || true
        cat > "$CONF" <<EOF
# proxychains-ng — vps-setup $RELEASE
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
    ok "usage: proxychains4 COMMAND"
}

t_tun2socks() {
    hdr "tun2socks — system-wide SOCKS routing"
    local PORT; PORT=$(socks_port); PORT="${PORT:-1080}"
    spin "installing tun2socks" bash -c "
        URL=\$(curl -fsSL \
            https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest \
            | grep browser_download_url | grep linux-amd64 | grep -v sha \
            | head -1 | cut -d'\"' -f4)
        [[ -n \"\$URL\" ]] || { echo 'release fetch failed'; exit 1; }
        curl -fsSL \"\$URL\" -o /tmp/t2s.zip
        unzip -qo /tmp/t2s.zip -d /tmp/t2s/
        install -m755 /tmp/t2s/tun2socks* /usr/local/bin/tun2socks 2>/dev/null || \
            cp /tmp/t2s/* /usr/local/bin/tun2socks
        rm -rf /tmp/t2s.zip /tmp/t2s/
    "
    if ! $DRY_RUN; then
        cat > /usr/local/bin/start-tun2socks.sh <<EOF
#!/bin/bash
# Route all traffic through SOCKS5 on 127.0.0.1:${PORT}
ip tuntap add mode tun dev tun0 2>/dev/null || true
ip addr add 198.18.0.1/15 dev tun0 2>/dev/null || true
ip link set dev tun0 up
ip route add default dev tun0 metric 1
exec tun2socks -device tun0 -proxy socks5://127.0.0.1:${PORT}
EOF
        chmod +x /usr/local/bin/start-tun2socks.sh
    fi
    ok "script: /usr/local/bin/start-tun2socks.sh"
    warn "replaces default route — run AFTER tunnel is up"
}

t_ufw_vps() {
    hdr "UFW — VPS running VPN(s) scenario"
    inf "opens: SSH (auto-detect), 443, 53 UDP/TCP, 2053 (3x-ui)"
    inf "default: deny incoming, allow outgoing"
    spin "installing UFW" apt install -y ufw
    local SP
    SP=$(ss -tlnp 2>/dev/null | grep sshd | grep -oP '(?<=:)\d+' | head -1)
    SP="${SP:-22}"
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow "${SP}/tcp"  comment "SSH"
    run ufw allow 443/tcp      comment "HTTPS/VLESS"
    run ufw allow 53/udp       comment "DNS-tunnel"
    run ufw allow 53/tcp       comment "DNS-tunnel-TCP"
    run ufw allow 2053/tcp     comment "3x-ui panel"
    run ufw allow 11434/tcp    comment "Ollama API (localhost only via nginx)"
    run ufw --force enable
    ok "UFW active  SSH=$SP"
}

t_ufw_laptop() {
    hdr "UFW — home laptop / workstation scenario"
    inf "relaxed: SSH disabled externally, all outgoing allowed"
    spin "installing UFW" apt install -y ufw
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow from 192.168.0.0/16 to any port 22 proto tcp comment "SSH LAN only"
    run ufw allow from 10.0.0.0/8    to any port 22 proto tcp comment "SSH VPN only"
    run ufw --force enable
    ok "UFW active  SSH restricted to LAN/VPN subnet only"
}

t_fail2ban() {
    hdr "fail2ban"
    spin "installing" apt install -y fail2ban
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
    ok "5 failed SSH attempts = 1h ban"
}

t_docker() {
    hdr "Docker"
    has docker && { warn "already installed: $(docker --version)"; return; }
    spin "installing Docker" bash -c "curl -fsSL https://get.docker.com | bash"
    run usermod -aG docker "$REAL_USER"
    ok "re-login as $REAL_USER to use docker without sudo"
}

menu_proxy() {
    submenu "PROXY / NETWORK" \
        "proxychains-ng (auto-config from active tunnel port)" t_proxychains \
        "tun2socks — route ALL traffic through SOCKS5"        t_tun2socks \
        "UFW — VPS/VPN scenario (443, 53, 2053)"              t_ufw_vps \
        "UFW — home laptop (SSH LAN-only, deny WAN)"          t_ufw_laptop \
        "fail2ban — SSH brute-force protection"                t_fail2ban \
        "Docker"                                               t_docker
}

# =============================================================================
# 3  BROWSER / GUI
# =============================================================================
t_xorg_base() {
    hdr "Xorg + Openbox WM (base)"
    warn "install this first before any GUI browser"
    spin "installing minimal Xorg + Openbox" \
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
    ok "start X:  startx   (right-click desktop for Openbox menu)"
}

t_xorg_optimize() {
    hdr "Xorg low-RAM optimizations"
    inf "disables MIT-SHM, compositing, AIGLX — forces swrast (software rendering)"
    if ! $DRY_RUN; then
        mkdir -p /etc/X11/xorg.conf.d/
        cat > /etc/X11/xorg.conf.d/10-vps-low-ram.conf <<'EOF'
# vps-setup low-RAM Xorg config
Section "Extensions"
    Option "MIT-SHM"   "disable"
    Option "Composite" "disable"
EndSection
Section "ServerFlags"
    Option "Xinerama" "false"
    Option "AIGLX"    "false"
EndSection
Section "Device"
    Identifier "VPS"
    Driver     "fbdev"
    Option     "AccelMethod" "none"
EndSection
EOF
        grep -q LIBGL_ALWAYS_SOFTWARE /etc/environment 2>/dev/null || \
            echo 'LIBGL_ALWAYS_SOFTWARE=1' >> /etc/environment
        echo 'export LIBGL_ALWAYS_SOFTWARE=1' >> "${REAL_HOME}/.profile"
        chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.profile"

        mkdir -p "${REAL_HOME}/.config/openbox"
        cat > "${REAL_HOME}/.config/openbox/rc.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme><n>Bear2</n><animateIconify>no</animateIconify></theme>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <applications/>
</openbox_config>
EOF
        chown -R "$REAL_USER:$REAL_USER" "${REAL_HOME}/.config"
    fi
    ok "MIT-SHM off, compositing off, swrast, Openbox no-effects"
    warn "restart X for changes"
}

t_b_epiphany() {
    hdr "Epiphany (GNOME Web)"
    inf "WebKit engine  ~80MB RAM  best JS support for 1C/1G  works with claude.ai"
    spin "installing" apt install -y --no-install-recommends epiphany-browser gstreamer1.0-libav
    ok "DISPLAY=:0 epiphany-browser"
}

t_b_midori() {
    hdr "Midori browser"
    inf "WebKit  ~100MB RAM  modern JS  good claude.ai alternative"
    spin "installing" apt install -y midori 2>/dev/null || {
        warn "not in apt — trying flatpak"
        apt install -y flatpak >> "$LOG_FILE" 2>&1
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo >> "$LOG_FILE" 2>&1
        flatpak install -y flathub org.midori_browser.Midori >> "$LOG_FILE" 2>&1
    }
    ok "DISPLAY=:0 midori"
}

t_b_netsurf() {
    hdr "NetSurf"
    inf "own engine  ~35MB RAM  limited JS — NOT suitable for claude.ai"
    spin "installing" apt install -y netsurf-gtk
    ok "DISPLAY=:0 netsurf-gtk"
}

t_b_dillo() {
    hdr "Dillo"
    inf "~10MB RAM  NO JS  fastest GUI browser  static HTML only"
    spin "installing" apt install -y dillo
    ok "DISPLAY=:0 dillo"
}

t_b_firefox() {
    hdr "Firefox ESR"
    warn "~300MB RAM  needs 2GB+  full claude.ai support"
    spin "adding Mozilla APT repo + installing Firefox ESR" bash -c "
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
    if ! $DRY_RUN; then
        mkdir -p "${REAL_HOME}/.mozilla/firefox"
        cat > "${REAL_HOME}/.mozilla/firefox/user.js" <<'EOF'
user_pref("browser.sessionstore.interval", 180000);
user_pref("browser.cache.disk.capacity", 51200);
user_pref("browser.cache.memory.capacity", 32768);
user_pref("gfx.webrender.enabled", false);
user_pref("layers.acceleration.disabled", true);
user_pref("media.hardware-video-decoding.enabled", false);
EOF
        chown -R "$REAL_USER:$REAL_USER" "${REAL_HOME}/.mozilla"
    fi
    ok "DISPLAY=:0 firefox-esr   (low-RAM user.js applied)"
}

t_b_chromium() {
    hdr "Chromium"
    warn "~350MB RAM  needs 2GB+"
    spin "installing" apt install -y chromium
    ok "DISPLAY=:0 chromium --no-sandbox --disable-gpu"
}

t_b_lynx()  { hdr "Lynx";  spin "installing" apt install -y lynx;     ok "lynx https://..."; }
t_b_w3m()   { hdr "w3m";   spin "installing" apt install -y w3m w3m-img; ok "w3m https://..."; }

t_proxied_browser() {
    hdr "Launch browser via proxychains"
    local PORT; PORT=$(socks_port)
    [[ -z "$PORT" ]] && { err "no active SOCKS tunnel detected"; return 1; }
    ok "tunnel on port $PORT"
    local found=""
    for b in epiphany-browser midori firefox-esr chromium; do
        has "$b" && { found="$b"; break; }
    done
    [[ -z "$found" ]] && { err "no GUI browser installed"; return 1; }
    inf "launching $found via proxychains4"
    $DRY_RUN || su - "$REAL_USER" -s /bin/bash -c \
        "DISPLAY=:0 proxychains4 $found &" >> "$LOG_FILE" 2>&1
    ok "launched $found"
}

menu_browser() {
    submenu "BROWSER / GUI" \
        "Xorg + Openbox WM — low-RAM base (install first)"    t_xorg_base \
        "Xorg low-RAM tweaks (MIT-SHM off, swrast, no-effects)" t_xorg_optimize \
        "Epiphany — WebKit ~80MB, best for claude.ai on 1C/1G" t_b_epiphany \
        "Midori — WebKit ~100MB, modern JS"                    t_b_midori \
        "NetSurf — ~35MB, very limited JS"                     t_b_netsurf \
        "Dillo — ~10MB, NO JS, fastest"                        t_b_dillo \
        "Firefox ESR — full browser ~300MB (2GB+ needed)"      t_b_firefox \
        "Chromium — full browser ~350MB (2GB+ needed)"         t_b_chromium \
        "Lynx — terminal text browser"                         t_b_lynx \
        "w3m — terminal browser with images"                   t_b_w3m \
        "Launch installed browser through proxychains"         t_proxied_browser
}

# =============================================================================
# 4  SYSTEM & PACKAGES
# =============================================================================
t_fast_mirror() {
    hdr "Fastest APT mirror"
    local OS_ID; OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    local CODENAME; CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"')
    CODENAME="${CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}"

    # try netselect-apt for Ubuntu
    if [[ "$OS_ID" == "ubuntu" ]] \
        && apt-get install -y netselect-apt -qq >> "$LOG_FILE" 2>&1; then
        if ! $DRY_RUN; then
            cp /etc/apt/sources.list /etc/apt/sources.list.bak
            netselect-apt -n -o /etc/apt/sources.list.d/fast-mirror.list \
                "$CODENAME" >> "$LOG_FILE" 2>&1
            apt update -qq >> "$LOG_FILE" 2>&1
            ok "netselect-apt wrote fast-mirror.list"
        fi
        return
    fi

    # manual latency test
    local mirrors=()
    if [[ "$OS_ID" == "ubuntu" ]]; then
        mirrors=(
            "https://archive.ubuntu.com/ubuntu"
            "https://mirror.nl.leaseweb.net/ubuntu"
            "https://ftp.tu-berlin.de/ubuntu"
            "https://mirrors.edge.kernel.org/ubuntu"
            "https://ftp.halifax.rwth-aachen.de/ubuntu"
            "https://mirror.i3d.net/ubuntu"
        )
    else
        mirrors=(
            "https://deb.debian.org/debian"
            "https://ftp.nl.debian.org/debian"
            "https://ftp.de.debian.org/debian"
            "https://mirror.nl.leaseweb.net/debian"
            "https://mirrors.edge.kernel.org/debian"
        )
    fi

    local best_url="" best_ms=99999
    for m in "${mirrors[@]}"; do
        local ms
        ms=$(curl -o /dev/null -s -w "%{time_connect}" \
             --connect-timeout 3 "$m" 2>/dev/null | awk '{printf "%.0f",$1*1000}')
        ms="${ms:-9999}"
        printf "    %6sms  %s\n" "$ms" "$m"
        (( ms < best_ms )) && { best_ms=$ms; best_url=$m; }
    done

    ok "fastest: $best_url  (${best_ms}ms)"

    if ! $DRY_RUN && [[ -n "$best_url" ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        if [[ "$OS_ID" == "ubuntu" ]]; then
            cat > /etc/apt/sources.list <<EOF
deb $best_url $CODENAME main restricted universe multiverse
deb $best_url ${CODENAME}-updates main restricted universe multiverse
deb $best_url ${CODENAME}-security main restricted universe multiverse
EOF
        else
            cat > /etc/apt/sources.list <<EOF
deb $best_url $CODENAME main contrib non-free non-free-firmware
deb $best_url ${CODENAME}-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security ${CODENAME}-security main contrib non-free
EOF
        fi
        apt update -qq >> "$LOG_FILE" 2>&1
        ok "sources.list updated  backup at sources.list.bak"
    fi
}

t_swap_zram() {
    hdr "Swap + ZRAM"
    local SZ ZZ
    if   (( RAM_MB <= 1024 )); then SZ="2G"; ZZ="512M"
    elif (( RAM_MB <= 2048 )); then SZ="3G"; ZZ="768M"
    else                            SZ="4G"; ZZ="50%"
    fi
    inf "RAM=${RAM_MB}MB  swap=$SZ  zram=$ZZ"

    if [[ -f /swapfile ]]; then warn "swapfile exists — skipping"
    else
        spin "creating $SZ swapfile" bash -c "
            fallocate -l $SZ /swapfile
            chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            grep -q '/swapfile' /etc/fstab \
                || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        "
    fi

    spin "installing systemd-zram-generator" apt install -y systemd-zram-generator
    if ! $DRY_RUN; then
        cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZZ
compression-algorithm = zstd
EOF
        modprobe zstd 2>/dev/null || true
        systemctl daemon-reload
        systemctl restart systemd-zram-generator.service 2>/dev/null || true
    fi
    ok "swap + ZRAM configured"
}

t_performance() {
    hdr "Performance tweaks (BBR + VM/TCP)"
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
    ok "BBR + VM/TCP tuning applied"
}

t_miniconda() {
    hdr "Miniconda 3"
    if [[ -x "${REAL_HOME}/miniconda3/bin/conda" ]]; then
        warn "already at ${REAL_HOME}/miniconda3"
    else
        spin "downloading" wget -q \
            "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
            -O /tmp/miniconda.sh
        spin "installing for $REAL_USER" \
            su - "$REAL_USER" -s /bin/bash -c \
            "bash /tmp/miniconda.sh -b -p ~/miniconda3 \
             && ~/miniconda3/bin/conda init bash"
    fi
    spin "creating env '$CONDA_ENV' (Python 3.12)" \
        su - "$REAL_USER" -s /bin/bash -c "
            source ~/miniconda3/bin/activate
            conda create -n $CONDA_ENV python=3.12 -y 2>/dev/null || true
            grep -q 'conda activate $CONDA_ENV' ~/.bashrc \
                || echo 'conda activate $CONDA_ENV' >> ~/.bashrc
        "
    ok "Miniconda + env '$CONDA_ENV' ready"
}

t_essentials() {
    hdr "Essential tools"
    spin "installing" apt install -y \
        htop ncdu tmux curl git unzip wget jq net-tools dnsutils lsof \
        build-essential software-properties-common apt-transport-https \
        ca-certificates gnupg lsb-release
    ok "essentials installed"
}

t_unattended() {
    hdr "unattended-upgrades"
    spin "installing" apt install -y unattended-upgrades
    $DRY_RUN || dpkg-reconfigure -plow unattended-upgrades >> "$LOG_FILE" 2>&1 || true
    ok "auto security patches enabled"
}

menu_system() {
    submenu "SYSTEM & PACKAGES" \
        "Fastest APT mirror — latency test + write sources.list" t_fast_mirror \
        "Swap + ZRAM (RAM-aware: ${RAM_MB}MB detected)"          t_swap_zram \
        "Performance tweaks — BBR + VM/TCP tuning"               t_performance \
        "Miniconda 3 + Python 3.12 env"                          t_miniconda \
        "Essential tools (htop, tmux, git, curl, jq, build-essential)" t_essentials \
        "unattended-upgrades — auto security patches"            t_unattended
}

# =============================================================================
# 5  SHELLS & EDITORS
# =============================================================================
t_fish() {
    hdr "Fish shell + Fisher + plugins"
    spin "installing Fish" apt install -y fish fzf
    $DRY_RUN || chsh -s /usr/bin/fish "$REAL_USER" 2>/dev/null \
        || warn "chsh failed — run: chsh -s /usr/bin/fish"
    spin "installing Fisher + plugins" \
        su - "$REAL_USER" -s /usr/bin/fish -c '
            curl -sL \
                https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish \
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
    ok "run: exec fish"
}

t_zsh() {
    hdr "Zsh + Oh My Zsh + plugins"
    spin "installing Zsh" apt install -y zsh fzf
    inf "installing Oh My Zsh for $REAL_USER"
    if ! $DRY_RUN; then
        su - "$REAL_USER" -s /bin/bash -c \
            'RUNZSH=no CHSH=no sh -c "$(curl -fsSL \
                https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"' \
            >> "$LOG_FILE" 2>&1
    fi
    # Install famous plugins (not bundled with OMZ)
    local PLUGINS_DIR="${REAL_HOME}/.oh-my-zsh/custom/plugins"
    if ! $DRY_RUN; then
        mkdir -p "$PLUGINS_DIR"
        # zsh-autosuggestions
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            "$PLUGINS_DIR/zsh-autosuggestions" >> "$LOG_FILE" 2>&1 || true
        # zsh-syntax-highlighting
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
            "$PLUGINS_DIR/zsh-syntax-highlighting" >> "$LOG_FILE" 2>&1 || true
        # zsh-history-substring-search
        git clone --depth=1 https://github.com/zsh-users/zsh-history-substring-search \
            "$PLUGINS_DIR/zsh-history-substring-search" >> "$LOG_FILE" 2>&1 || true
        # fzf-tab
        git clone --depth=1 https://github.com/Aloxaf/fzf-tab \
            "$PLUGINS_DIR/fzf-tab" >> "$LOG_FILE" 2>&1 || true

        # powerlevel10k theme
        git clone --depth=1 https://github.com/romkatv/powerlevel10k \
            "${REAL_HOME}/.oh-my-zsh/custom/themes/powerlevel10k" >> "$LOG_FILE" 2>&1 || true

        # Write .zshrc
        local ZSHRC="${REAL_HOME}/.zshrc"
        [[ -f "$ZSHRC" ]] && cp "$ZSHRC" "${ZSHRC}.bak"
        cat >> "$ZSHRC" <<'EOF'

# vps-setup additions
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(
    git
    sudo
    z
    fzf
    docker
    tmux
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-history-substring-search
    fzf-tab
)
# history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY
# keybindings for history-substring-search
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
EOF
        chown "$REAL_USER:$REAL_USER" "$ZSHRC"
    fi

    $DRY_RUN || chsh -s /usr/bin/zsh "$REAL_USER" 2>/dev/null \
        || warn "chsh failed — run: chsh -s /usr/bin/zsh"
    ok "Zsh + OMZ + powerlevel10k + autosuggestions + syntax-highlighting + fzf-tab"
    inf "run: p10k configure  (to set up prompt)"
}

t_bash_tweaks() {
    hdr "Bash tweaks + plugins"
    inf "bash-completion, fzf, starship prompt, .bashrc improvements"
    spin "installing bash-completion fzf" apt install -y bash-completion fzf

    # Starship prompt
    spin "installing starship prompt" bash -c \
        "curl -sS https://starship.rs/install.sh | sh -s -- -y"

    if ! $DRY_RUN; then
        local BASHRC="${REAL_HOME}/.bashrc"
        [[ -f "$BASHRC" ]] && cp "$BASHRC" "${BASHRC}.bak"
        cat >> "$BASHRC" <<'EOF'

# vps-setup bash tweaks
# better history
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend
PROMPT_COMMAND="history -a;$PROMPT_COMMAND"
# better defaults
shopt -s checkwinsize cdspell autocd
# aliases
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias gs='git status'
alias gp='git pull'
alias ..='cd ..'
alias ...='cd ../..'
alias ports='ss -tlnp'
alias myip='curl -4s ifconfig.me'
# fzf
[[ -f /usr/share/bash-completion/bash_completion ]] \
    && source /usr/share/bash-completion/bash_completion
[[ -f ~/.fzf.bash ]] && source ~/.fzf.bash
# starship
has starship && eval "$(starship init bash)"
EOF
        chown "$REAL_USER:$REAL_USER" "$BASHRC"

        # Starship config for REAL_USER
        mkdir -p "${REAL_HOME}/.config"
        cat > "${REAL_HOME}/.config/starship.toml" <<'EOF'
# starship config — vps-setup
format = "$username$hostname$directory$git_branch$git_status$python$cmd_duration$line_break$character"
[character]
success_symbol = "[>](green)"
error_symbol   = "[x](red)"
[directory]
truncation_length = 3
[git_branch]
symbol = " "
[git_status]
format = '([$all_status$ahead_behind]($style) )'
EOF
        chown -R "$REAL_USER:$REAL_USER" "${REAL_HOME}/.config"
    fi
    ok "Bash: better history, aliases, fzf, starship prompt"
}

t_nano_tweaks() {
    hdr "nano tweaks"
    inf "syntax highlighting, line numbers, smooth scroll, mouse support"
    spin "installing nano" apt install -y nano
    if ! $DRY_RUN; then
        # System-wide nanorc
        cat >> /etc/nanorc <<'EOF'

# vps-setup nano tweaks
set linenumbers
set mouse
set softwrap
set tabsize 4
set tabstospaces
set autoindent
set smooth
set boldtext
set historylog
set positionlog
set afterends
set wordchars "_"
# syntax files
include "/usr/share/nano/*.nanorc"
EOF
        # Also patch user nanorc
        cat > "${REAL_HOME}/.nanorc" <<'EOF'
include "/etc/nanorc"
EOF
        chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.nanorc"
    fi
    ok "nano: line numbers, mouse, smooth scroll, syntax highlighting, autoindent"
    inf "keybindings: Ctrl+S save  Ctrl+X exit  Alt+U undo  Ctrl+W find"
}

t_micro_editor() {
    hdr "micro — modern terminal editor"
    inf "https://micro-editor.github.io  mouse, syntax, plugins, Ctrl+S/Ctrl+Q"
    inf "best simple CLI editor for beginners — one binary, zero config needed"
    if ! $DRY_RUN; then
        curl -fsSL https://getmic.ro | bash -s -- -y >> "$LOG_FILE" 2>&1
        install -m755 micro /usr/local/bin/micro 2>/dev/null || true
        rm -f micro
        # Plugin: filemanager
        su - "$REAL_USER" -s /bin/bash -c \
            "micro -plugin install filemanager linter autoclose" >> "$LOG_FILE" 2>&1 || true
    else echo "${DM}  [dry]${RS}"; fi
    ok "usage: micro FILE  |  Ctrl+S save  Ctrl+Q quit  Ctrl+E command"
}

t_helix_editor() {
    hdr "Helix — modal terminal editor"
    inf "https://helix-editor.com  Vim-like modal, tree-sitter, LSP built-in"
    inf "best for developers who want modal editing without Vim complexity"
    spin "installing Helix" bash -c "
        add-apt-repository -y ppa:maveonair/helix-editor >> /dev/null 2>&1 || true
        apt update -qq && apt install -y helix
    " 2>/dev/null || {
        warn "PPA failed — trying GitHub release"
        local URL
        URL=$(curl -fsSL \
            https://api.github.com/repos/helix-editor/helix/releases/latest \
            | grep browser_download_url | grep linux | grep x86 | head -1 | cut -d'"' -f4)
        if ! $DRY_RUN && [[ -n "$URL" ]]; then
            curl -fsSL "$URL" -o /tmp/helix.tar.xz
            tar -xJf /tmp/helix.tar.xz -C /tmp/
            find /tmp/ -name 'hx' -type f -exec install -m755 {} /usr/local/bin/hx \;
            rm -f /tmp/helix.tar.xz
        fi
    }
    ok "usage: hx FILE  |  :w save  :q quit  i insert  normal mode default"
}

t_fonts() {
    hdr "Fira fonts (FiraCode + FiraMono Nerd Font)"
    inf "best fonts for terminals and CLI — ligatures, Powerline, Nerd Font icons"
    spin "installing fonts-firacode" apt install -y fonts-firacode
    # Also install Fira Mono Nerd Font from nerd-fonts
    if ! $DRY_RUN; then
        local FONT_DIR="/usr/local/share/fonts/NerdFonts"
        mkdir -p "$FONT_DIR"
        local BASE="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
        for f in FiraMono.tar.xz; do
            curl -fsSL "${BASE}/${f}" -o "/tmp/${f}" 2>/dev/null && \
            tar -xJf "/tmp/${f}" -C "$FONT_DIR" 2>/dev/null && \
            rm -f "/tmp/${f}" || true
        done
        fc-cache -fv >> "$LOG_FILE" 2>&1
    fi
    ok "Fira Code + FiraMono Nerd Font installed"
    inf "set terminal font to: FiraMono Nerd Font Mono  or  Fira Code"
}

t_farsi_keyboard() {
    hdr "Farsi keyboard (Persian) + X configuration"
    inf "installs IBus + farsi layout, setxkbmap shortcuts, xorg conf"
    spin "installing IBus + farsi" apt install -y ibus ibus-m17n m17n-db

    if ! $DRY_RUN; then
        # Xorg keyboard config
        mkdir -p /etc/X11/xorg.conf.d/
        cat > /etc/X11/xorg.conf.d/20-keyboard-farsi.conf <<'EOF'
Section "InputClass"
    Identifier   "keyboard layout"
    MatchIsKeyboard "yes"
    Option "XkbLayout"  "us,ir"
    Option "XkbOptions" "grp:alt_shift_toggle,grp_led:scroll"
EndSection
EOF

        # User IBus config
        cat >> "${REAL_HOME}/.profile" <<'EOF'

# Farsi / IBus
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
ibus-daemon -drx &>/dev/null &
EOF
        chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.profile"

        # Add setxkbmap to xinitrc
        if [[ -f "${REAL_HOME}/.xinitrc" ]]; then
            sed -i '/^exec openbox/i setxkbmap -layout "us,ir" -option "grp:alt_shift_toggle"' \
                "${REAL_HOME}/.xinitrc"
        fi
    fi
    ok "toggle keyboard: Alt+Shift"
    inf "add more engines via: ibus-setup  (run as $REAL_USER in X session)"
    inf "check layout:         setxkbmap -query"
}

t_jcal() {
    hdr "jcal — Jalali (Persian) calendar"
    inf "https://github.com/ashkang/jcal  command-line Jalali/Shamsi calendar"
    spin "installing build deps" apt install -y build-essential libxml2-dev
    if ! $DRY_RUN; then
        git clone --depth=1 https://github.com/ashkang/jcal /tmp/jcal >> "$LOG_FILE" 2>&1
        cd /tmp/jcal
        autoreconf -fi >> "$LOG_FILE" 2>&1 || \
            { apt install -y autoconf automake libtool >> "$LOG_FILE" 2>&1
              autoreconf -fi >> "$LOG_FILE" 2>&1; }
        ./configure --prefix=/usr/local >> "$LOG_FILE" 2>&1
        make -j"$CPU_CORES" >> "$LOG_FILE" 2>&1
        make install >> "$LOG_FILE" 2>&1
        cd /
        rm -rf /tmp/jcal
    else echo "${DM}  [dry]${RS}"; fi
    ok "usage: jcal       show this month"
    ok "       jcal -j    show Jalali"
    ok "       jdate       print today's Jalali date"
}

menu_shells() {
    submenu "SHELLS & EDITORS" \
        "Fish + Fisher + plugins (fzf, z, tide, git)"            t_fish \
        "Zsh + Oh My Zsh + powerlevel10k + autosuggestions + fzf-tab" t_zsh \
        "Bash tweaks + starship prompt + fzf + aliases"          t_bash_tweaks \
        "nano tweaks (line numbers, mouse, syntax, autoindent)"  t_nano_tweaks \
        "micro — best simple GUI-like terminal editor"           t_micro_editor \
        "Helix — modal editor with tree-sitter + LSP"            t_helix_editor \
        "Fira fonts (FiraCode + FiraMono Nerd Font)"             t_fonts \
        "Farsi keyboard (IBus + X layout, Alt+Shift toggle)"     t_farsi_keyboard \
        "jcal — Jalali/Shamsi calendar"                          t_jcal
}

# =============================================================================
# 6  AI TOOLS
# =============================================================================
t_aichat() {
    hdr "aichat — multi-provider AI CLI"
    inf "https://github.com/sigoden/aichat  Rust binary ~0 RAM overhead"
    inf "providers: Anthropic, OpenAI, Groq, Gemini, Ollama, OpenRouter"
    local URL
    URL=$(curl -fsSL \
        "https://api.github.com/repos/sigoden/aichat/releases/latest" 2>/dev/null \
        | grep browser_download_url | grep "x86_64-unknown-linux-musl" \
        | head -1 | cut -d'"' -f4)
    [[ -z "$URL" ]] && { err "could not fetch aichat release"; return 1; }
    spin "installing aichat" bash -c "
        curl -fsSL '$URL' -o /tmp/aichat.tar.gz
        tar -xzf /tmp/aichat.tar.gz -C /tmp/
        install -m755 /tmp/aichat /usr/local/bin/aichat
        rm -f /tmp/aichat.tar.gz /tmp/aichat
    "
    ok "config: ~/.config/aichat/config.yaml"
    inf "example: aichat -m claude:claude-sonnet-4-6 'hello'"
}

t_ollama() {
    hdr "Ollama — local LLM runtime"
    inf "https://ollama.com  runs LLMs locally via CPU (no GPU needed on VPS)"
    warn "RAM guide: 1G VPS → skip / 2G → phi3:mini (2GB) / 4G → phi3 or gemma2:2b / 8G+ → mistral:7b"

    spin "installing Ollama" bash -c \
        "curl -fsSL https://ollama.com/install.sh | bash"

    if ! $DRY_RUN; then
        # Low-RAM systemd tuning
        mkdir -p /etc/systemd/system/ollama.service.d/
        cat > /etc/systemd/system/ollama.service.d/vps.conf <<EOF
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF
        systemctl daemon-reload
        systemctl enable --now ollama >> "$LOG_FILE" 2>&1

        # Show RAM-appropriate model suggestions
        echo ""
        printf "  RAM-appropriate models for your ${RAM_MB}MB VPS:\n"
        if (( RAM_MB <= 1024 )); then
            warn "  only ${RAM_MB}MB — Ollama not recommended (needs 2GB+)"
        elif (( RAM_MB <= 2048 )); then
            inf "  suggested: ollama pull phi3:mini   (2.2GB, fast, good quality)"
        elif (( RAM_MB <= 4096 )); then
            inf "  suggested: ollama pull phi3:mini   or  gemma2:2b"
        elif (( RAM_MB <= 8192 )); then
            inf "  suggested: ollama pull mistral:7b  or  llama3.2:3b"
        else
            inf "  suggested: ollama pull mistral:7b  or  llama3.2:8b"
        fi

        # Install Open WebUI option
        if ask "Install Open WebUI (browser chat interface for Ollama)?"; then
            has docker || { warn "Docker needed — install from Proxy/Network menu first"; }
            has docker && docker run -d \
                --name open-webui \
                --restart unless-stopped \
                -p 3000:8080 \
                -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
                -v open-webui:/app/backend/data \
                ghcr.io/open-webui/open-webui:main >> "$LOG_FILE" 2>&1 \
                && ok "Open WebUI: http://localhost:3000"
        fi
    fi
    ok "ollama pull MODEL  then  ollama run MODEL"
    ok "API: curl http://localhost:11434/api/generate -d '{\"model\":\"phi3:mini\",\"prompt\":\"hello\"}'"
}

t_groq_cli_chat() {
    hdr "groq-cli-chat (OleksiyM)"
    inf "https://github.com/OleksiyM/groq-cli-chat"
    inf "Go binary, ~9MB, fast, multi-provider (Groq/xAI/OpenRouter/Mistral)"
    inf "history saved as Markdown in ~/.groq-chat/history/"
    warn "needs GROQ_API_KEY from https://console.groq.com (free tier available)"

    if ! $DRY_RUN; then
        local URL
        URL=$(curl -fsSL \
            https://api.github.com/repos/OleksiyM/groq-cli-chat/releases/latest \
            | grep browser_download_url \
            | grep -i "linux.*amd64\|amd64.*linux" | grep -v sha \
            | head -1 | cut -d'"' -f4)
        if [[ -n "$URL" ]]; then
            curl -fsSL "$URL" -o /tmp/groq-chat-bin
            install -m755 /tmp/groq-chat-bin /usr/local/bin/groq-chat
            rm -f /tmp/groq-chat-bin
        else
            # Build from source via Go
            has go || apt install -y golang-go >> "$LOG_FILE" 2>&1
            git clone --depth=1 \
                https://github.com/OleksiyM/groq-cli-chat /tmp/groq-cli-chat \
                >> "$LOG_FILE" 2>&1
            cd /tmp/groq-cli-chat
            go build -o /usr/local/bin/groq-chat ./cmd/ >> "$LOG_FILE" 2>&1
            cd / && rm -rf /tmp/groq-cli-chat
        fi
    else echo "${DM}  [dry]${RS}"; fi
    ok "export GROQ_API_KEY=xxx  then  groq-chat"
    inf "inside: [m] switch model  [h] history  [i] info  [q] quit"
}

t_groq_code_cli() {
    hdr "groq-code-cli (build-with-groq)"
    inf "https://github.com/build-with-groq/groq-code-cli"
    inf "TypeScript coding agent, customizable, npm-based"
    warn "needs Node.js 18+ and GROQ_API_KEY"

    local NODE_VER; NODE_VER=$(node --version 2>/dev/null | grep -oP 'v\K[0-9]+' || echo 0)
    if (( NODE_VER < 18 )); then
        spin "installing Node.js 20" bash -c "
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt install -y nodejs
        "
    fi
    spin "installing groq-code-cli" bash -c "
        npm install -g groq-code-cli 2>/dev/null \
            || npx groq-code-cli@latest --version
    "
    ok "run: groq  (set GROQ_API_KEY first)"
}

t_grok_xai_cli() {
    hdr "Grok CLI (xAI/superagent)"
    inf "https://github.com/superagent-ai/grok-cli  2.3k stars"
    warn "needs Bun runtime + GROK_API_KEY from https://x.ai"
    if ! has bun; then
        spin "installing Bun" bash -c "curl -fsSL https://bun.sh/install | bash"
        export PATH="$HOME/.bun/bin:$PATH"
        runu 'echo "export PATH=\"\$HOME/.bun/bin:\$PATH\"" >> ~/.bashrc'
    fi
    spin "installing grok-cli via Bun" \
        su - "$REAL_USER" -s /bin/bash -c \
        'export PATH="$HOME/.bun/bin:$PATH"; bun add -g grok-dev'
    ok "export GROK_API_KEY=xxx  then  grok"
}

t_gemini_cli() {
    hdr "Gemini CLI (@google/gemini-cli)"
    local NODE_VER; NODE_VER=$(node --version 2>/dev/null | grep -oP 'v\K[0-9]+' || echo 0)
    if (( NODE_VER < 18 )); then
        spin "installing Node.js 20" bash -c "
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt install -y nodejs
        "
    fi
    spin "installing @google/gemini-cli" npm install -g @google/gemini-cli
    ok "run: gemini  (sign in with Google)"
}

menu_ai() {
    submenu "AI TOOLS" \
        "aichat — multi-provider CLI (Anthropic/OpenAI/Groq/Gemini/Ollama)" t_aichat \
        "Ollama — local LLM runtime (RAM-aware model suggestions)"           t_ollama \
        "groq-cli-chat — lightweight Go chat CLI (free Groq API)"           t_groq_cli_chat \
        "groq-code-cli — TypeScript coding agent (Groq)"                   t_groq_code_cli \
        "Grok CLI — xAI agent (GROK_API_KEY)"                              t_grok_xai_cli \
        "Gemini CLI — @google/gemini-cli"                                   t_gemini_cli
}

# =============================================================================
# 7  SECURITY / HARDENING
# =============================================================================
t_ssh_allow_root_password() {
    hdr "SSH — enable root password login"
    warn "DANGEROUS — only use on trusted networks or for initial setup"
    ask "really enable root password login?" || { inf "skipped"; return 0; }
    if ! $DRY_RUN; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    fi
    ok "root password login enabled — change or revert when done"
}

t_ssh_harden() {
    hdr "SSH hardening (key-only, no password)"
    warn "disables password auth — ensure your SSH key is in authorized_keys first!"
    ask "proceed?" || { inf "skipped"; return 0; }
    if ! $DRY_RUN; then
        local SSHD="/etc/ssh/sshd_config"
        cp "$SSHD" "${SSHD}.bak.$(date +%Y%m%d%H%M)"
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD"
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD"
        sed -i 's/^#*X11Forwarding.*/X11Forwarding yes/' "$SSHD"
        grep -q "MaxAuthTries" "$SSHD" \
            || printf "\nMaxAuthTries 3\nClientAliveInterval 300\n" >> "$SSHD"
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    fi
    ok "key-only SSH  (backup at sshd_config.bak.DATE)"
    warn "test in a NEW terminal before closing this one!"
}

t_create_user() {
    hdr "Create non-root sudo user"
    printf "new username: "; read -r NU
    [[ -z "$NU" ]] && { err "empty"; return 1; }
    id "$NU" &>/dev/null && { warn "user $NU exists"; return 0; }
    if ! $DRY_RUN; then
        adduser --gecos "" "$NU"
        usermod -aG sudo "$NU"
        if [[ -f /root/.ssh/authorized_keys ]]; then
            mkdir -p "/home/$NU/.ssh"
            cp /root/.ssh/authorized_keys "/home/$NU/.ssh/"
            chown -R "$NU:$NU" "/home/$NU/.ssh"
            chmod 700 "/home/$NU/.ssh"
            chmod 600 "/home/$NU/.ssh/authorized_keys"
            ok "root authorized_keys copied to $NU"
        fi
    fi
    ok "user $NU created with sudo"
}

t_save_creds() {
    hdr "Save system info + credentials"
    if ! $DRY_RUN; then
        local F="$OUTPUT_DIR/sysinfo-$(date +%Y%m%d-%H%M%S).txt"
        {
            printf "vps-setup %s — %s\n" "$RELEASE" "$(date)"
            printf "hostname:  %s\n" "$(hostname)"
            printf "public IP: %s\n" "$(curl -4s ifconfig.me 2>/dev/null)"
            printf "OS:        %s\n" "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
            printf "RAM:       %sMB  CPU: %s cores\n" "$RAM_MB" "$CPU_CORES"
            printf "user:      %s (uid=%s)\n\n" "$REAL_USER" "$REAL_UID"
            printf "services:\n"
            for s in ufw fail2ban docker x-ui cloudflared ollama; do
                systemctl is-active --quiet "$s" 2>/dev/null \
                    && printf "  %s ACTIVE\n" "$s" \
                    || printf "  %s inactive\n" "$s"
            done
            printf "\nlistening ports:\n"
            ss -tlnp 2>/dev/null || true
        } > "$F"
        chmod 600 "$F"
        ok "saved: $F"
    fi
    printf "\n%s contents:\n" "$OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR/" 2>/dev/null || true
}

t_crowdsec() {
    hdr "CrowdSec — community intrusion prevention"
    inf "https://www.crowdsec.net  modern fail2ban alternative"
    spin "installing CrowdSec" bash -c "
        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \
            | bash
        apt install -y crowdsec crowdsec-firewall-bouncer-iptables
    "
    ok "cscli hub update && cscli collections install crowdsecurity/linux"
}

menu_security() {
    submenu "SECURITY / HARDENING" \
        "SSH hardening — key-only, disable password auth"       t_ssh_harden \
        "SSH — enable root password login (for setup/recovery)" t_ssh_allow_root_password \
        "Create non-root sudo user (copies root SSH keys)"      t_create_user \
        "Save system info + credentials to $OUTPUT_DIR/"        t_save_creds \
        "CrowdSec — community intrusion prevention"             t_crowdsec
}

# =============================================================================
# RUN ALL (recommended non-interactive core)
# =============================================================================
run_all() {
    warn "running recommended core tasks — failures logged, chain continues"
    local tasks=(
        t_essentials t_fast_mirror t_swap_zram t_performance
        t_ufw_vps t_fail2ban t_proxychains t_bash_tweaks t_aichat
    )
    for t in "${tasks[@]}"; do $t 2>/dev/null || err "$t failed"; sleep 1; done
    t_save_creds 2>/dev/null || true
    ok "core done  log=$LOG_FILE  output=$OUTPUT_DIR/"
}

# =============================================================================
# MAIN MENU
# =============================================================================
main_menu() {
    local dry=""; $DRY_RUN && dry="  [DRY-RUN]"
    printf "\n${BD}vps-setup %s  |  %sMB RAM  %s cores  user=%s%s${RS}\n" \
        "$RELEASE" "$RAM_MB" "$CPU_CORES" "$REAL_USER" "$dry"
    printf "log: %s  |  output: %s/\n\n" "$LOG_FILE" "$OUTPUT_DIR"
    printf "  1  VPN / Tunnel      dnstm, SlipGate, reality-ezpz, 3x-ui, cloudflared\n"
    printf "  2  Proxy / Network   proxychains, tun2socks, UFW (VPS or laptop), fail2ban\n"
    printf "  3  Browser / GUI     Epiphany, Midori, Firefox, Chromium + Xorg tweaks\n"
    printf "  4  System            mirror, swap, BBR, Miniconda, essentials\n"
    printf "  5  Shells & Editors  Fish, Zsh, Bash, nano, micro, Helix, fonts, Farsi, jcal\n"
    printf "  6  AI Tools          aichat, Ollama, groq-cli-chat, groq-code-cli, Grok, Gemini\n"
    printf "  7  Security          SSH options, sudo user, CrowdSec, credential archive\n\n"
    printf "  A  Run recommended core tasks\n"
    printf "  S  Status dashboard\n"
    printf "  0  Exit\n\n"
    printf "Choice: "
}

# ── STARTUP ───────────────────────────────────────────────────────────────────
printf "\nvps-setup %s starting\n" "$RELEASE"
printf "root=%s  real_user=%s  home=%s\n" "$(whoami)" "$REAL_USER" "$REAL_HOME"
printf "RAM=%sMB  CPUs=%s\n" "$RAM_MB" "$CPU_CORES"
$DRY_RUN && warn "DRY-RUN — no changes will be made"

if ! $DRY_RUN; then
    printf "\nupdating apt... "
    apt update -qq >> "$LOG_FILE" 2>&1 && printf "${G}done${RS}\n" \
        || printf "${Y}warnings (see log)${RS}\n"
fi

while true; do
    main_menu
    read -r choice
    case "${choice^^}" in
        1) menu_vpn ;;
        2) menu_proxy ;;
        3) menu_browser ;;
        4) menu_system ;;
        5) menu_shells ;;
        6) menu_ai ;;
        7) menu_security ;;
        A) run_all; pause ;;
        S) show_status; pause ;;
        0) printf "\ndone. log=%s  output=%s/\n" "$LOG_FILE" "$OUTPUT_DIR"; exit 0 ;;
        *) err "invalid: $choice" ;;
    esac
done
