#!/bin/bash
set -e

URL_SCRIPT="https://raw.githubusercontent.com/KnowLedZ/Wizzard/main/n8n-wizzard.sh"

echo "======================================"
echo "     N8N BOOTSTRAP INITIALIZER"
echo "======================================"
echo ""

echo "[INFO] Downloading installer..."
curl -L -f "$URL_SCRIPT" -o /root/n8n-installer.sh

chmod +x /root/n8n-installer.sh

echo "[OK] Installer downloaded"
echo ""

echo "[INFO] Running installer..."
echo ""

# ✅ BLOCKING (WAJIB, supaya tidak lanjut sebelum selesai)
exec bash /root/n8n-installer.sh
