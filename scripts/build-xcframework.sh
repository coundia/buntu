#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CARGO_TARGET_DIR="${ROOT_DIR}/target"
BRIDGE_DIR="${ROOT_DIR}/apple/Packages/CndCoreBridge"

echo "=== Building CND Core Native Universal XCFramework ==="
echo "Root Dir: ${ROOT_DIR}"
echo "Bridge Dir: ${BRIDGE_DIR}"

cd "${ROOT_DIR}"

# 1. Targets definition
TARGET_MAC_ARM="aarch64-apple-darwin"
TARGET_MAC_X86="x86_64-apple-darwin"

TARGET_IOS_SIM_ARM="aarch64-apple-ios-sim"
TARGET_IOS_SIM_X86="x86_64-apple-ios"

TARGET_IOS="aarch64-apple-ios"

TARGET_TVOS_SIM="aarch64-apple-tvos-sim"
TARGET_TVOS="aarch64-apple-tvos"

echo "--> Compiling Rust for macOS (arm64 & x86_64)..."
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --package cnd-core --release --target "${TARGET_MAC_ARM}"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --package cnd-core --release --target "${TARGET_MAC_X86}"

echo "--> Compiling Rust for iOS Simulator (arm64 & x86_64)..."
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --package cnd-core --release --target "${TARGET_IOS_SIM_ARM}"
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --package cnd-core --release --target "${TARGET_IOS_SIM_X86}"

echo "--> Compiling Rust for iOS Device (arm64)..."
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --package cnd-core --release --target "${TARGET_IOS}"

echo "--> Compiling Rust for tvOS Simulator (arm64)..."
TVOS_DEPLOYMENT_TARGET=17.0 cargo build --package cnd-core --release --target "${TARGET_TVOS_SIM}"

echo "--> Compiling Rust for tvOS Device (arm64)..."
TVOS_DEPLOYMENT_TARGET=17.0 cargo build --package cnd-core --release --target "${TARGET_TVOS}"

# 2. Universal Fat Binaries with lipo
UNIVERSAL_DIR="${CARGO_TARGET_DIR}/universal"
mkdir -p "${UNIVERSAL_DIR}/macos"
mkdir -p "${UNIVERSAL_DIR}/ios-sim"

echo "--> Creating Universal macOS static library..."
lipo -create \
    "${CARGO_TARGET_DIR}/${TARGET_MAC_ARM}/release/libcnd_core.a" \
    "${CARGO_TARGET_DIR}/${TARGET_MAC_X86}/release/libcnd_core.a" \
    -output "${UNIVERSAL_DIR}/macos/libcnd_core.a"

echo "--> Creating Universal iOS Simulator static library..."
lipo -create \
    "${CARGO_TARGET_DIR}/${TARGET_IOS_SIM_ARM}/release/libcnd_core.a" \
    "${CARGO_TARGET_DIR}/${TARGET_IOS_SIM_X86}/release/libcnd_core.a" \
    -output "${UNIVERSAL_DIR}/ios-sim/libcnd_core.a"

# 3. Generate UniFFI Bindings
echo "--> Generating UniFFI Swift Bindings & C Headers..."
BINDINGS_DIR="${CARGO_TARGET_DIR}/uniffi_generated"
rm -rf "${BINDINGS_DIR}"
mkdir -p "${BINDINGS_DIR}"

cargo run --package cnd-core --features cli --bin uniffi-bindgen -- \
    generate \
    --library "${CARGO_TARGET_DIR}/${TARGET_MAC_ARM}/release/libcnd_core.dylib" \
    --language swift \
    --out-dir "${BINDINGS_DIR}"

# Prepare Headers folder for xcframework
HEADERS_DIR="${CARGO_TARGET_DIR}/xcframework_headers"
rm -rf "${HEADERS_DIR}"
mkdir -p "${HEADERS_DIR}"
cp "${BINDINGS_DIR}/cnd_coreFFI.h" "${HEADERS_DIR}/"
cp "${BINDINGS_DIR}/cnd_coreFFI.modulemap" "${HEADERS_DIR}/module.modulemap"

# 4. Create Universal XCFramework
XCFRAMEWORK_OUT="${BRIDGE_DIR}/cnd_coreFFI.xcframework"
rm -rf "${XCFRAMEWORK_OUT}"

echo "--> Packaging XCFramework with xcodebuild..."
xcodebuild -create-xcframework \
    -library "${UNIVERSAL_DIR}/macos/libcnd_core.a" \
    -headers "${HEADERS_DIR}" \
    -library "${UNIVERSAL_DIR}/ios-sim/libcnd_core.a" \
    -headers "${HEADERS_DIR}" \
    -library "${CARGO_TARGET_DIR}/${TARGET_IOS}/release/libcnd_core.a" \
    -headers "${HEADERS_DIR}" \
    -library "${CARGO_TARGET_DIR}/${TARGET_TVOS_SIM}/release/libcnd_core.a" \
    -headers "${HEADERS_DIR}" \
    -library "${CARGO_TARGET_DIR}/${TARGET_TVOS}/release/libcnd_core.a" \
    -headers "${HEADERS_DIR}" \
    -output "${XCFRAMEWORK_OUT}"

# 5. Copy Swift interface into Swift Package
SWIFT_SOURCES_DIR="${BRIDGE_DIR}/Sources/CndCoreBridge"
mkdir -p "${SWIFT_SOURCES_DIR}"
cp "${BINDINGS_DIR}/cnd_core.swift" "${SWIFT_SOURCES_DIR}/CndCore.swift"

echo "=== CndCoreBridge Universal XCFramework build completed successfully! ==="
