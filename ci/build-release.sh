#!/bin/bash
# GitHub Actions'ta çalışır: iki mimari için derler, birleştirir, sabit sertifikayla imzalar, zip'ler.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/GooglyEyes.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  echo "→ Derleniyor: $ARCH"
  xcrun swiftc -O -target "$ARCH-apple-macos12.0" \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    main.swift -o "dist/GooglyEyes-$ARCH"
done
lipo -create -output "$APP/Contents/MacOS/GooglyEyes" dist/GooglyEyes-arm64 dist/GooglyEyes-x86_64

cp Info.plist "$APP/Contents/"
cp Resources/* "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :GooglyCommit string ${GITHUB_SHA:-unknown}" "$APP/Contents/Info.plist"

if [ -n "${CERT_P12:-}" ]; then
  echo "→ Sabit sertifikayla imzalanıyor"
  KC="$RUNNER_TEMP/sign.keychain-db"
  security create-keychain -p ci "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p ci "$KC"
  printf '%s' "$CERT_P12" | base64 --decode > "$RUNNER_TEMP/id.p12"
  security import "$RUNNER_TEMP/id.p12" -k "$KC" -P "$CERT_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k ci "$KC" >/dev/null
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  # kendinden imzalı sertifikaya kod imzalama için güven ver (sadece bu derleme makinesinde)
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain ci/signing-cert.pem
  codesign --force --deep --sign "GooglyEyes Signing" --keychain "$KC" "$APP"
else
  echo "⚠︎ CERT_P12 yok: geçici imza (izinler her güncellemede sıfırlanabilir)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | tail -1

(cd dist && ditto -c -k --keepParent GooglyEyes.app GooglyEyes.zip)
ls -la dist
