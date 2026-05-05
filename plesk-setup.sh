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
        echo -e "\b ${RED}✖${NC}"
        echo -e "${RED}[ERROR] Cek log: $LOG_FILE${NC}"
        exit 1
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
# STEP 1
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
# STEP 2
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
    yes y | bash /root/install.sh > "$LOG_FILE" 2>&1
) &
spinner $! "Installing Plesk"

echo ""

# =========================================================
# STEP 3
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/3] Plesk login information${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

# =========================
# WAIT PLESK READY
# =========================
for i in {1..20}; do
    systemctl is-active psa.service >/dev/null 2>&1 && break
    sleep 2
done

# =========================
# GET LOGIN URL
# =========================
PLESK_URL=$(plesk login 2>/dev/null | grep -Eo 'https://[^ ]+')

# =========================
# BASIC INFO
# =========================
IP=$(hostname -I | awk '{print $1}')
PORT="443"

# fallback kalau gagal ambil token
[ -z "$PLESK_URL" ] && PLESK_URL="https://$IP:$PORT"

# internal URL (tanpa token)
LOGIN_URL="https://$IP:$PORT"

DOMAIN_URL=$(echo "$PLESK_URL" | grep -o 'https://[^ ]*plesk.page[^ ]*')
IP_URL=$(echo "$PLESK_URL" | grep -o 'https://[0-9\.]*:[0-9]*/login[^ ]*')

# fallback
[ -z "$DOMAIN_URL" ] && DOMAIN_URL="$PLESK_URL"
[ -z "$IP_URL" ] && IP_URL="$LOGIN_URL/login"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}        PLESK LOGIN INFO              ${NC}"
echo -e "${GREEN}======================================${NC}"

# Login utama
printf "${CYAN}%-15s${NC} : %s\n" "Login URL" "$LOGIN_URL"
echo ""

# First Setup (nested)
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
echo -e "${CYAN}plesk login${NC}        - Generate login link"
echo -e "${CYAN}plesk version${NC}      - Show version"
echo -e "${CYAN}plesk repair${NC}       - Repair installation"
echo -e "${CYAN}plesk help${NC}         - Show all commands"
echo -e "${CYAN}systemctl status psa${NC} - Check service"
echo -e "${CYAN}systemctl restart psa${NC} - Restart Plesk"
