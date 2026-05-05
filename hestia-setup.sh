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

LOG_FILE="/var/log/hestia-install.log"

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
echo -e "${BLUE}      HESTIA INSTALLER WIZARD         ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# =========================
# PROMPT
# =========================
read -p "Start Hestia installation wizard? (Y/n): " CONFIRM
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
echo -e "${YELLOW}[STEP 1/4] Prepare system${NC}"
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

echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 2/4] Configuration${NC}"
echo -e "${YELLOW}--------------------------------------------${NC}"
echo ""

read -p "Domain: " DOMAIN
read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""
    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo -e "${RED}[ERROR]${NC} Password mismatch"
done
POSTGRES_PASSWORD=$P1

# =========================================================
# STEP 2
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/4] Install hestia${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    wget -O /root/install.sh https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh >/dev/null 2>&1
    chmod +x /root/install.sh
) &
spinner $! "Downloading installer"

(
    while true; do
    read -p "Pilih opsi (1/2) [default:1]: " DB_CHOICE
    DB_CHOICE=${DB_CHOICE:-1}

    case "$DB_CHOICE" in
        1)
            echo "[INFO] Menggunakan MySQL..."
            bash hst-install.sh \
                --port "$PORT" \
                --hostname "$FQDN" \
                --username "$USERNAME" \
                --email "$EMAIL" \
                --password "$PASSWORD" \
                --interactive no
            break
            ;;
        2)
            echo "[INFO] Menggunakan PostgreSQL..."
            bash hst-install.sh \
                --port "$PORT" \
                --hostname "$FQDN" \
                --username "$USERNAME" \
                --email "$EMAIL" \
                --password "$PASSWORD" \
                --mysql no \
                --postgresql yes \
                --interactive no
            break
            ;;
        *)
            echo "[ERROR] Pilihan tidak valid! Harus 1 atau 2."
            echo ""
            ;; > "$LOG_FILE" 2>&1
) &
spinner $! "Installing hestia"

echo ""

# =========================================================
# STEP 3
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 4/4] hestia login information${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}         HESTIA LOGIN INFO            ${NC}"
echo -e "${GREEN}======================================${NC}"

printf "${CYAN}%-15s${NC} : %s\n" "Domain" "https://$FQDN":$PORT"
printf "${CYAN}%-15s${NC} : %s\n" "IP" "https://$IP":$PORT"
printf "${CYAN}%-15s${NC} : %s\n" "Username" "$USERNAME"
printf "${CYAN}%-15s${NC} : %s\n" "Password" "$PASSWORD"

echo -e "${GREEN}======================================${NC}"

echo ""
printf "${CYAN}%-15s${NC} : %s\n" "Log File" "$LOG_FILE"
echo ""

echo -e "${GREEN}Useful commands:${NC}"
