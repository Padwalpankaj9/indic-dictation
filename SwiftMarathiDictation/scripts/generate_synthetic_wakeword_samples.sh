#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/Indic Dictation"
MODEL_NAME="hey_vaani"
MODEL_DIR="$APP_SUPPORT/WakeWordTraining/output/$MODEL_NAME"
POSITIVE_TRAIN="$MODEL_DIR/positive_train"
POSITIVE_TEST="$MODEL_DIR/positive_test"
NEGATIVE_TRAIN="$MODEL_DIR/negative_train"
NEGATIVE_TEST="$MODEL_DIR/negative_test"

VOICES=("Rishi" "Lekha")
RATES=(155 175 195 215)

POSITIVE_PHRASES=(
  "Hey Vaani"
  "Hey Vani"
  "हे वाणी"
)

NEGATIVE_PHRASES=(
  "Hey Varun"
  "Hey Vasu"
  "Hey Vaibhav"
  "Hey Rani"
  "Hey Wani"
  "Hey Vaani nahi"
  "Okay Vaani"
  "Are Vaani"
  "Hi Vaani"
  "What are we doing now"
  "Can you write this in English"
  "I am thinking in Marathi"
  "मला हे इंग्रजीत लिहायचे आहे"
  "आज आपण काय करणार आहोत"
  "हे वाक्य इंग्रजीत पाहिजे"
  "मी मराठीत बोलतो आहे"
  "थोडा वेळ थांबा"
  "आता पुढचे काम करूया"
)

mkdir -p "$POSITIVE_TRAIN" "$POSITIVE_TEST" "$NEGATIVE_TRAIN" "$NEGATIVE_TEST"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

next_clip_path() {
  local directory="$1"
  local next_index
  next_index="$(
    find "$directory" -maxdepth 1 -type f -name 'clip_*.wav' -print |
      while IFS= read -r file; do
        basename "$file" .wav | sed -E 's/^clip_([0-9]{6})$/\1/'
      done |
      sort -n |
      tail -n 1
  )"
  if [[ -z "$next_index" ]]; then
    next_index=0
  else
    next_index=$((10#$next_index + 1))
  fi
  printf '%s/clip_%06d.wav' "$directory" "$next_index"
}

target_dir_for() {
  local kind="$1"
  local count="$2"
  if [[ "$kind" == "positive" ]]; then
    if (( count % 5 == 4 )); then
      printf '%s' "$POSITIVE_TEST"
    else
      printf '%s' "$POSITIVE_TRAIN"
    fi
  else
    if (( count % 5 == 4 )); then
      printf '%s' "$NEGATIVE_TEST"
    else
      printf '%s' "$NEGATIVE_TRAIN"
    fi
  fi
}

render_clip() {
  local voice="$1"
  local rate="$2"
  local text="$3"
  local output="$4"
  local tmp
  tmp="$(mktemp -t indic-dictation-say.XXXXXX).aiff"
  say -v "$voice" -r "$rate" -o "$tmp" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp" "$output"
  rm -f "$tmp"
}

generate_kind() {
  local kind="$1"
  local limit="$2"
  shift 2
  local phrases=("$@")
  local generated=0
  local phrase_index=0

  while (( generated < limit )); do
    for voice in "${VOICES[@]}"; do
      for rate in "${RATES[@]}"; do
        local phrase="${phrases[$((phrase_index % ${#phrases[@]}))]}"
        local target_dir
        local output
        target_dir="$(target_dir_for "$kind" "$generated")"
        output="$(next_clip_path "$target_dir")"
        echo "[$kind] $voice $rate: $phrase -> $output"
        render_clip "$voice" "$rate" "$phrase" "$output"
        generated=$((generated + 1))
        phrase_index=$((phrase_index + 1))
        if (( generated >= limit )); then
          return
        fi
      done
    done
  done
}

require_command say
require_command afconvert

POSITIVE_COUNT="${POSITIVE_COUNT:-24}"
NEGATIVE_COUNT="${NEGATIVE_COUNT:-120}"

generate_kind positive "$POSITIVE_COUNT" "${POSITIVE_PHRASES[@]}"
generate_kind negative "$NEGATIVE_COUNT" "${NEGATIVE_PHRASES[@]}"

echo "Generated $POSITIVE_COUNT synthetic wake samples and $NEGATIVE_COUNT synthetic non-wake samples."
echo "Next: run ./scripts/train_wakeword_from_samples.sh"
