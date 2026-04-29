#!/bin/bash
set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# COLOR
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================
# SPINNER (FIX NO BUG)
# ==============================
spinner() {
    local pid=$1
    local msg="$2"
    local spin='-\|/'
    local i=0

    tput civis 2>/dev/null || true

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${CYAN}[INFO]${NC} %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.2
    done

    printf "\r"
    tput cnorm 2>/dev/null || true
}

# ==============================
# RUN STEP
# ==============================
run_step() {
    local MSG="$1"
    shift

    "$@" >> "$MAIN_LOG" 2>&1 &
    PID=$!

    spinner $PID "$MSG"
    wait $PID

    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} $MSG gagal!"
        echo -e "${YELLOW}[INFO]${NC} Cek log: $MAIN_LOG"
        exit 1
    fi

    echo -e "${GREEN}[OK]${NC} $MSG"
}

# ==============================
# FIX APT LOCK (ANTI RACE)
# ==============================
fix_apt_lock() {
    echo -e "${CYAN}[INFO]${NC} Preparing apt (anti race)..."

    systemctl stop apt-daily.service 2>/dev/null || true
    systemctl stop apt-daily-upgrade.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily-upgrade.service 2>/dev/null || true

    (
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
            sleep 2
        done
    ) &

    spinner $! "Waiting apt lock"

    dpkg --configure -a >> "$MAIN_LOG" 2>&1 || true

    echo -e "${GREEN}[OK]${NC} apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}        N8N INSTALLER WIZARD${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ==============================
# STEP 1
# ==============================
echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 1/5] Prepare system${NC}"
echo -e "${YELLOW}--------------------------------------------${NC}"

fix_apt_lock

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

echo -e "${GREEN}[OK]${NC} Docker ready"

# ==============================
# STEP 2
# ==============================
echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 2/5] Configuration${NC}"
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

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""
    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo -e "${RED}[ERROR]${NC} Password mismatch"
done
POSTGRES_NON_ROOT_PASSWORD=$P1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)
INSTALL_DIR="/opt/n8n"

# ==============================
# STEP 3
# ==============================
echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/5] Prepare environment${NC}"
echo -e "${YELLOW}--------------------------------------------${NC}"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_step "Cloning repository" git clone https://github.com/KnowLedZ/n8n-http.git . || true

IP=$(hostname -I | awk '{print $1}')

cat <<EOF > .env
N8N_VERSION=stable
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD
RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
FQDN=$IP
EOF

echo -e "${GREEN}[OK]${NC} Config ready"

# ==============================
# STEP 4
# ==============================
echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 4/5] Starting containers${NC}"
echo -e "${YELLOW}--------------------------------------------${NC}"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &
spinner $! "Deploying containers"
wait $!

echo -e "${GREEN}[OK]${NC} Containers created"

echo -e "${CYAN}[INFO]${NC} Waiting PostgreSQL..."

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
        $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) \
        2>/dev/null || echo "starting")

    printf "\r${CYAN}[INFO]${NC} Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo -e "${GREEN}[OK]${NC} PostgreSQL ready"

# ==============================
# STEP 5
# ==============================
echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 5/5] Finalizing${NC}"
echo -e "${YELLOW}--------------------------------------------${NC}"

docker compose up -d >> "$DOCKER_LOG" 2>&1

echo -e "${CYAN}[INFO]${NC} Waiting n8n..."

for i in {1..60}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)
    printf "\r${CYAN}[INFO]${NC} n8n: %d (%d/60)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 2 ]] && break
    sleep 2
done

echo ""
echo -e "${GREEN}[OK]${NC} n8n running"

echo ""
echo -e "${CYAN}[INFO]${NC} Container status:"
docker ps

# ==============================
# DONE
# ==============================
echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}        INSTALLATION COMPLETE${NC}"
echo -e "${BLUE}======================================${NC}"

echo -e "${CYAN}URL:${NC}"
echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"

echo ""
echo -e "${CYAN}TOKEN:${NC}"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo -e "${CYAN}LOG:${NC}"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
