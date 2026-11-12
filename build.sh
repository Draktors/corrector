#!/bin/bash
# Compile Correcteur.app et crée Correcteur.zip à envoyer.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Correcteur.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/Correcteur"

cp Info.plist "$APP/Contents/Info.plist"
# Exigence de signature fixée sur l'identifiant : macOS garde l'autorisation Accessibilité d'une compilation à l'autre.
codesign --force --sign - -r='designated => identifier "com.local.correcteur"' "$APP"

(cd build && ditto -c -k --keepParent Correcteur.app Correcteur.zip)
echo "OK -> $(pwd)/$APP"
