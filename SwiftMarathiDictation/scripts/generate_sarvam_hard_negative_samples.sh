#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3.12 || command -v python3)}"

uv run \
  --no-project \
  --python "$PYTHON_BIN" \
  --with "sarvamai>=0.1.28" \
  "$ROOT/scripts/generate_sarvam_hard_negative_samples.py" "$@"
