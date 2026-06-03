#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Marathi Dictation"
EXECUTABLE_NAME="MarathiDictationApp"
RESOURCE_BUNDLE_NAME="SwiftMarathiDictation_MarathiDictationApp.bundle"
CONFIG="release"
INSTALL_APP=false

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIG="debug"
      ;;
    --release)
      CONFIG="release"
      ;;
    --install)
      INSTALL_APP=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT"
swift build -c "$CONFIG"

EXECUTABLE="$ROOT/.build/$CONFIG/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
  EXECUTABLE="$(find "$ROOT/.build" -path "*/$CONFIG/$EXECUTABLE_NAME" -type f -perm -111 | head -n 1)"
fi

RESOURCE_BUNDLE="$(find "$ROOT/.build" -path "*/$CONFIG/$RESOURCE_BUNDLE_NAME" -type d | head -n 1)"

if [[ -z "${EXECUTABLE:-}" || ! -x "$EXECUTABLE" ]]; then
  echo "Could not find built executable for $CONFIG." >&2
  exit 1
fi

if [[ -z "${RESOURCE_BUNDLE:-}" || ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Could not find Swift resource bundle for $CONFIG." >&2
  exit 1
fi

DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
cp "$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
cp "$ROOT/Sources/MarathiDictationApp/Resources/Icons/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

chmod 755 "$CONTENTS/MacOS/$EXECUTABLE_NAME"
plutil -lint "$CONTENTS/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"

if [[ "$INSTALL_APP" == true ]]; then
  INSTALLED_APP="/Applications/$APP_NAME.app"
  rm -rf "$INSTALLED_APP"
  ditto "$APP_DIR" "$INSTALLED_APP"
  echo "$INSTALLED_APP"
fi
