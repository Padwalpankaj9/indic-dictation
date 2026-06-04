#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 path/to/Indic-Dictation.dmg" >&2
  exit 2
fi

DMG_PATH="$1"
PROFILE="${INDIC_DICTATION_NOTARY_PROFILE:-indic-dictation}"
APPLE_ID="${INDIC_DICTATION_NOTARY_APPLE_ID:-}"
TEAM_ID="${INDIC_DICTATION_NOTARY_TEAM_ID:-}"
PASSWORD="${INDIC_DICTATION_NOTARY_PASSWORD:-}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$PROFILE" \
    --wait
else
  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$PASSWORD" ]]; then
    cat >&2 <<EOF
Missing notarization credentials.

Preferred setup:

  xcrun notarytool store-credentials "$PROFILE" \\
    --apple-id "you@example.com" \\
    --team-id "TEAMID"

Then run:

  $0 "$DMG_PATH"

Environment fallback:

  INDIC_DICTATION_NOTARY_APPLE_ID
  INDIC_DICTATION_NOTARY_TEAM_ID
  INDIC_DICTATION_NOTARY_PASSWORD
EOF
    exit 1
  fi

  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$PASSWORD" \
    --wait
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
