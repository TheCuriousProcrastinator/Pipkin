#!/bin/bash
#
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Pipkin"
EXEC="pipkin"
APP="build/$APP_NAME.app"
DEPLOY="14.0"
VERSION="$(tr -d '[:space:]' < VERSION)"

DEBUG_FLAGS=""
INSTALL=0
ARCHS=(x86_64 arm64)
OPT="-O"

for arg in "$@"; do
    case "$arg" in
        --debug)   DEBUG_FLAGS="-D DEBUG -g"; OPT="-Onone" ;;
        --install) INSTALL=1 ;;
        --fast)    ARCHS=("$(uname -m)") ;;
        *) echo "[build-app] : $arg"; exit 1 ;;
    esac
done

FRAMEWORKS=(
    -framework AppKit
    -framework ScreenCaptureKit
    -framework AVFoundation
    -framework CoreMedia
    -framework CoreVideo
    -framework CoreImage
    -framework CoreGraphics
    -framework Carbon
)

echo "[build-app] Building $EXEC v$VERSION (${ARCHS[*]}) ..."
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "[build-app]   - Building $arch ..."
    swiftc $OPT $DEBUG_FLAGS -target "${arch}-apple-macos${DEPLOY}" \
        -o "build/obj/${EXEC}-${arch}" Sources/"$EXEC"/*.swift \
        "${FRAMEWORKS[@]}"
    SLICES+=("build/obj/${EXEC}-${arch}")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$EXEC"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/$EXEC"
fi
echo "[build-app] Architectures: $(lipo -archs "$APP/Contents/MacOS/$EXEC")"

cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null

if [ -f Resources/AppIcon.png ]; then
    echo "[build-app] Generating AppIcon.icns ..."
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     Resources/AppIcon.png --out "$ICONSET/icon_16x16.png"      >/dev/null
    sips -z 32 32     Resources/AppIcon.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
    sips -z 32 32     Resources/AppIcon.png --out "$ICONSET/icon_32x32.png"      >/dev/null
    sips -z 64 64     Resources/AppIcon.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
    sips -z 128 128   Resources/AppIcon.png --out "$ICONSET/icon_128x128.png"    >/dev/null
    sips -z 256 256   Resources/AppIcon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   Resources/AppIcon.png --out "$ICONSET/icon_256x256.png"    >/dev/null
    sips -z 512 512   Resources/AppIcon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   Resources/AppIcon.png --out "$ICONSET/icon_512x512.png"    >/dev/null
    cp Resources/AppIcon.png "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-Pipkin Release Signing}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/mywindowpip-release.keychain-db}"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ -f "$SIGN_KEYCHAIN" ]; then
    SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
fi

if /usr/bin/codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1; then
    echo "[build-app] Signed with ${SIGN_IDENTITY}"
else
    /usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "[build-app] WARNING: signing with ${SIGN_IDENTITY} failed; falling back to ad-hoc signing"
    echo "[build-app]          Screen Recording permission will not persist across ad-hoc builds"
fi

if /usr/bin/codesign -d -r- "$APP" 2>&1 | grep -q 'designated => cdhash'; then
    echo "[build-app] WARNING: designated requirement is still cdhash; Screen Recording permission may need to be granted again after rebuilding"
fi

echo "[build-app] Created $APP"

if [ "$INSTALL" = "1" ]; then
    echo "[build-app] Installing to /Applications ..."
    pkill -x "$EXEC" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "[build-app] Installed /Applications/$APP_NAME.app"
fi
