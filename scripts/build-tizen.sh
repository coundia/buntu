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

# Automatically pick up Tizen Studio CLI & sdb if installed in the default location
if [ -d "$HOME/tizen-studio/tools" ]; then
    export PATH="$PATH:$HOME/tizen-studio/tools:$HOME/tizen-studio/tools/ide/bin"
fi

echo "=== [1/5] Checking Toolchain for Tizen ==="
for cmd in node npm wasm-pack wasm-opt zip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Missing required command '$cmd'."
        echo "Please install via Homebrew: brew install node binaryen wasm-pack"
        exit 1
    fi
done

echo "=== [2/5] Compiling cnd-domain-wasm to WebAssembly 1.0 MVP (Tizen 3.0+ / Chromium 56+) ==="
cd "$ROOT_DIR"
# Rust 1.82+ defaults wasm32-unknown-unknown to `generic` (+multivalue, +reference-types, +bulk-memory, +sign-ext),
# and prebuilt libstd carries a `target_features` section that causes wasm-bindgen to emit multi-value returns
# (`CompileError: return count of 4 exceeds internal limit` on Tizen Chromium < 85) and `externref` (< 96).
# Force `target-cpu=mvp`, clear linker target_features before wasm-bindgen runs, then lower libcore's
# bulk-memory/sign-ext/trunc_sat instructions to strict WebAssembly 1.0 MVP with Binaryen.
RUSTFLAGS="-C target-cpu=mvp -C link-arg=--no-check-features -C link-arg=--features=" \
    wasm-pack build "$WASM_CRATE_DIR" --target web --release --no-opt --out-dir "$TIZEN_DIR/src/wasm/pkg"

WASM_FILE="$TIZEN_DIR/src/wasm/pkg/cnd_domain_wasm_bg.wasm"
if [ -f "$WASM_FILE" ]; then
    echo "Running wasm-opt MVP lowering + -Oz..."
    wasm-opt \
        --enable-bulk-memory \
        --enable-bulk-memory-opt \
        --enable-sign-ext \
        --enable-nontrapping-float-to-int \
        --enable-mutable-globals \
        -Oz \
        --signext-lowering \
        --llvm-memory-copy-fill-lowering \
        --llvm-nontrapping-fptoint-lowering \
        "$WASM_FILE" -o "$WASM_FILE"
    echo "Verifying strict WebAssembly 1.0 MVP compliance..."
    wasm-opt --mvp-features "$WASM_FILE" -o /dev/null
    echo "Wasm binary size (100% MVP verified): $(du -h "$WASM_FILE" | cut -f1)"
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
    # Signs with the ACTIVE certificate profile (Certificate Manager), or TIZEN_PROFILE=<name>.
    # A previous run's signature files and manifest would end up inside the new package.
    rm -f "$WGT_ROOT"/author-signature.xml "$WGT_ROOT"/signature*.xml "$WGT_ROOT"/.manifest.tmp
    PROFILE_ARGS=()
    if [ -n "${TIZEN_PROFILE:-}" ]; then PROFILE_ARGS=(-s "$TIZEN_PROFILE"); fi
    tizen package -t wgt "${PROFILE_ARGS[@]}" -o "$OUT_DIR" -- "$WGT_ROOT"
    SIGNED="$(ls -t "$OUT_DIR"/*.wgt | grep -v cnd-iptv-tizen.wgt | head -1)"
    if [ -n "$SIGNED" ]; then mv "$SIGNED" "$WGT_PATH"; fi
else
    echo "WARNING: the Tizen Studio CLI is not in PATH: this .wgt is NOT signed and a TV will refuse it"
    echo "         (install error 'Check certificate error'). Run:"
    echo "         export PATH=\"\$PATH:\$HOME/tizen-studio/tools:\$HOME/tizen-studio/tools/ide/bin\" and build again."
    echo "Creating a plain .wgt zip archive (for inspection only)..."
    zip -r -q "$WGT_PATH" ./*
fi

echo "=============================================================================="
echo " SUCCESS: Tizen package generated successfully!"
echo " Package path: $WGT_PATH"
echo " Package size: $(du -h "$WGT_PATH" | cut -f1)"
echo " SHA256: $(shasum -a 256 "$WGT_PATH" | cut -d' ' -f1)"
echo " To install on TV: ./scripts/install-tizen.sh <TV_IP>"
echo "=============================================================================="

