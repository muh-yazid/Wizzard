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

LOG_FILE="/var/log/docker-install.log"

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
echo -e "${BLUE}     DOCKER INSTALLER WIZARD         ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# =========================
# PROMPT (optional)
# =========================
if [ -t 0 ]; then
    read -p "Start Docker installation? (Y/n): " CONFIRM
    CONFIRM=${CONFIRM:-Y}

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Installation cancelled.${NC}"
        exit 0
    fi
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
    apt install -y curl ca-certificates >/dev/null 2>&1
) &

spinner $! "Preparing apt & dependencies"

echo ""

# =========================================================
# STEP 2
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 2/3] Install Docker${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

echo -e "${CYAN}[INFO]${NC} Download Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh >> "$MAIN_LOG" 2>&1

for i in 1 2 3; do
    if run_step "Installing Docker (attempt $i)" sh get-docker.sh; then
        break
    fi
    echo -e "${YELLOW}[WARN]${NC} Retry install Docker..."
    sleep 3
done

run_step "Starting Docker" bash -c "systemctl start docker || service docker start || true"
echo ""

# =========================================================
# STEP 3
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/3] Verify Docker${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    systemctl start docker || service docker start || true
    systemctl enable docker >/dev/null 2>&1 || true

    for i in {1..30}; do
        if docker info >/dev/null 2>&1; then
            exit 0
        fi
        sleep 2
    done

    exit 1
) &

spinner $! "Starting & checking Docker"

echo ""

# =========================================================
# DONE
# =========================================================
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}       DOCKER INSTALL SUCCESS         ${NC}"
echo -e "${GREEN}======================================${NC}"

DOCKER_VERSION=$(docker --version 2>/dev/null || echo "Unknown")
IP=$(hostname -I | awk '{print $1}')

printf "${CYAN}%-15s${NC} : %s\n" "Docker Version" "$DOCKER_VERSION"
printf "${CYAN}%-15s${NC} : %s\n" "Server IP" "$IP"
printf "${CYAN}%-15s${NC} : %s\n" "Log File" "$LOG_FILE"

echo ""
echo -e "${GREEN}Useful commands:${NC}"
echo -e "${CYAN}systemctl start docker${NC}"
echo -e "${CYAN}systemctl stop docker${NC}"
echo -e "${CYAN}systemctl restart docker${NC}"
echo -e "${CYAN}docker ps${NC}"
echo -e "${CYAN}docker info${NC}"
echo ""
