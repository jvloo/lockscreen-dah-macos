#!/bin/bash
# One-time setup: download InsightFace MobileFaceNet (w600k_mbf, ~13 MB ONNX),
# convert it to a Core ML mlprogram, and compile to Resources/FaceEmbedding.mlmodelc.
#
# The converted model takes a 112x112 RGB face crop and returns a 512-d identity
# embedding. Conversion runs in a throwaway venv; nothing Python is needed at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Resources/FaceEmbedding.mlmodelc"
WORK="${MODEL_WORK_DIR:-.model-work}"

if [ -d "$OUT" ]; then
  echo "$OUT already exists — delete it to reconvert."
  exit 0
fi

mkdir -p "$WORK" Resources

# 1. Download ONNX (inside InsightFace's buffalo_sc pack)
# Pinned SHA-256 of the release asset — a swapped or MITM'd download (which
# would otherwise be converted and shipped as the recognition model) fails here.
BUFFALO_SC_SHA256="57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"
ONNX="$WORK/w600k_mbf.onnx"
if [ ! -f "$ONNX" ]; then
  echo "Downloading buffalo_sc.zip (InsightFace)..."
  curl -fsSL -o "$WORK/buffalo_sc.zip" \
    "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip"
  ACTUAL="$(shasum -a 256 "$WORK/buffalo_sc.zip" | cut -d' ' -f1)"
  [ "$ACTUAL" = "$BUFFALO_SC_SHA256" ] || {
    echo "checksum mismatch for buffalo_sc.zip:" >&2
    echo "  expected $BUFFALO_SC_SHA256" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
  }
  unzip -o -q "$WORK/buffalo_sc.zip" -d "$WORK/buffalo_sc"
  FOUND="$(find "$WORK" -name 'w600k_mbf.onnx' | head -1)"
  [ -n "$FOUND" ] || { echo "w600k_mbf.onnx not found in archive"; exit 1; }
  [ "$FOUND" != "$ONNX" ] && cp "$FOUND" "$ONNX"
fi

# 2. Convert ONNX -> TorchScript -> Core ML mlprogram
PY="$(command -v python3.12 || command -v python3.11 || command -v python3.10 || command -v python3)"
echo "Using $("$PY" --version 2>&1) at $PY"
if [ ! -d "$WORK/venv" ]; then
  "$PY" -m venv "$WORK/venv"
fi
# shellcheck disable=SC1091
source "$WORK/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet torch onnx onnx2torch coremltools numpy

python - <<'PYEOF'
import onnx, torch, numpy as np
import coremltools as ct
from onnx2torch import convert

onnx_model = onnx.load(".model-work/w600k_mbf.onnx")
torch_model = convert(onnx_model)
torch_model.eval()

example = torch.randn(1, 3, 112, 112)
traced = torch.jit.trace(torch_model, example)

# InsightFace ArcFace preprocessing: RGB, (x - 127.5) / 127.5
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name="input",
        shape=(1, 3, 112, 112),
        scale=1 / 127.5,
        bias=[-1.0, -1.0, -1.0],
        color_layout=ct.colorlayout.RGB,
    )],
    convert_to="mlprogram",
    compute_units=ct.ComputeUnit.ALL,
    minimum_deployment_target=ct.target.macOS13,
)

# Sanity check: same input through torch and coreml should agree
from PIL import Image
rng = np.random.default_rng(0)
img = rng.integers(0, 255, (112, 112, 3), dtype=np.uint8)
with torch.no_grad():
    t_in = (torch.from_numpy(img).float().permute(2, 0, 1).unsqueeze(0) - 127.5) / 127.5
    t_out = traced(t_in).numpy().ravel()
c_out = list(mlmodel.predict({"input": Image.fromarray(img)}).values())[0].ravel()
cos = float(np.dot(t_out, c_out) / (np.linalg.norm(t_out) * np.linalg.norm(c_out)))
print(f"torch-vs-coreml cosine agreement: {cos:.5f}")
assert cos > 0.999, "conversion mismatch"

mlmodel.save(".model-work/FaceEmbedding.mlpackage")
print("saved .model-work/FaceEmbedding.mlpackage")
PYEOF

# 3. Compile to .mlmodelc for bundling
xcrun coremlcompiler compile "$WORK/FaceEmbedding.mlpackage" Resources/
[ -d "$OUT" ] || { echo "coremlcompiler did not produce $OUT"; exit 1; }
echo "Done: $OUT"
