#!/bin/bash
set -e

URL_SCRIPT="https://raw.githubusercontent.com/KnowLedZ/Wizzard/main/paperclip-wizzard.sh"

echo "======================================"
echo "     PAPERCLIP BOOTSTRAP INITIALIZER"
echo "======================================"
echo ""

echo "[INFO] Downloading installer..."
curl -L -f "$URL_SCRIPT" -o /root/paperclip-installer.sh

chmod +x /root/paperclip-installer.sh

echo "[OK] Installer downloaded"
echo ""

echo "[INFO] Running installer..."
echo ""

# ✅ BLOCKING (WAJIB, supaya tidak lanjut sebelum selesai)
exec bash /root/paperclip-installer.sh
