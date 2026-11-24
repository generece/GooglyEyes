#!/bin/bash
# GooglyEyes'ı derler, sabit bir yerel sertifikayla imzalar, ~/Applications'a kurar ve başlatır.
# Sabit imza sayesinde macOS her derlemeyi aynı uygulama sayar ve Ekran Kaydı izni korunur.
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift derleyicisi yok. Açılan pencerede 'Yükle'ye bas, bitince bu scripti tekrar çalıştır."
  xcode-select --install || true
  exit 1
fi

IDENT="GooglyEyes Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# --- Bir kerelik: yerel imza sertifikası oluştur ---
if ! security find-certificate -c "$IDENT" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "→ Bir kerelik imza sertifikası oluşturuluyor (Mac şifren istenebilir)…"
  TMPD="$(mktemp -d)"
  cat > "$TMPD/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENT
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" -config "$TMPD/cert.cnf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMPD/key.pem" -in "$TMPD/cert.pem" \
    -out "$TMPD/id.p12" -passout pass:googly -name "$IDENT" >/dev/null 2>&1
  security import "$TMPD/id.p12" -k "$KEYCHAIN" -P googly -T /usr/bin/codesign >/dev/null
  echo "→ Sertifikaya kod imzalama için güven veriliyor (şifre penceresi açılırsa onayla)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMPD/cert.pem" || true
  rm -rf "$TMPD"
fi

APP="build/GooglyEyes.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Derleniyor…"
xcrun swiftc -O -target "$(uname -m)-apple-macos12.0" \
  -framework Cocoa -framework Carbon -framework ServiceManagement \
  main.swift -o "$APP/Contents/MacOS/GooglyEyes"

cp Info.plist "$APP/Contents/"
cp Resources/* "$APP/Contents/Resources/"

# Hangi sürüm olduğunu uygulamaya yaz (Güncellemeleri Kontrol Et bunu GitHub'la karşılaştırır)
COMMIT="${GOOGLY_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
/usr/libexec/PlistBuddy -c "Add :GooglyCommit string $COMMIT" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Set :GooglyCommit $COMMIT" "$APP/Contents/Info.plist"

if codesign --force --deep --sign "$IDENT" "$APP" 2>/tmp/googly-sign.log; then
  echo "→ Sabit sertifikayla imzalandı."
else
  echo "⚠︎ Sabit imza başarısız, geçici imza kullanılıyor (izin her derlemede tekrar istenebilir):"
  cat /tmp/googly-sign.log
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

DEST="$HOME/Applications/GooglyEyes.app"
mkdir -p "$HOME/Applications"
pkill -x GooglyEyes 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "→ Kuruldu: $DEST"
open "$DEST"
echo "✓ Gözler menü çubuğunda!"
