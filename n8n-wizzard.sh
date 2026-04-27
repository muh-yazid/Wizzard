#!/bin/bash

set -e

LOG_FILE="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$LOG_FILE") 2>&1

spinner() {
    local pid=$1
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%c] Working..." "${spin:$i:1}"
        sleep 0.2
    done
    printf "\r"
}

run_step_bg() {
    DESC="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $DESC"
    echo "======================================"

    "$@" >> "$LOG_FILE" 2>&1 &
    PID=$!

    spinner $PID
    wait $PID

    echo "[OK] $DESC"
}

clear
echo "----------------------------------------"
echo "   N8N INSTALLER + WIZARD"
echo "----------------------------------------"

# ==============================
# CONFIRM
# ==============================
read -p "Start wizard? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 0

# ==============================
# WAIT APT LOCK
# ==============================
echo "[INFO] Waiting apt lock..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done

# ==============================
# INSTALL DOCKER
# ==============================
run_step_bg "Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_step_bg "Install Docker" sh get-docker.sh

systemctl start docker || service docker start || true

# ==============================
# INPUT
# ==============================
read -p "Domain: " DOMAIN

read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_PASSWORD=$P1

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_NON_ROOT_PASSWORD=$P1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

INSTALL_DIR="/opt/n8n"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# ==============================
# CLONE REPO
# ==============================
run_step_bg "Clone repo" git clone https://github.com/KnowLedZ/n8n-http.git . || true

IP=$(hostname -I | awk '{print $1}')

# ==============================
# ENV
# ==============================
cat <<EOF > .env
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

N8N_SECURE_COOKIE=false
N8N_HOST=$IP:5678
WEBHOOK_URL=http://$IP:5678/

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
EOF

# ==============================
# START DOCKER
# ==============================
echo "[INFO] Starting containers..."
docker compose up -d > "$DOCKER_LOG" 2>&1

# ==============================
# WAIT POSTGRES HEALTH
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..40}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' n8n-postgres-1 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %s (%d/40)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 3
done

echo ""

# ==============================
# ENSURE RUNNING
# ==============================
docker compose up -d >> "$DOCKER_LOG" 2>&1

# ==============================
# WAIT N8N
# ==============================
echo "[INFO] Waiting n8n..."

for i in {1..40}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n-n8n-1)
    printf "\r[INFO] n8n: %d (%d/40)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 1 ]] && break
    sleep 3
done

echo ""

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "$LOG_FILE"
echo "$DOCKER_LOG"
