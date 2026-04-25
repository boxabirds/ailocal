#!/usr/bin/env bash
# vllm-swift install — uv-managed Python deps (replaces upstream install.sh's pip+venv)
set -euo pipefail
cd "$(dirname "$0")"
SRC="$PWD/src"
SWIFT_DIR="$SRC/swift"
BUILD_DIR="$SWIFT_DIR/.build/arm64-apple-macosx/release"

echo "=== 1. Swift build ==="
cd "$SWIFT_DIR"
swift build -c release 2>&1 | tail -3
[ -f "$BUILD_DIR/libVLLMBridge.dylib" ] || { echo "ERROR: dylib not built"; exit 1; }
echo "   $BUILD_DIR/libVLLMBridge.dylib"

echo
echo "=== 2. MLX metallib ==="
if [ ! -f "$BUILD_DIR/mlx.metallib" ]; then
    # Generate via mlx; install briefly to capture the file
    uv run --with mlx python3 -c "
import mlx.core as mx, os, shutil
mx.eval(mx.add(mx.array([1]), mx.array([2])))
src = os.path.join(os.path.dirname(mx.__file__), 'lib', 'mlx.metallib')
shutil.copy(src, '$BUILD_DIR/mlx.metallib')
print('  copied', src)
"
fi
ls -lh "$BUILD_DIR/mlx.metallib"

echo
echo "=== 3. uv venv + plugin + vllm ==="
cd "$PWD"
cd "$(dirname "$0")"
uv venv --python 3.13 .venv
source .venv/bin/activate
# Install plugin in editable mode
uv pip install -e "$SRC"
# vLLM needs the parentheses warning suppressed on Apple clang
CFLAGS="-Wno-parentheses" CXXFLAGS="-Wno-parentheses" uv pip install "vllm>=0.19.0"

echo
echo "=== 4. activate.sh ==="
cat > activate.sh <<EOF
# source me before running vllm-swift
source "$(pwd)/.venv/bin/activate"
export DYLD_LIBRARY_PATH="$BUILD_DIR:\${DYLD_LIBRARY_PATH:-}"
echo "vllm-swift active (venv + DYLD_LIBRARY_PATH)"
EOF
echo "wrote activate.sh"

echo
echo "=== 5. verify plugin ==="
.venv/bin/python3 -c "from vllm_swift import register; print('plugin OK')"

echo
echo "Done. Run:"
echo "  source pocs/02-vllm-swift/activate.sh"
echo "  vllm serve ~/models/Qwen3.6-27B-MLX-8bit --max-model-len 32768"
