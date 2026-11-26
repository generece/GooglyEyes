#!/bin/bash
# GooglyEyes kurulum / güncelleme (Xcode gerekmez)
# Kullanım:  curl -fsSL https://raw.githubusercontent.com/generece/GooglyEyes/main/install.sh | bash
# GitHub'daki en son hazır sürümü indirir, ~/Applications'a kurar ve başlatır.
set -e

REPO="generece/GooglyEyes"
URL="https://github.com/$REPO/releases/latest/download/GooglyEyes.zip"

echo "→ Son sürüm indiriliyor…"
TMP="$(mktemp -d)"
curl -fsSL "$URL" -o "$TMP/GooglyEyes.zip"
ditto -x -k "$TMP/GooglyEyes.zip" "$TMP"
[ -d "$TMP/GooglyEyes.app" ] || { echo "İndirilen dosya açılamadı."; exit 1; }
xattr -dr com.apple.quarantine "$TMP/GooglyEyes.app" 2>/dev/null || true

DEST="$HOME/Applications/GooglyEyes.app"
mkdir -p "$HOME/Applications"
# -a: güncelleme uygulamanın içinden başlatıldığında da onu kapat
pkill -a -x GooglyEyes 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
mv "$TMP/GooglyEyes.app" "$DEST"
rm -rf "$TMP"

echo "→ Kuruldu: $DEST"
open "$DEST"
echo "✓ Gözler menü çubuğunda!"
