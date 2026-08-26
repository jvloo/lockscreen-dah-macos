#!/bin/bash
# Local-only recognition A/B harness. It builds the CLI-capable executable but
# does not launch/install the app, download models, or write evaluation output.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: scripts/evaluate-model.sh DATASET.json [R50.mlmodelc]" >&2
  exit 2
fi

MANIFEST="$1"
MBF_MODEL="${MBF_MODEL_PATH:-Resources/FaceEmbedding.mlmodelc}"

echo "Model weights keep their own license; this harness does not grant redistribution or commercial-use rights." >&2
swift build -c release

ARGS=(
  --evaluate-model
  --manifest "$MANIFEST"
  --model "mbf=$MBF_MODEL"
)
if [ "$#" -eq 2 ]; then
  ARGS+=(--model "r50=$2")
fi

exec .build/release/LockscreenDah "${ARGS[@]}"
