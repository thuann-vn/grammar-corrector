#!/bin/bash
# Builds GrammarCorrector.app (a menu-bar-only app, no Dock icon) and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"

# Universal binary (Apple Silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/GrammarCorrector"

APP="build/GrammarCorrector.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Grammar Corrector</string>
    <key>CFBundleIdentifier</key><string>com.local.GrammarCorrector</string>
    <key>CFBundleExecutable</key><string>GrammarCorrector</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS keeps the Accessibility permission across rebuilds.
# Uses $SIGN_IDENTITY, else the first "Apple Development" certificate, else ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (Accessibility permission resets on every rebuild)."
    echo "Tip: Xcode > Settings > Accounts > Manage Certificates > + Apple Development"
fi
echo "Built $APP"

# Install to /Applications (set INSTALL=0 to skip) and restart the running copy.
if [ "${INSTALL:-1}" = "1" ]; then
    DEST="/Applications/GrammarCorrector.app"
    # Only replace a previous install of this same app.
    if [ -e "$DEST" ] && [ "$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "com.local.GrammarCorrector" ]; then
        echo "Refusing to overwrite $DEST: it is a different app." >&2
        exit 1
    fi
    pkill -f "GrammarCorrector.app/Contents/MacOS/GrammarCorrector" || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
