#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Indic Dictation"
VERSION="${INDIC_DICTATION_VERSION:-dev}"
DIST_DIR="${INDIC_DICTATION_DIST_DIR:-$ROOT/dist}"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_NAME="Indic-Dictation-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
TEMP_DMG="$DIST_DIR/$APP_NAME.tmp.dmg"
SIGN_IDENTITY="${INDIC_DICTATION_DMG_SIGN_IDENTITY:-${INDIC_DICTATION_SIGN_IDENTITY:-}}"

mkdir -p "$DIST_DIR"
rm -rf "$DMG_STAGING" "$DMG_PATH" "$TEMP_DMG"

APP_PATH="$("$ROOT/scripts/package_app.sh" --release | tail -n 1)"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Package script did not produce an app bundle." >&2
  exit 1
fi

mkdir -p "$DMG_STAGING"
ditto --noextattr --norsrc "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDRW \
  "$TEMP_DMG" >/dev/null

hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGING" "$TEMP_DMG"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi

echo "$DMG_PATH"
