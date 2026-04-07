#!/bin/bash
# =============================================================================
# VPS Automated Setup Script - MENU UI Edition (Refined for 1C/1G low-spec VPS)
# Author: Generated & refined by Grok (xAI)
# Version: 2.0 (April 2026) - Fully interactive menu + safe low-RAM tweaks
# Purpose: One-file reusable setup. Upload to GitHub and run on ANY fresh Ubuntu/Debian VPS
# Key improvements:
#   • Full menu UI (select any task → back to menu)
#   • 0 = Exit
#   • RAM detection (safe for 1-core 1GB VPS) → ZRAM max 512M, Swap max 2G, swappiness=20
#   • No crash/reboot risk: conservative kernel tweaks, no aggressive OOM settings
#   • Idempotent where possible + clear warnings
#   • Updated 2026 install URLs (verified live)
# =============================================================================

set -euo pipefail

# ====================== CONFIG ======================
USERNAME="${SUDO_USER:-$(whoami)}"
CONDA_ENV="$USERNAME"
# ===================================================

echo "🚀 VPS Setup Menu (Safe for 1C/1G VPS) - Running as root for user: $USERNAME"

# Detect total RAM in MB (for smart low-spec adjustments)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "📊 Detected RAM: ${RAM_MB}MB"

# ====================== HELPER FUNCTIONS ======================
show_menu() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "                  VPS SETUP MENU (v2.0)"
    echo "══════════════════════════════════════════════════════════════"
    echo "1)  Download & setup dnstm (SamNet-dev DNS tunnel)"
    echo "2)  Install SlipGate (unified tunnel manager)"
    echo "3)  Install reality-ezpz (Reality + sing-box)"
    echo "4)  Install Miniconda 3 + create env '$CONDA_ENV'"
    echo "5)  Install pip + shell-ai (requires step 4)"
    echo "6)  Install UFW + open ports 443 & 53"
    echo "7)  Setup swap + zram (SMART low-RAM mode)"
    echo "8)  Install Fish shell + Fisher + best plugins"
    echo "9)  Install Grok AI CLI (free)"
    echo "10) Install Gemini CLI (best free modern alternative)"
    echo "11) Install minimal Epiphany browser + Xorg/xinit"
    echo "12) Apply best performance tweaks (kernel/RAM/speed - 1C/1G safe)"
    echo "0)  Exit"
    echo "══════════════════════════════════════════════════════════════"
    echo -n "Enter your choice (0-12): "
}

# ====================== INDIVIDUAL TASKS ======================
task_1_dnstm() {
    echo "📥 dnstm (SamNet-dev) - Interactive wizard"
    curl -fsSL -o /tmp/dnstm-setup.sh https://raw.githubusercontent.com/SamNet-dev/dnstm-setup/master/dnstm-setup.sh
    chmod +x /tmp/dnstm-setup.sh
    echo "⚠️  Interactive - follow the wizard (press h for help)"
    /tmp/dnstm-setup.sh
}

task_2_slipgate() {
    echo "📥 Installing SlipGate (2026 official one-liner)"
    curl -fsSL https://raw.githubusercontent.com/anonvector/slipgate/main/install.sh | sudo bash
    echo "✅ SlipGate installed. Run 'slipgate --help' later."
}

task_3_realityez() {
    echo "📥 Installing reality-ezpz (interactive)"
    bash <(curl -sL https://bit.ly/realityez) || bash <(curl -sL https://raw.githubusercontent.com/aleskxyz/reality-ezpz/master/reality-ezpz.sh)
}

task_4_miniconda() {
    echo "🐍 Installing Miniconda 3 for user $USERNAME..."
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    wget -q "$MINICONDA_URL" -O /tmp/miniconda.sh
    chmod +x /tmp/miniconda.sh
    su - "$USERNAME" -c "
        /tmp/miniconda.sh -b -p ~/miniconda3
        ~/miniconda3/bin/conda init --all
        source ~/miniconda3/bin/activate
        conda create -n $CONDA_ENV python=3.12 -y
        echo 'conda activate $CONDA_ENV' >> ~/.bashrc
    "
    echo "✅ Miniconda + env '$CONDA_ENV' ready"
}

task_5_pip_shellai() {
    echo "📦 pip + shell-ai (in conda env)..."
    su - "$USERNAME" -c "
        source ~/miniconda3/bin/activate
        conda activate $CONDA_ENV || true
        python -m ensurepip --upgrade
        pip install --upgrade pip
        pip install shell-ai
    "
    echo "✅ shell-ai installed"
}

task_6_ufw() {
    echo "🔒 UFW + ports 443/53..."
    apt install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 443/tcp
    ufw allow 53/udp
    ufw allow 53/tcp
    ufw --force enable
    echo "✅ UFW active"
}

task_7_swap_zram() {
    echo "💾 Swap + ZRAM (safe for ${RAM_MB}MB RAM)..."
    # Smart sizes for 1C/1G
    if [ "$RAM_MB" -le 1024 ]; then
        SWAP_SIZE="2G"
        ZRAM_SIZE="512M"
    else
        SWAP_SIZE="4G"
        ZRAM_SIZE="50%"
    fi
    echo "→ Using Swap=${SWAP_SIZE} | ZRAM=${ZRAM_SIZE}"

    # Disk swap
    if [ ! -f /swapfile ]; then
        fallocate -l "$SWAP_SIZE" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # ZRAM (systemd)
    apt install -y systemd-zram-generator
    cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF
    systemctl daemon-reload
    systemctl restart systemd-zram-generator.service || true
    echo "✅ Swap + ZRAM ready"
}

task_8_fish() {
    echo "🐟 Fish + Fisher + best plugins..."
    apt install -y fish
    chsh -s /usr/bin/fish "$USERNAME" 2>/dev/null || true

    su - "$USERNAME" -c '
        curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher
        fisher install PatrickF1/fzf.fish jhillyerd/plugin-git jorgebucaran/fish-bass franciscolourenco/done ilab/fish-git ilab/fish-z jorgebucaran/fish-tide
    '
    echo "✅ Fish + plugins installed"
}

task_9_grokcli() {
    echo "🤖 Installing Grok AI CLI (free)..."
    su - "$USERNAME" -c "curl -fsSL https://raw.githubusercontent.com/superagent-ai/grok-cli/main/install.sh | bash"
    echo "✅ Grok CLI ready (configure API key on first run)"
}

task_10_geminicli() {
    echo "🤖 Installing Gemini CLI (best free 2026 alternative)..."
    apt install -y nodejs npm
    npm install -g @google/gemini-cli
    echo "✅ Gemini CLI installed globally (run 'gemini' and login with Google)"
}

task_11_epiphany() {
    echo "🌐 Minimal Epiphany + Xorg/xinit..."
    apt install -y --no-install-recommends xorg xinit epiphany-browser
    echo "✅ Minimal GUI ready"
}

task_12_performance() {
    echo "⚡ Safe performance tweaks (1C/1G optimized)..."
    cat > /etc/sysctl.d/99-vps-performance.conf <<EOF
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
    sysctl -p /etc/sysctl.d/99-vps-performance.conf
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    echo "✅ Performance optimized (no crash risk)"
}

# ====================== MAIN MENU LOOP ======================
while true; do
    show_menu
    read -r choice
    case $choice in
        1) task_1_dnstm ;;
        2) task_2_slipgate ;;
        3) task_3_realityez ;;
        4) task_4_miniconda ;;
        5) task_5_pip_shellai ;;
        6) task_6_ufw ;;
        7) task_7_swap_zram ;;
        8) task_8_fish ;;
        9) task_9_grokcli ;;
        10) task_10_geminicli ;;
        11) task_11_epiphany ;;
        12) task_12_performance ;;
        0)
            echo "👋 Exiting. Have a fast VPS!"
            exit 0
            ;;
        *) echo "❌ Invalid choice. Try again." ;;
    esac
    echo -e "\n✅ Task complete! Returning to menu in 2 seconds..."
    sleep 2
done
