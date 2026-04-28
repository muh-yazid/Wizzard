#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# SPINNER
# ==============================
spinner() {
    local pid=$1
    local msg=$2
    local spin='-\|/'
    local i=0

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.2
    done

    printf "\r"
}

# ==============================
# WAIT APT
# ==============================
wait_apt() {
    echo "[INFO] Preparing apt..."

    (
        sleep 5
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
            sleep 2
        done
    ) &

    PID=$!
    spinner $PID "Waiting apt lock"
    wait $PID

    echo "[OK] apt ready"
}

# ==============================
# RUN WITH SPINNER
# ==============================
run_step() {
    local MSG="$1"
    shift

    "$@" >> "$MAIN_LOG" 2>&1 &
    PID=$!

    spinner $PID "$MSG"
    wait $PID

    if [ $? -ne 0 ]; then
        echo "[ERROR] $MSG failed!"
        echo "[INFO] Check log: $MAIN_LOG"
        exit 1
    fi

    echo "[OK] $MSG"
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
# STEP 1
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 1/5] Prepare system"
echo "------------------------------------------"

wait_apt

echo "[INFO] Download Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh >> "$MAIN_LOG" 2>&1

run_step "Installing Docker" sh get-docker.sh
run_step "Starting Docker" bash -c "systemctl start docker || service docker start || true"

echo "[OK] Docker ready"

# ==============================
# STEP 2
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 2/5] Configuration setup"
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
# STEP 3
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 3/5] Prepare environment"
echo "------------------------------------------"

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

echo "[OK] Config ready"

# ==============================
# STEP 4
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 4/5] Starting containers"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &
PID=$!
spinner $PID "Deploying containers"
wait $PID

echo "[OK] Containers created"

# WAIT postgres (safe)
POSTGRES_CONTAINER=""
for i in {1..10}; do
    POSTGRES_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep postgres | head -n1)
    [[ -n "$POSTGRES_CONTAINER" ]] && break
    sleep 2
done

echo "[INFO] Waiting PostgreSQL..."

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# STEP 5
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 5/5] Finalizing"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1

for i in {1..60}; do
    RUNNING=$(docker ps --filter "status=running" --format '{{.Names}}' | grep -c n8n || true)

    printf "\r[INFO] n8n running: %d (%d/60)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 1 ]] && break
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
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
