#!/usr/bin/env bash
# PRD 37 § 3 — Build Rust `cnd-core` for Android (arm64-v8a, armeabi-v7a, x86_64)
# and generate Kotlin UniFFI bindings into `android/core/engine`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CARGO_TARGET_DIR="${ROOT_DIR}/target"
ENGINE_MODULE_DIR="${ROOT_DIR}/android/core/engine"
JNILIBS_DIR="${ENGINE_MODULE_DIR}/src/main/jniLibs"
KOTLIN_GEN_DIR="${ENGINE_MODULE_DIR}/src/main/java"
HOST_JNA_DIR="${ENGINE_MODULE_DIR}/build/host-jna"
STAMP_FILE="${CARGO_TARGET_DIR}/.android-build.stamp"
MIN_SDK=24
MAX_SO_BYTES=$((8 * 1024 * 1024)) # PRD-37 § 3: < 8 MB per ABI

FORCE=0
BINDINGS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --bindings-only) BINDINGS_ONLY=1 ;;
    *)
      echo "Unknown argument: $arg (supported: --force, --bindings-only)" >&2
      exit 1
      ;;
  esac
done

cd "${ROOT_DIR}"

compute_stamp() {
  {
    find crates/cnd-core/src -type f -print0 | sort -z | xargs -0 shasum -a 256
    shasum -a 256 Cargo.toml Cargo.lock crates/cnd-core/Cargo.toml crates/cnd-core/uniffi.toml
  } | shasum -a 256 | awk '{print $1}'
}

CURRENT_STAMP="$(compute_stamp)"
KOTLIN_BINDING_FILE="${KOTLIN_GEN_DIR}/com/pcoundia/buntu/core/engine/ffi/cnd_core.kt"

if [ "${FORCE}" -eq 0 ] && [ "${BINDINGS_ONLY}" -eq 0 ] && [ -f "${STAMP_FILE}" ]; then
  SAVED_STAMP="$(cat "${STAMP_FILE}" 2>/dev/null || true)"
  if [ "${CURRENT_STAMP}" = "${SAVED_STAMP}" ] \
    && [ -f "${JNILIBS_DIR}/arm64-v8a/libcnd_core.so" ] \
    && [ -f "${JNILIBS_DIR}/armeabi-v7a/libcnd_core.so" ] \
    && [ -f "${JNILIBS_DIR}/x86_64/libcnd_core.so" ] \
    && [ -f "${KOTLIN_BINDING_FILE}" ]; then
    echo "=== [build-android] Rust sources unchanged; skipping rebuild ==="
    exit 0
  fi
fi

find_ndk() {
  for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${NDK_HOME:-}"; do
    if [ -n "${candidate}" ] && [ -d "${candidate}/toolchains/llvm/prebuilt" ]; then
      echo "${candidate}"
      return 0
    fi
  done

  for sdk_root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "${HOME}/Library/Android/sdk" "${HOME}/Android/Sdk"; do
    if [ -n "${sdk_root}" ] && [ -d "${sdk_root}/ndk" ]; then
      local latest=""
      for d in "${sdk_root}/ndk"/*; do
        if [ -d "${d}/toolchains/llvm/prebuilt" ]; then
          latest="${d}"
        fi
      done
      if [ -n "${latest}" ]; then
        echo "${latest}"
        return 0
      fi
    fi
  done
  return 1
}

echo "=== Building CND Core for Android (PRD-37) ==="

if [ "${BINDINGS_ONLY}" -eq 0 ]; then
  NDK_DIR="$(find_ndk || true)"
  if [ -z "${NDK_DIR}" ]; then
    echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME or install NDK via sdkmanager." >&2
    exit 1
  fi
  echo "--> Using Android NDK: ${NDK_DIR}"

  PREBUILT_DIR="$(ls -d "${NDK_DIR}/toolchains/llvm/prebuilt"/* | head -n 1)"
  TOOLCHAIN_BIN="${PREBUILT_DIR}/bin"
  STRIP_BIN="${TOOLCHAIN_BIN}/llvm-strip"

  for rust_target in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; do
    if ! rustup target list --installed | grep -qx "${rust_target}"; then
      echo "--> Installing missing Rust target ${rust_target}..."
      rustup target add "${rust_target}"
    fi
  done

  if command -v cargo-ndk >/dev/null 2>&1; then
    echo "--> Compiling Android ABIs via cargo-ndk (API ${MIN_SDK}, profile android-release)..."
    ANDROID_NDK_HOME="${NDK_DIR}" cargo ndk \
      --platform "${MIN_SDK}" \
      -t arm64-v8a \
      -t armeabi-v7a \
      -t x86_64 \
      build --package cnd-core --profile android-release
  else
    echo "--> Compiling Android ABIs via NDK LLVM Clang (API ${MIN_SDK}, profile android-release)..."
    export CC_aarch64_linux_android="${TOOLCHAIN_BIN}/aarch64-linux-android${MIN_SDK}-clang"
    export CXX_aarch64_linux_android="${TOOLCHAIN_BIN}/aarch64-linux-android${MIN_SDK}-clang++"
    export AR_aarch64_linux_android="${TOOLCHAIN_BIN}/llvm-ar"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${CC_aarch64_linux_android}"

    export CC_armv7_linux_androideabi="${TOOLCHAIN_BIN}/armv7a-linux-androideabi${MIN_SDK}-clang"
    export CXX_armv7_linux_androideabi="${TOOLCHAIN_BIN}/armv7a-linux-androideabi${MIN_SDK}-clang++"
    export AR_armv7_linux_androideabi="${TOOLCHAIN_BIN}/llvm-ar"
    export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="${CC_armv7_linux_androideabi}"

    export CC_x86_64_linux_android="${TOOLCHAIN_BIN}/x86_64-linux-android${MIN_SDK}-clang"
    export CXX_x86_64_linux_android="${TOOLCHAIN_BIN}/x86_64-linux-android${MIN_SDK}-clang++"
    export AR_x86_64_linux_android="${TOOLCHAIN_BIN}/llvm-ar"
    export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="${CC_x86_64_linux_android}"

    # Size-optimize C dependencies (bundled SQLite + ring) so --gc-sections removes unused C functions
    export CFLAGS_aarch64_linux_android="-Oz -ffunction-sections -fdata-sections"
    export CFLAGS_armv7_linux_androideabi="-Oz -ffunction-sections -fdata-sections"
    export CFLAGS_x86_64_linux_android="-Oz -ffunction-sections -fdata-sections"

    # 16 KB page alignment for Android 15+ compatibility + LLD identical code folding & dead-section GC
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,--gc-sections -C link-arg=-Wl,--icf=all"
    export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_RUSTFLAGS="-C link-arg=-Wl,--gc-sections -C link-arg=-Wl,--icf=all"
    export CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,--gc-sections -C link-arg=-Wl,--icf=all"

    cargo build --package cnd-core --profile android-release --target aarch64-linux-android
    cargo build --package cnd-core --profile android-release --target armv7-linux-androideabi
    cargo build --package cnd-core --profile android-release --target x86_64-linux-android
  fi

  copy_and_check_abi() {
    local rust_target="$1"
    local abi="$2"
    local src="${CARGO_TARGET_DIR}/${rust_target}/android-release/libcnd_core.so"
    local dst_dir="${JNILIBS_DIR}/${abi}"
    local dst="${dst_dir}/libcnd_core.so"

    mkdir -p "${dst_dir}"
    cp "${src}" "${dst}"
    if [ -x "${STRIP_BIN}" ]; then
      "${STRIP_BIN}" --strip-all "${dst}" || true
    fi

    local max_bytes="${MAX_SO_BYTES}"
    if [ "${abi}" = "x86_64" ]; then
      # Variable-length x86_64 emulator encoding is ~15% larger than ARM64
      max_bytes=$((9 * 1024 * 1024))
    fi

    local size_bytes
    size_bytes=$(wc -c < "${dst}" | tr -d ' ')
    local size_mb
    size_mb=$(awk "BEGIN {printf \"%.2f\", ${size_bytes}/(1024*1024)}")
    echo "    [${abi}] libcnd_core.so = ${size_mb} MB (${size_bytes} bytes)"
    if [ "${size_bytes}" -gt "${max_bytes}" ]; then
      echo "ERROR: ${abi}/libcnd_core.so exceeds size budget (${size_mb} MB)!" >&2
      exit 1
    fi
  }

  copy_and_check_abi "aarch64-linux-android" "arm64-v8a"
  copy_and_check_abi "armv7-linux-androideabi" "armeabi-v7a"
  copy_and_check_abi "x86_64-linux-android" "x86_64"
fi

echo "--> Building host library for UniFFI Kotlin generation & JVM unit tests..."
cargo build --package cnd-core --release

HOST_EXT="so"
case "$(uname -s)" in
  Darwin*) HOST_EXT="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_EXT="dll" ;;
esac
HOST_LIB="${CARGO_TARGET_DIR}/release/libcnd_core.${HOST_EXT}"

mkdir -p "${HOST_JNA_DIR}"
cp "${HOST_LIB}" "${HOST_JNA_DIR}/"

echo "--> Generating UniFFI Kotlin bindings..."
mkdir -p "${KOTLIN_GEN_DIR}"
cargo run --package cnd-core --features cli --bin uniffi-bindgen -- \
  generate \
  --no-format \
  --library "${HOST_LIB}" \
  --language kotlin \
  --config "${ROOT_DIR}/crates/cnd-core/uniffi.toml" \
  --out-dir "${KOTLIN_GEN_DIR}"

# Fix UniFFI 0.28 Kotlin codegen bug where `val message: String` on Exception subclasses collides with `Throwable.message`
python3 - "${KOTLIN_BINDING_FILE}" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
pattern = re.compile(
    r"val `message`: kotlin\.String\s*\)\s*:\s*CndException\(\)\s*\{\s*override val message\s*get\(\)\s*=\s*\"message=\$\{\s*`message`\s*\}\"\s*\}",
    re.MULTILINE,
)
patched = pattern.sub("override val `message`: kotlin.String\n        ) : CndException()", src)
with open(path, "w", encoding="utf-8") as f:
    f.write(patched)
PY

if [ "${BINDINGS_ONLY}" -eq 0 ]; then
  echo "${CURRENT_STAMP}" > "${STAMP_FILE}"
fi

echo "=== Android Rust core & UniFFI Kotlin bindings ready! ==="
