#!/bin/bash
set -e

# =========================
# COLOR
# =========================
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
NC="\e[0m"

LOG_FILE="/var/log/plesk-install.log"

# =========================
# SPINNER
# =========================
spinner() {
    local pid=$1
    local msg=$2
    local spin='-\|/'
    local i=0

    echo -ne "${CYAN}[INFO] $msg... ${NC}"

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\b${spin:$i:1}"
        sleep 0.1
    done

    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "\b ${GREEN}✔${NC}"
    else
        # ❗ jangan langsung fail (plesk sering return non-zero)
        echo -e "\b ${YELLOW}⚠${NC}"
    fi
}

clear
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}     PLESK INSTALLER WIZARD         ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# =========================
# PROMPT
# =========================
read -p "Start Plesk installation wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation cancelled.${NC}"
    exit 0
fi

echo ""

# =========================================================
# STEP 1 - PREPARE
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 1/3] Prepare system${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 2; done
    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done

    rm -f /var/lib/dpkg/lock*
    rm -f /var/lib/apt/lists/lock*
    rm -f /var/cache/apt/archives/lock
    dpkg --configure -a || true

    apt update -y >/dev/null 2>&1
    apt install -y wget curl sudo >/dev/null 2>&1
) &
spinner $! "Preparing apt & dependencies"

echo ""

# =========================================================
# STEP 2 - INSTALL
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 2/3] Install Plesk${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    wget -O /root/install.sh https://autoinstall.plesk.com/one-click-installer >/dev/null 2>&1
    chmod +x /root/install.sh
) &
spinner $! "Downloading installer"

(
    set +e
    yes y | bash /root/install.sh > "$LOG_FILE" 2>&1
    exit 0
) &
spinner $! "Installing Plesk (10-20 minutes)"

echo ""

# =========================================================
# STEP 3 - LOGIN INFO
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/3] Plesk login information${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

# =========================
# WAIT SERVICE
# =========================
echo ""
echo "[INFO] Verifikasi service Plesk..."

for i in {1..60}; do
    if systemctl is-active psa.service >/dev/null 2>&1; then
        echo "[OK] Plesk service sudah running"
        break
    fi
    echo "[WAIT] Plesk belum ready ($i/60)"
    sleep 2
done

# =========================
# WAIT LOGIN URL READY
# =========================
for i in {1..30}; do
    PLESK_URL=$(plesk login 2>/dev/null | grep -Eo 'https://[^ ]+' || true)
    [ -n "$PLESK_URL" ] && break
    sleep 2
done

# =========================
# BASIC INFO
# =========================
IP=$(hostname -I | awk '{print $1}')
PORT="443"

LOGIN_URL="https://$IP:$PORT"

# parsing domain & ip link
DOMAIN_URL=$(echo "$PLESK_URL" | grep -o 'https://[^ ]*plesk.page[^ ]*' || true)
IP_URL=$(echo "$PLESK_URL" | grep -o 'https://[0-9\.]*:[0-9]*/login[^ ]*' || true)

# fallback
[ -z "$DOMAIN_URL" ] && DOMAIN_URL="$PLESK_URL"
[ -z "$IP_URL" ] && IP_URL="$LOGIN_URL/login"

# =========================
# OUTPUT
# =========================
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}        PLESK LOGIN INFO              ${NC}"
echo -e "${GREEN}======================================${NC}"

printf "${CYAN}%-15s${NC} : %s\n" "Login URL" "$LOGIN_URL"
echo ""

printf "${CYAN}%-15s${NC} :\n" "First Setup"
printf "  ${CYAN}%-12s${NC} : %s\n" "Domain" "$DOMAIN_URL"
printf "  ${CYAN}%-12s${NC} : %s\n" "IP" "$IP_URL"

echo -e "${GREEN}======================================${NC}"

echo ""
printf "${CYAN}%-15s${NC} : %s\n" "Log File" "$LOG_FILE"
printf "${CYAN}%-15s${NC} : %s\n" "Install Path" "/usr/local/psa"
echo ""

# =========================
# COMMANDS
# =========================
echo -e "${GREEN}Useful commands:${NC}"
echo -e "${CYAN}plesk login${NC}           - Generate login link"
echo -e "${CYAN}plesk version${NC}         - Show version"
echo -e "${CYAN}plesk repair${NC}          - Repair installation"
echo -e "${CYAN}plesk help${NC}            - Show all commands"
echo -e "${CYAN}systemctl status psa${NC}  - Check service"
echo -e "${CYAN}systemctl restart psa${NC} - Restart Plesk"
