#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Qyvro.app"
BACKUP_ROOT="$(cd "$ROOT/.." && pwd)/FPilotMac_Backups"
BACKUP_TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
SOURCE_BACKUP="$BACKUP_ROOT/FPilotMac_prebuild_$BACKUP_TIMESTAMP.zip"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fpilotmac-build.XXXXXX")"
APP_DIR="$BUILD_ROOT/$APP_NAME"
EXECUTABLE="$APP_DIR/Contents/MacOS/Qyvro"
X86_EXECUTABLE="$BUILD_ROOT/Qyvro-x86_64"
ARM_EXECUTABLE="$BUILD_ROOT/Qyvro-arm64"
SWIFT_SOURCES=("$ROOT"/Sources/*.swift)
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

# After a partial Command Line Tools update the unversioned SDK symlink can
# briefly point at a newer SDK than the installed Swift compiler understands.
# The stable 15.4 SDK is sufficient for our macOS 13 deployment target and
# keeps local Universal builds reproducible on both Intel and Apple Silicon.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$BUILD_ROOT/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

mkdir -p "$BACKUP_ROOT"
(
  cd "$ROOT"
  /usr/bin/zip -qry "$SOURCE_BACKUP" \
    Sources \
    Resources \
    Tests \
    build_app.sh \
    ./*.md
)
/usr/bin/unzip -tqq "$SOURCE_BACKUP"
echo "Source backup: $SOURCE_BACKUP"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

xcrun swiftc \
  -O \
  -target x86_64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -framework AVFoundation \
  -framework Carbon \
  -framework Cocoa \
  -framework CoreImage \
  -framework CoreVideo \
  -framework IOSurface \
  -framework Metal \
  -framework Quartz \
  -framework QuickLookThumbnailing \
  "${SWIFT_SOURCES[@]}" \
  -o "$X86_EXECUTABLE" &
X86_BUILD_PID=$!

xcrun swiftc \
  -O \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -framework AVFoundation \
  -framework Carbon \
  -framework Cocoa \
  -framework CoreImage \
  -framework CoreVideo \
  -framework IOSurface \
  -framework Metal \
  -framework Quartz \
  -framework QuickLookThumbnailing \
  "${SWIFT_SOURCES[@]}" \
  -o "$ARM_EXECUTABLE" &
ARM_BUILD_PID=$!

# Both optimized targets are independent, so compiling them together nearly
# halves Universal build time.
wait "$X86_BUILD_PID"
wait "$ARM_BUILD_PID"

lipo -create "$X86_EXECUTABLE" "$ARM_EXECUTABLE" -output "$EXECUTABLE"

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/Qyvro.icns" "$APP_DIR/Contents/Resources/Qyvro.icns"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
find "$APP_DIR" -name '._*' -delete
dot_clean -m "$APP_DIR" 2>/dev/null || true
/usr/bin/xattr -rc "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
