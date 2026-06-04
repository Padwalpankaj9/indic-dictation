#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Indic Dictation"
TRAIN_ROOT="$APP_SUPPORT/WakeWordTraining"
DATA_DIR="$TRAIN_ROOT/data"
OUTPUT_DIR="$TRAIN_ROOT/output"
MODEL_NAME="hey_vaani"
MODEL_DIR="$OUTPUT_DIR/$MODEL_NAME"
WAKE_DIR="$APP_SUPPORT/WakeWord"
CONFIG_PATH="$TRAIN_ROOT/${MODEL_NAME}_recorded.yaml"
LIVEKIT_DIR="$ROOT/.build/checkouts/livekit-wakeword"
LIVEKIT_SPEC="livekit-wakeword[train,export] @ file://$LIVEKIT_DIR"
PYTHON_BIN="${PYTHON_BIN:-/usr/local/bin/python3.12}"

count_clips() {
  local split="$1"
  if [[ ! -d "$MODEL_DIR/$split" ]]; then
    echo 0
    return
  fi
  find "$MODEL_DIR/$split" -maxdepth 1 -type f -name 'clip_[0-9][0-9][0-9][0-9][0-9][0-9].wav' 2>/dev/null | wc -l | tr -d ' '
}

write_config() {
  mkdir -p "$TRAIN_ROOT" "$DATA_DIR" "$OUTPUT_DIR" "$WAKE_DIR"
  cat > "$CONFIG_PATH" <<YAML
model_name: $MODEL_NAME
target_phrases: ["hey vaani"]

data_dir: "$DATA_DIR"
output_dir: "$OUTPUT_DIR"

n_samples: 0
n_samples_val: 0
n_background_samples: 0
n_background_samples_val: 0

augmentation:
  clip_duration: 2.0
  batch_size: 8
  rounds: 3
  background_paths: []
  rir_paths: []

model:
  model_type: dnn
  model_size: tiny

steps: 1500
learning_rate: 0.001
weight_decay: 0.001
label_smoothing: 0.02
max_negative_weight: 800
target_fp_per_hour: 1.0

batch_n_per_class:
  positive: 8
  adversarial_negative: 8
  ACAV100M_sample: 0
  background_noise: 0
YAML
}

require_samples() {
  local pos_train pos_test neg_train neg_test
  pos_train="$(count_clips positive_train)"
  pos_test="$(count_clips positive_test)"
  neg_train="$(count_clips negative_train)"
  neg_test="$(count_clips negative_test)"

  echo "Wake samples:  $((pos_train + pos_test)) total ($pos_train train, $pos_test test)"
  echo "Other samples: $((neg_train + neg_test)) total ($neg_train train, $neg_test test)"

  if (( pos_train < 8 || pos_test < 2 || neg_train < 8 || neg_test < 2 )); then
    cat >&2 <<MSG

Not enough samples yet.

For a rough first model, record at least:
  - 10 wake samples by saying "Hey Vaani"
  - 10 other speech samples by saying anything except "Hey Vaani"

For a better model, collect 50+ of each.
MSG
    exit 1
  fi
}

if [[ ! -d "$LIVEKIT_DIR" ]]; then
  echo "LiveKit WakeWord checkout not found. Run 'swift build' first." >&2
  exit 1
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="$(command -v python3.12 || command -v python3)"
fi

write_config
require_samples

echo "Using Python: $PYTHON_BIN"
echo "Config: $CONFIG_PATH"

uv run \
  --no-project \
  --python "$PYTHON_BIN" \
  --with "$LIVEKIT_SPEC" \
  livekit-wakeword augment "$CONFIG_PATH"

uv run \
  --no-project \
  --python "$PYTHON_BIN" \
  --with "$LIVEKIT_SPEC" \
  livekit-wakeword train "$CONFIG_PATH"

uv run \
  --no-project \
  --python "$PYTHON_BIN" \
  --with "$LIVEKIT_SPEC" \
  livekit-wakeword export "$CONFIG_PATH"

cp "$MODEL_DIR/$MODEL_NAME.onnx" "$WAKE_DIR/$MODEL_NAME.onnx"
echo "Installed wake-word model: $WAKE_DIR/$MODEL_NAME.onnx"
