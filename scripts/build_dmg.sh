#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
fi

DERIVED_DATA_DIR="$ROOT_DIR/.build/ReleaseBuild"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/dmg-staging"

rm -rf "$DERIVED_DATA_DIR" "$STAGING_DIR"
mkdir -p "$DIST_DIR" "$STAGING_DIR"

echo "==> Building RecordOS (Release)..."
xcodebuild \
    -project "$ROOT_DIR/RecordOS.xcodeproj" \
    -scheme RecordOS \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/RecordOS.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: Built app not found at $APP_PATH" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
DMG_NAME="RecordOS-${VERSION}-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "==> Verifying code signature for RecordOS v${VERSION} (Build ${BUILD_NUM})..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Preparing DMG staging folder..."
ditto "$APP_PATH" "$STAGING_DIR/RecordOS.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
echo "==> Creating compressed DMG at $DMG_PATH..."
hdiutil create \
    -volname "RecordOS ${VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> Done: $DMG_PATH"
ls -lh "$DMG_PATH"
