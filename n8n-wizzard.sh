#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# PROGRESS BAR
# ==============================
progress_bar() {
    local duration=$1
    local msg=$2

    echo "[INFO] $msg"

    for ((i=1;i<=duration;i++)); do
        percent=$(( i * 100 / duration ))
        filled=$(( percent / 2 ))
        empty=$((50 - filled))

        printf "\r[%-50s] %3d%%" \
        "$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s")" \
        "$percent"

        sleep 0.2
    done

    echo ""
}

# ==============================
# WAIT APT (SAFE)
# ==============================
wait_apt() {
    echo "[INFO] Preparing apt (production-safe)..."

    sleep 5

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        echo "[WAIT] apt locked... retry"
        sleep 3
    done

    echo "[OK] apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "=========================================="
echo "         N8N INSTALLER WIZARD"
echo "=========================================="
echo ""

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}

[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0

# ==============================
# STEP 1 - SYSTEM
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 1/6] Prepare system"
echo "------------------------------------------"

wait_apt

echo "[INFO] Download Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh >> "$MAIN_LOG" 2>&1

progress_bar 20 "Preparing Docker install"

for i in {1..3}; do
    echo "[INFO] Install Docker attempt $i..."
    if sh get-docker.sh >> "$MAIN_LOG" 2>&1; then
        echo "[OK] Docker installed"
        break
    fi
    sleep 5
done

systemctl start docker || service docker start || true
echo "[OK] Docker ready"

# ==============================
# STEP 2 - INPUT
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 2/6] Configuration setup"
echo "------------------------------------------"
echo ""

read -p "Domain: " DOMAIN

read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""
    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done
POSTGRES_PASSWORD=$P1

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""
    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done
POSTGRES_NON_ROOT_PASSWORD=$P1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)
INSTALL_DIR="/opt/n8n"

# ==============================
# STEP 3 - PREPARE
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 3/6] Prepare environment"
echo "------------------------------------------"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "[INFO] Cloning repo..."
git clone https://github.com/KnowLedZ/n8n-http.git . >> "$MAIN_LOG" 2>&1 || true

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

echo "[OK] Config ready"

# ==============================
# STEP 4 - START CONTAINER
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 4/6] Starting containers"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &

PID=$!

for i in {1..40}; do
    percent=$(( i * 100 / 40 ))
    printf "\r[INFO] Deploying containers... %d%%" "$percent"
    sleep 0.5
done

wait $PID
echo ""
echo "[OK] Containers created"

# ==============================
# STEP 5 - WAIT POSTGRES
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 5/6] Waiting PostgreSQL"
echo "------------------------------------------"

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
        $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) \
        2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# STEP 6 - WAIT N8N
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 6/6] Finalizing"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1

for i in {1..60}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)
    printf "\r[INFO] n8n: %d (%d/60)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 2 ]] && break
    sleep 2
done

echo ""
echo "[OK] n8n running"

echo ""
echo "[INFO] Container status:"
docker ps

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "URL:"
echo "Domain : http://$DOMAIN"
echo "IP      : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
