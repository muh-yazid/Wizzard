#!/bin/bash
set -e

LOG="/var/log/aapanel-install.log"
exec > >(tee -a "$LOG") 2>&1

# ==============================
# SPINNER
# ==============================
spinner() {
    local pid=$1
    local msg="$2"
    local spin='-\|/'
    local i=0

    tput civis 2>/dev/null || true

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.2
    done

    printf "\r"
    tput cnorm 2>/dev/null || true
}

run_step() {
    local MSG="$1"
    shift

    "$@" >> "$LOG" 2>&1 &
    PID=$!

    spinner $PID "$MSG"
    wait $PID

    if [ $? -ne 0 ]; then
        echo "[ERROR] $MSG gagal!"
        exit 1
    fi

    echo "[OK] $MSG"
}

# ==============================
# FIX APT LOCK
# ==============================
fix_apt() {
    echo "[INFO] Preparing apt..."

    systemctl stop apt-daily.service 2>/dev/null || true
    systemctl stop apt-daily-upgrade.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily-upgrade.service 2>/dev/null || true

    (
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
            sleep 2
        done
    ) &

    spinner $! "Waiting apt lock"

    dpkg --configure -a >> "$LOG" 2>&1 || true

    echo "[OK] apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "======================================"
echo "        AAPANEL INSTALLER"
echo "======================================"
echo ""

read -p "Start installation? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ==============================
# STEP 1 - SYSTEM
# ==============================
echo ""
echo "--------------------------------------"
echo "[STEP 1/3] Prepare system"
echo "--------------------------------------"

fix_apt
run_step "Install dependency" apt-get install -y curl wget

# ==============================
# STEP 2 - INPUT CONFIG
# ==============================
echo ""
echo "--------------------------------------"
echo "[STEP 2/3] Panel configuration"
echo "--------------------------------------"
echo ""

read -p "Panel username: " PANEL_USER

while true; do
    read -s -p "Panel password: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done
PANEL_PASS=$P1

read -p "Panel port (default 8888): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8888}

# ambil IP utama (1 IP saja)
IP=$(hostname -I | awk '{print $1}')

echo "[INFO] Using IP: $IP"

# ==============================
# STEP 3 - INSTALL AAPANEL
# ==============================
echo ""
echo "--------------------------------------"
echo "[STEP 3/3] Installing aaPanel"
echo "--------------------------------------"

echo "[INFO] Download official installer..."
curl -fsSL https://www.aapanel.com/script/install-ubuntu_6.0_en.sh -o install.sh

chmod +x install.sh

echo "[INFO] Running aaPanel installer..."
bash install.sh

# ==============================
# APPLY CONFIG (AFTER INSTALL)
# ==============================
echo ""
echo "[INFO] Applying panel configuration..."

# tunggu bt ready
for i in {1..30}; do
    if command -v bt >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# set username & password
echo "$PANEL_USER" | bt 6 >> "$LOG" 2>&1 || true
echo "$PANEL_PASS" | bt 5 >> "$LOG" 2>&1 || true

# set port
echo "$PANEL_PORT" | bt 8 >> "$LOG" 2>&1 || true

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "Panel URL:"
echo "http://$IP:$PANEL_PORT"

echo ""
echo "Username: $PANEL_USER"
echo "Password: $PANEL_PASS"

echo ""
echo "LOG: $LOG"
