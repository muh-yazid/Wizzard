#!/bin/bash
set -e

MAIN_LOG="/var/log/paperclip-install.log"
DOCKER_LOG="/var/log/paperclip-docker.log"

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
echo -e "${BLUE}        PAPERCLIP INSTALLER WIZARD${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

read -p "Start Paperclip configuration wizard? (Y/n): " CONFIRM
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

PAPERCLIP_SECRET_KEY=$(openssl rand -hex 16)
PAPERCLIP_WEBHOOK_SECRET=$(openssl rand -hex 16)
INSTALL_DIR="/opt/paperclip"

# ==============================
# STEP 3
# ==============================
echo ""
echo -e "${YELLOW}--------------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/5] Prepare environment${NC}"
echo -e "${YELLOW}--------------------------------------------${NC}"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_step "Cloning repository" git clone https://github.com/KnowLedZ/paperclip-ai.git . || true

IP=$(hostname -I | awk '{print $1}')

cat <<EOF > .env
# Database (required)
PAPERCLIP_DB_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}

# Job queue (required for production)
PAPERCLIP_REDIS_URL=redis://redis:6379

# LLM providers (at least one required)
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...

# Security (required for production)
PAPERCLIP_SECRET_KEY=generate-a-random-64-char-string
PAPERCLIP_CORS_ORIGINS=https://${IP}

# Optional: telemetry and logging
PAPERCLIP_LOG_LEVEL=info
PAPERCLIP_TELEMETRY=false

# Optional: vector search for RAG
PAPERCLIP_QDRANT_URL=http://qdrant:6333

# Optional: webhook signing
PAPERCLIP_WEBHOOK_SECRET=${PAPERCLIP_WEBHOOK_SECRET}
PAPERCLIP_SECRET_KEY=${PAPERCLIP_SECRET_KEY}
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

echo -e "${CYAN}[INFO]${NC} Waiting paperclip..."

for i in {1..60}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c paperclip || true)
    printf "\r${CYAN}[INFO]${NC} paperclip: %d (%d/60)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 2 ]] && break
    sleep 2
done

echo ""
echo -e "${GREEN}[OK]${NC} paperclip running"

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

echo -e "${CYAN}DASHBOARD URL:${NC}"
echo "Domain : http://$DOMAIN:3000""
echo "IP     : http://$IP:3000"

echo -e "${CYAN}API URL:${NC}"
echo "Domain : http://$DOMAIN:3001""
echo "IP     : http://$IP:3001"

echo ""
echo -e "${CYAN}TOKEN:${NC}"
echo "$PAPERCLIP_SECRET_KEY"

echo ""
echo -e "${CYAN}LOG:${NC}"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
