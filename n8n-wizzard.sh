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
# WAIT APT (REAL FIX)
# ==============================
wait_apt() {
    echo "[INFO] Preparing apt..."

    (
        while pgrep -x apt >/dev/null || \
              pgrep -x apt-get >/dev/null || \
              pgrep -x dpkg >/dev/null; do
            sleep 2
        done

        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
            sleep 2
        done
    ) &

    spinner $! "Waiting apt ready"
    wait $!

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
# DOCKER INSTALL SAFE
# ==============================
install_docker_safe() {
    for attempt in 1 2 3; do
        echo "[INFO] Installing Docker (attempt $attempt)..."

        if sh get-docker.sh >> "$MAIN_LOG" 2>&1; then
            echo "[OK] Docker installed"
            return 0
        fi

        echo "[WARN] Install failed, retry..."
        sleep 5
    done

    echo "[ERROR] Docker install failed"
    exit 1
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

install_docker_safe

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

# kasih delay biar postgres init stabil
sleep 5

# ==============================
# STEP 4
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 4/5] Starting containers"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &
spinner $! "Deploying containers"
wait $!

echo "[OK] Containers created"

# ==============================
# WAIT POSTGRES (FIX TOTAL)
# ==============================
echo "[INFO] Waiting PostgreSQL..."

POSTGRES_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep postgres | head -n1)

HEALTH_OK_COUNT=0

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s" "$STATUS"

    if [[ "$STATUS" == "healthy" ]]; then
        HEALTH_OK_COUNT=$((HEALTH_OK_COUNT+1))
    else
        HEALTH_OK_COUNT=0
    fi

    [[ $HEALTH_OK_COUNT -ge 3 ]] && break

    sleep 2
done

echo ""

# fallback retry kalau belum stabil
if [[ $HEALTH_OK_COUNT -lt 3 ]]; then
    echo "[WARN] PostgreSQL belum stabil, restart..."

    docker restart "$POSTGRES_CONTAINER" >> "$DOCKER_LOG" 2>&1
    sleep 5

    for i in {1..30}; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || echo "starting")

        printf "\r[INFO] Retry Postgres: %-10s" "$STATUS"

        [[ "$STATUS" == "healthy" ]] && break
        sleep 2
    done

    echo ""
fi

echo "[OK] PostgreSQL ready"

# ==============================
# STEP 5
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 5/5] Finalizing"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1

echo "[INFO] Waiting n8n..."

for i in {1..60}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)
    printf "\r[INFO] n8n: %d" "$RUNNING"

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
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
