#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# SPINNER (FIXED)
# ==============================
spinner() {
    local pid=$1
    local msg="$2"
    local spin=('|' '/' '-' '\')
    local i=0

    while kill -0 $pid 2>/dev/null; do
        printf "\r[INFO] %s... %s " "$msg" "${spin[$i]}"
        i=$(( (i+1) %4 ))
        sleep 0.2
    done

    printf "\r\033[K"
}

# ==============================
# WAIT APT (NO GLITCH)
# ==============================
wait_apt() {
    echo "[INFO] Preparing apt..."

    (
        while true; do
            if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
               ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then

                sleep 3

                if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
                    break
                fi
            fi
            sleep 1
        done
    ) &

    spinner $! "Waiting apt lock"
    wait $!

    echo "[OK] apt ready"
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
# STEP 4 (POSTGRES ONLY)
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 4/5] Start PostgreSQL"
echo "------------------------------------------"

docker compose up -d postgres >> "$DOCKER_LOG" 2>&1 &
spinner $! "Starting PostgreSQL"
wait $!

echo "[OK] PostgreSQL container started"

echo "[INFO] Waiting PostgreSQL healthy..."

while true; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' n8n-postgres-1 2>/dev/null || echo "starting")
    printf "\r[INFO] Postgres status: %-10s" "$STATUS"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

printf "\r\033[K"
echo "[OK] PostgreSQL ready"

# ==============================
# STEP 5 (ALL SERVICES)
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 5/5] Starting N8N"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &
spinner $! "Starting n8n services"
wait $!

echo "[OK] Containers started"

echo "[INFO] Waiting n8n..."

while true; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)
    printf "\r[INFO] n8n containers: %d" "$RUNNING"

    [[ "$RUNNING" -ge 2 ]] && break
    sleep 2
done

printf "\r\033[K"
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
