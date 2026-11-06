#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CND IPTV - Samsung Smart TV (Tizen) Build & Packaging (PRD 38 § 8)
#
# Produces:
#   1. crates/cnd-domain-wasm compiled to wasm32-unknown-unknown with wasm-opt -Oz
#   2. tizen/dist web bundle (Vite + SolidJS + Chromium 56 polyfills)
#   3. build/tizen/cnd-iptv-tizen.wgt signed/packaged for Samsung Smart TVs
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIZEN_DIR="$ROOT_DIR/tizen"
WASM_CRATE_DIR="$ROOT_DIR/crates/cnd-domain-wasm"
OUT_DIR="$ROOT_DIR/build/tizen"
WGT_ROOT="$OUT_DIR/wgt_root"

echo "=== [1/5] Checking Toolchain for Tizen ==="
for cmd in node npm wasm-pack wasm-opt zip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Missing required command '$cmd'."
        echo "Please install via Homebrew: brew install node binaryen wasm-pack"
        exit 1
    fi
done

echo "=== [2/5] Compiling cnd-domain-wasm to WebAssembly ==="
cd "$ROOT_DIR"
wasm-pack build "$WASM_CRATE_DIR" --target web --release --out-dir "$TIZEN_DIR/src/wasm/pkg"

# Additional binaryen optimization
WASM_FILE="$TIZEN_DIR/src/wasm/pkg/cnd_domain_wasm_bg.wasm"
if [ -f "$WASM_FILE" ]; then
    echo "Running wasm-opt -Oz..."
    wasm-opt -Oz "$WASM_FILE" -o "$WASM_FILE"
    echo "Wasm binary size: $(du -h "$WASM_FILE" | cut -f1)"
fi

echo "=== [3/5] Building Tizen Web App (Vite + Chromium 56 Legacy) ==="
cd "$TIZEN_DIR"
if [ ! -d "node_modules" ]; then
    npm install
fi
npm run build

echo "=== [4/5] Preparing Tizen Package Directory ==="
rm -rf "$OUT_DIR"
mkdir -p "$WGT_ROOT"

# Copy built web assets
cp -R "$TIZEN_DIR/dist/"* "$WGT_ROOT/"
cp "$TIZEN_DIR/config.xml" "$WGT_ROOT/config.xml"
cp "$TIZEN_DIR/icon.png" "$WGT_ROOT/icon.png"

echo "=== [5/5] Creating .wgt Package ==="
WGT_PATH="$OUT_DIR/cnd-iptv-tizen.wgt"
cd "$WGT_ROOT"

if command -v tizen >/dev/null 2>&1; then
    echo "Tizen Studio CLI found: packaging and signing..."
    tizen package -t wgt -s default -- "$WGT_ROOT"
    mv "$WGT_ROOT"/*.wgt "$WGT_PATH" 2>/dev/null || true
else
    echo "Tizen Studio CLI not in PATH: creating standard .wgt zip archive..."
    zip -r -q "$WGT_PATH" ./*
fi

echo "=============================================================================="
echo " SUCCESS: Tizen package generated successfully!"
echo " Package path: $WGT_PATH"
echo " Package size: $(du -h "$WGT_PATH" | cut -f1)"
echo " SHA256: $(shasum -a 256 "$WGT_PATH" | cut -d' ' -f1)"
echo " To install on TV: sdb connect <TV_IP> && sdb install $WGT_PATH"
echo "=============================================================================="
