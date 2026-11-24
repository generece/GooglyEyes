#!/bin/bash
# GooglyEyes kurulum / güncelleme
# Kullanım:  curl -fsSL https://raw.githubusercontent.com/generece/GooglyEyes/main/install.sh | bash
# GitHub'daki son sürümü indirir, bu Mac'te derler, ~/Applications'a kurar ve başlatır.
set -e

REPO="generece/GooglyEyes"
DIR="$HOME/Library/Application Support/GooglyEyes"
mkdir -p "$DIR"

echo "→ Son sürüm bilgisi alınıyor…"
SHA=$(curl -fsSL "https://api.github.com/repos/$REPO/commits/main" 2>/dev/null \
      | grep -m1 '"sha"' | sed -E 's/.*"sha": *"([0-9a-f]+)".*/\1/') || true
[ -n "$SHA" ] || SHA="unknown"

echo "→ İndiriliyor…"
TMP="$(mktemp -d)"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.zip" -o "$TMP/src.zip"
ditto -x -k "$TMP/src.zip" "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -type d -name 'GooglyEyes-*' | head -1)"
[ -n "$SRC" ] || { echo "İndirilen arşiv açılamadı."; exit 1; }

rm -rf "$DIR/src"
mv "$SRC" "$DIR/src"
rm -rf "$TMP"

GOOGLY_COMMIT="$SHA" bash "$DIR/src/build.sh"
