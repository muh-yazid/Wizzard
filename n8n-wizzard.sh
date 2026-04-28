#!/bin/bash
set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# CLEAN SPINNER (NO BUG)
# ==============================
spinner() {
    local pid=$1
    local msg="$2"
    local spin='-\|/'
    local i=0

    tput civis 2>/dev/null || true

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
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
        echo "[ERROR] $MSG gagal!"
        echo "[INFO] Cek log: $MAIN_LOG"
        exit 1
    fi

    echo "[OK] $MSG"
}

# ==============================
# HARD FIX APT LOCK (ANTI RACE)
# ==============================
fix_apt_lock() {
    echo "[INFO] Preparing apt (anti race)..."

    # stop auto apt
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

    # fix dpkg jika nyangkut
    dpkg --configure -a >> "$MAIN_LOG" 2>&1 || true

    echo "[OK] apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "============================================"
echo "        N8N INSTALLER WIZARD"
echo "============================================"
echo ""

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ==============================
# STEP 1 - SYSTEM
# ==============================
echo ""
echo "--------------------------------------------"
echo "[STEP 1/5] Prepare system"
echo "--------------------------------------------"

fix_apt_lock

echo "[INFO] Download Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh >> "$MAIN_LOG" 2>&1

# retry install docker (anti gagal karena apt)
for i in 1 2 3; do
    if run_step "Installing Docker (attempt $i)" sh get-docker.sh; then
        break
    fi
    echo "[WARN] Retry install Docker..."
    sleep 3
done

run_step "Starting Docker" bash -c "systemctl start docker || service docker start || true"

echo "[OK] Docker ready"

# ==============================
# STEP 2 - INPUT
# ==============================
echo ""
echo "--------------------------------------------"
echo "[STEP 2/5] Configuration"
echo "--------------------------------------------"
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
echo "--------------------------------------------"
echo "[STEP 3/5] Prepare environment"
echo "--------------------------------------------"

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
# STEP 4 - DEPLOY
# ==============================
echo ""
echo "--------------------------------------------"
echo "[STEP 4/5] Starting containers"
echo "--------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &
spinner $! "Deploying containers"
wait $!

echo "[OK] Containers created"

# ==============================
# WAIT POSTGRES (FIX UNHEALTHY)
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
        $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) \
        2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    if [[ "$STATUS" == "healthy" ]]; then
        break
    fi

    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# STEP 5 - FINAL
# ==============================
echo ""
echo "--------------------------------------------"
echo "[STEP 5/5] Finalizing"
echo "--------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1

echo "[INFO] Waiting n8n..."

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
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
