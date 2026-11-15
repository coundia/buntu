#!/usr/bin/env bash
# Unified release packager for Buntu. The version comes from Cargo.toml and the build number from the
# Android versionCode; scripts/check-version.sh refuses a tree where a platform disagrees.
#
# Usage:
#   scripts/prepare-releases.sh              Build all targets (--all)
#   scripts/prepare-releases.sh --all        Build Tizen, macOS and Android releases
#   scripts/prepare-releases.sh --tizen      Build Samsung Smart TV (.wgt) release
#   scripts/prepare-releases.sh --macos      Build macOS (.zip and .dmg) release
#   scripts/prepare-releases.sh --android    Build Android & Android TV (.apk) releases
#   scripts/prepare-releases.sh --skip-core  Skip rebuilding Rust core (macOS/Android)
#   scripts/prepare-releases.sh --dry-run    Print steps, commands and outputs without building
#   scripts/prepare-releases.sh -h|--help    Show this help
#
# Output directory: build/release/v<version>/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
read -r VERSION BUILD_NUMBER < <("${SCRIPT_DIR}/check-version.sh" --print)
RELEASE_REL_DIR="build/release/v${VERSION}"
RELEASE_DIR="${ROOT_DIR}/${RELEASE_REL_DIR}"

RUN_TIZEN=0
RUN_MACOS=0
RUN_ANDROID=0
EXPLICIT_TARGET=0
DRY_RUN=0
SKIP_CORE=0
STAGE_DIR=""

cleanup() {
  if [[ -n "${STAGE_DIR}" && -d "${STAGE_DIR}" ]]; then
    rm -rf "${STAGE_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "${arg}" in
    --all)
      RUN_TIZEN=1
      RUN_MACOS=1
      RUN_ANDROID=1
      EXPLICIT_TARGET=1
      ;;
    --tizen)
      RUN_TIZEN=1
      EXPLICIT_TARGET=1
      ;;
    --macos)
      RUN_MACOS=1
      EXPLICIT_TARGET=1
      ;;
    --android)
      RUN_ANDROID=1
      EXPLICIT_TARGET=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-core)
      SKIP_CORE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '${arg}' (see --help)" >&2
      exit 2
      ;;
  esac
done

if [[ "${EXPLICIT_TARGET}" -eq 0 ]]; then
  RUN_TIZEN=1
  RUN_MACOS=1
  RUN_ANDROID=1
fi

format_size() {
  local bytes="$1"
  awk -v b="${bytes}" 'BEGIN {
    if (b >= 1048576) printf "%.2f MB", b / 1048576;
    else if (b >= 1024) printf "%.1f KB", b / 1024;
    else printf "%d B", b;
  }'
}

selected_targets() {
  local targets=()
  [[ "${RUN_TIZEN}" -eq 1 ]] && targets+=("tizen")
  [[ "${RUN_MACOS}" -eq 1 ]] && targets+=("macos")
  [[ "${RUN_ANDROID}" -eq 1 ]] && targets+=("android")
  echo "${targets[*]}"
}

prepare_tizen() {
  echo "==> [Tizen] Building production .wgt package"
  local wgt_src="${ROOT_DIR}/build/tizen/cnd-iptv-tizen.wgt"
  local out_store="${RELEASE_DIR}/Buntu_${VERSION}_Tizen.wgt"
  local out_std="${RELEASE_DIR}/Buntu-${VERSION}-tizen.wgt"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "  [dry-run] ./scripts/build-tizen.sh --prod"
    echo "  [dry-run] cp build/tizen/cnd-iptv-tizen.wgt ${RELEASE_REL_DIR}/Buntu_${VERSION}_Tizen.wgt"
    echo "  [dry-run] cp build/tizen/cnd-iptv-tizen.wgt ${RELEASE_REL_DIR}/Buntu-${VERSION}-tizen.wgt"
    return 0
  fi

  "${SCRIPT_DIR}/build-tizen.sh" --prod
  [[ -f "${wgt_src}" ]] || { echo "error: expected Tizen package missing at ${wgt_src}" >&2; exit 1; }
  cp "${wgt_src}" "${out_store}"
  cp "${wgt_src}" "${out_std}"
}

prepare_macos() {
  echo "==> [macOS] Building release bundle (.zip + .dmg)"
  local macos_flags=(--release --build-only)
  if [[ "${SKIP_CORE}" -eq 0 ]]; then
    macos_flags+=(--rebuild-core)
  fi

  local zip_out="${RELEASE_DIR}/Buntu-${VERSION}-macOS.zip"
  local dmg_out="${RELEASE_DIR}/Buntu-${VERSION}-macOS.dmg"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "  [dry-run] ./scripts/run-macos.sh ${macos_flags[*]}"
    echo "  [dry-run] stage build/CndIPTV.app -> <staging>/Buntu.app"
    echo "  [dry-run] ditto -c -k --sequesterRsrc --keepParent <staging>/Buntu.app ${RELEASE_REL_DIR}/Buntu-${VERSION}-macOS.zip"
    echo "  [dry-run] hdiutil create -volname \"Buntu\" -srcfolder <staging> -ov -format UDZO ${RELEASE_REL_DIR}/Buntu-${VERSION}-macOS.dmg"
    return 0
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: macOS release packaging requires Darwin/macOS." >&2
    exit 1
  fi

  "${SCRIPT_DIR}/run-macos.sh" "${macos_flags[@]}"

  local src_app="${ROOT_DIR}/build/CndIPTV.app"
  [[ -d "${src_app}" ]] || { echo "error: expected macOS bundle missing at ${src_app}" >&2; exit 1; }

  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/buntu-macos-release.XXXXXX")"
  local dmg_root="${STAGE_DIR}/dmg"
  mkdir -p "${dmg_root}"

  ditto "${src_app}" "${dmg_root}/Buntu.app"
  ln -s /Applications "${dmg_root}/Applications"

  rm -f "${zip_out}" "${dmg_out}"
  ditto -c -k --sequesterRsrc --keepParent "${dmg_root}/Buntu.app" "${zip_out}"
  hdiutil create -volname "Buntu" -srcfolder "${dmg_root}" -ov -format UDZO "${dmg_out}" >/dev/null
}

prepare_android() {
  echo "==> [Android] Building release APKs (arm64-v8a, armeabi-v7a, x86_64, universal)"
  local abis=(arm64-v8a armeabi-v7a x86_64 universal)
  local apk_dir="${ROOT_DIR}/android/app/build/outputs/apk/release"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ "${SKIP_CORE}" -eq 0 ]]; then
      echo "  [dry-run] ./scripts/build-android.sh"
    else
      echo "  [dry-run] (skip-core) skipping ./scripts/build-android.sh"
    fi
    echo "  [dry-run] (cd android && ./gradlew assembleRelease)"
    for abi in "${abis[@]}"; do
      echo "  [dry-run] copy android/app/build/outputs/apk/release/app-${abi}-release.apk -> ${RELEASE_REL_DIR}/Buntu-${VERSION}-android-${abi}.apk"
    done
    return 0
  fi

  if [[ "${SKIP_CORE}" -eq 0 ]]; then
    "${SCRIPT_DIR}/build-android.sh"
  fi

  (cd "${ROOT_DIR}/android" && ./gradlew assembleRelease)

  for abi in "${abis[@]}"; do
    local candidate="${apk_dir}/app-${abi}-release.apk"
    if [[ ! -f "${candidate}" ]]; then
      candidate="${apk_dir}/app-${abi}-release-unsigned.apk"
    fi
    [[ -f "${candidate}" ]] || { echo "error: expected Android APK missing for ABI '${abi}' in ${apk_dir}" >&2; exit 1; }
    cp "${candidate}" "${RELEASE_DIR}/Buntu-${VERSION}-android-${abi}.apk"
  done
}

generate_checksums() {
  echo "==> [Checksums] Generating ${RELEASE_REL_DIR}/SHA256SUMS.txt"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    local planned=()
    if [[ "${RUN_TIZEN}" -eq 1 ]]; then
      planned+=(
        "Buntu_${VERSION}_Tizen.wgt"
        "Buntu-${VERSION}-tizen.wgt"
      )
    fi
    if [[ "${RUN_MACOS}" -eq 1 ]]; then
      planned+=(
        "Buntu-${VERSION}-macOS.zip"
        "Buntu-${VERSION}-macOS.dmg"
      )
    fi
    if [[ "${RUN_ANDROID}" -eq 1 ]]; then
      planned+=(
        "Buntu-${VERSION}-android-arm64-v8a.apk"
        "Buntu-${VERSION}-android-armeabi-v7a.apk"
        "Buntu-${VERSION}-android-x86_64.apk"
        "Buntu-${VERSION}-android-universal.apk"
      )
    fi
    echo "  [dry-run] (cd ${RELEASE_REL_DIR} && shasum -a 256 ${planned[*]} > SHA256SUMS.txt)"
    echo ""
    echo "Planned release artifacts (${RELEASE_REL_DIR}):"
    for item in "${planned[@]}"; do
      echo "  - ${RELEASE_REL_DIR}/${item}"
    done
    echo "  - ${RELEASE_REL_DIR}/SHA256SUMS.txt"
    return 0
  fi

  (
    cd "${RELEASE_DIR}"
    shopt -s nullglob
    local artifacts=( *.wgt *.zip *.dmg *.apk )
    if [[ "${#artifacts[@]}" -eq 0 ]]; then
      echo "error: no release artifacts found in ${RELEASE_DIR}" >&2
      exit 1
    fi

    local sorted=()
    while IFS= read -r line; do
      sorted+=("${line}")
    done < <(printf '%s\n' "${artifacts[@]}" | LC_ALL=C sort)

    shasum -a 256 "${sorted[@]}" > SHA256SUMS.txt

    echo ""
    printf '%-40s  %-10s  %s\n' "File" "Size" "SHA-256"
    printf '%-40s  %-10s  %s\n' "----------------------------------------" "----------" "----------------------------------------------------------------"
    for f in "${sorted[@]}"; do
      local bytes size_label digest
      bytes="$(wc -c < "${f}" | tr -d ' ')"
      size_label="$(format_size "${bytes}")"
      digest="$(shasum -a 256 "${f}" | awk '{print $1}')"
      printf '%-40s  %-10s  %s\n' "${f}" "${size_label}" "${digest}"
    done
    echo ""
    echo "Checksums written to: ${RELEASE_REL_DIR}/SHA256SUMS.txt"
  )
}

cd "${ROOT_DIR}"

echo "=============================================================================="
echo "  Buntu Release Packager — v${VERSION} (build ${BUILD_NUMBER})"
echo "  Targets : $(selected_targets)"
echo "  Output  : ${RELEASE_REL_DIR}/"
if [[ "${SKIP_CORE}" -eq 1 ]]; then
  echo "  Core    : skipped (--skip-core)"
fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "  Mode    : DRY RUN (no builds or files will be created)"
fi
echo "=============================================================================="

echo "==> [Pre-flight] Checking that every platform has version ${VERSION} (build ${BUILD_NUMBER})"
"${SCRIPT_DIR}/check-version.sh"

echo "==> [Pre-flight] Running secrets check"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "  [dry-run] ./scripts/check-secrets.sh"
else
  "${SCRIPT_DIR}/check-secrets.sh"
fi

if [[ "${DRY_RUN}" -eq 0 ]]; then
  mkdir -p "${RELEASE_DIR}"
else
  echo "  [dry-run] mkdir -p ${RELEASE_REL_DIR}"
fi

[[ "${RUN_TIZEN}" -eq 1 ]] && prepare_tizen
[[ "${RUN_MACOS}" -eq 1 ]] && prepare_macos
[[ "${RUN_ANDROID}" -eq 1 ]] && prepare_android

generate_checksums
