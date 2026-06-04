#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 path/to/Indic-Dictation.dmg" >&2
  exit 2
fi

DMG_PATH="$1"
APPLE_ID="${INDIC_DICTATION_NOTARY_APPLE_ID:-}"
TEAM_ID="${INDIC_DICTATION_NOTARY_TEAM_ID:-}"
PASSWORD="${INDIC_DICTATION_NOTARY_PASSWORD:-}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$PASSWORD" ]]; then
  cat >&2 <<'EOF'
Missing notarization environment variables:

  INDIC_DICTATION_NOTARY_APPLE_ID
  INDIC_DICTATION_NOTARY_TEAM_ID
  INDIC_DICTATION_NOTARY_PASSWORD

Use an app-specific password or a notarytool keychain profile.
EOF
  exit 1
fi

xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$PASSWORD" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
