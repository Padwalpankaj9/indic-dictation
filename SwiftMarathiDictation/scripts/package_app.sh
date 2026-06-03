#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Indic Dictation"
EXECUTABLE_NAME="IndicDictationApp"
RESOURCE_BUNDLE_NAME="SwiftIndicDictation_MarathiDictationApp.bundle"
CONFIG="release"
INSTALL_APP=false
SIGN_IDENTITY="${INDIC_DICTATION_SIGN_IDENTITY:-${MARATHI_DICTATION_SIGN_IDENTITY:-}}"

clean_bundle_metadata() {
  local bundle_path="$1"
  xattr -cr "$bundle_path" 2>/dev/null || true
  find "$bundle_path" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
  find "$bundle_path" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
}

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

DIST_DIR="${INDIC_DICTATION_DIST_DIR:-${MARATHI_DICTATION_DIST_DIR:-${TMPDIR:-/tmp}/indic-dictation-dist}}"
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
clean_bundle_metadata "$APP_DIR"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development: padwalpankaj9@gmail.com/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No stable code signing identity found. Falling back to ad-hoc signing." >&2
  SIGN_IDENTITY="-"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
clean_bundle_metadata "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"

if [[ "$INSTALL_APP" == true ]]; then
  INSTALLED_APP="/Applications/$APP_NAME.app"
  rm -rf "$INSTALLED_APP"
  ditto --noextattr --norsrc "$APP_DIR" "$INSTALLED_APP"
  clean_bundle_metadata "$INSTALLED_APP"
  codesign --verify --deep --strict "$INSTALLED_APP"
  echo "$INSTALLED_APP"
fi
