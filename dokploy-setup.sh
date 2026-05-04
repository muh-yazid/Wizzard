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

LOG_FILE="/var/log/dokploy-install.log"

# =========================
# SPINNER (FIXED)
# =========================
spinner() {
    local pid=$1
    local msg=$2
    local spin='-\|/'
    local i=0

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${CYAN}[INFO] $msg... ${spin:$i:1}"
        sleep 0.1
    done

    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        printf "\r${CYAN}[INFO] $msg... ${GREEN}✔${NC}\n"
    else
        printf "\r${CYAN}[INFO] $msg... ${RED}✖${NC}\n"
        echo -e "${RED}[ERROR] Cek log: $LOG_FILE${NC}"
        exit 1
    fi
}

clear
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}     DOKPLOY INSTALLER WIZARD         ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# =========================
# PROMPT
# =========================
read -p "Start Dokploy installation wizard? (Y/n): " CONFIRM
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
    apt install -y wget curl sudo docker.io >/dev/null 2>&1
) &
spinner $! "Preparing apt & dependencies"

echo ""

# =========================================================
# STEP 2
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 2/3] Install Dokploy${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    wget -O /root/install.sh https://dokploy.com/install.sh >/dev/null 2>&1
    chmod +x /root/install.sh
) &
spinner $! "Downloading installer"

(
    # jalankan installer dengan benar-benar silent
    script -q -c "yes y | bash /root/install.sh" /dev/null
) > "$LOG_FILE" 2>&1 &
spinner $! "Installing Dokploy (2-5 minutes)"

echo ""

# =========================================================
# STEP 3
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/3] Dokploy Information${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

# ambil IP publik / fallback lokal
IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
PORT=3000
URL="http://$IP:$PORT"

# ambil swarm info
WORKER_TOKEN=$(docker swarm join-token worker -q 2>/dev/null || echo "-")
MANAGER_TOKEN=$(docker swarm join-token manager -q 2>/dev/null || echo "-")
MANAGER_IP=$(docker info -f '{{.Swarm.NodeAddr}}' 2>/dev/null || hostname -I | awk '{print $1}')

WORKER_CMD="docker swarm join --token $WORKER_TOKEN $MANAGER_IP:2377"
MANAGER_CMD="docker swarm join --token $MANAGER_TOKEN $MANAGER_IP:2377"

# ambil service
SERVICES=$(docker service ls --format "{{.Name}}" 2>/dev/null || echo "-")

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}        DOKPLOY ACCESS INFO          ${NC}"
echo -e "${GREEN}======================================${NC}"

printf "${CYAN}%-15s${NC} : %s\n" "Panel URL" "$URL"
printf "${CYAN}%-15s${NC} : %s\n" "Public IP" "$IP"
printf "${CYAN}%-15s${NC} : %s\n" "Port" "$PORT"

echo ""
echo -e "${YELLOW}First time access:${NC}"
echo -e " - Open URL di browser"
echo -e " - Create admin account (tidak ada default login)"

echo ""
echo -e "${GREEN}Docker Swarm Join Info:${NC}"

printf "${CYAN}%-15s${NC} : %s\n" "Worker Join" "$WORKER_CMD"
printf "${CYAN}%-15s${NC} : %s\n" "Manager Join" "$MANAGER_CMD"

echo ""
printf "${CYAN}%-15s${NC} : %s\n" "Docker Services" "$SERVICES"

echo -e "${GREEN}======================================${NC}"

echo ""
printf "${CYAN}%-15s${NC} : %s\n" "Log File" "$LOG_FILE"

echo ""
echo -e "${GREEN}Useful commands:${NC}"
echo -e "${CYAN}docker service ls${NC}          - List services"
echo -e "${CYAN}docker service ps <name>${NC}   - Check service"
echo -e "${CYAN}docker logs <container>${NC}    - View logs"
echo -e "${CYAN}docker node ls${NC}             - Swarm nodes"
echo -e "${CYAN}docker swarm join-token worker${NC}"

echo ""
