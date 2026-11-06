#!/usr/bin/env bash
# Builds the Android app (Phone, Tablet & Android TV), installs the matching ABI APK on a
# connected Android device or emulator via adb, and launches Buntu.
#
#   scripts/run-android.sh                        first connected device, debug build, launch
#   scripts/run-android.sh --release              optimized R8 release build
#   scripts/run-android.sh --device "Pixel_8"     pick a device by adb serial or model name
#   scripts/run-android.sh --tv                   force Leanback 10-foot TV launcher intent
#   scripts/run-android.sh --rebuild-core         force rebuild of Rust .so + UniFFI bindings
#   scripts/run-android.sh --no-launch            build and install only
#   scripts/run-android.sh --logs                 stream Buntu logcat after launching
#   scripts/run-android.sh --list                 list connected Android devices / TVs / emulators
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANDROID_DIR="${ROOT_DIR}/android"

VARIANT="Debug"
VARIANT_LOWER="debug"
APP_ID="com.pcoundia.buntu.debug"
DEVICE=""
FORCE_TV=0
REBUILD_CORE=0
LAUNCH=1
FOLLOW_LOGS=0
LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      VARIANT="Release"
      VARIANT_LOWER="release"
      APP_ID="com.pcoundia.buntu"
      ;;
    --device)
      DEVICE="${2:?--device needs a serial or model name}"
      shift
      ;;
    --tv) FORCE_TV=1 ;;
    --rebuild-core) REBUILD_CORE=1 ;;
    --no-launch) LAUNCH=0 ;;
    --logs) FOLLOW_LOGS=1 ;;
    --list) LIST=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
  shift
done

find_adb() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi
  for sdk in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "${HOME}/Library/Android/sdk" "${HOME}/Android/Sdk"; do
    if [[ -n "${sdk}" && -x "${sdk}/platform-tools/adb" ]]; then
      echo "${sdk}/platform-tools/adb"
      return 0
    fi
  done
  return 1
}

ADB_BIN="$(find_adb || true)"
if [[ -z "${ADB_BIN}" ]]; then
  echo "error: 'adb' not found. Install Android SDK Platform-Tools or set ANDROID_SDK_ROOT." >&2
  exit 1
fi

# Prints connected online devices as: serial<TAB>model<TAB>abi<TAB>sdk<TAB>kind
connected_devices() {
  local serials
  serials="$("${ADB_BIN}" devices | awk 'NR>1 && $2 == "device" {print $1}')"
  [[ -z "${serials}" ]] && return 0

  while IFS= read -r serial; do
    [[ -z "${serial}" ]] && continue
    local model abi sdk is_tv kind
    model="$("${ADB_BIN}" -s "${serial}" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r' | xargs || echo "Android")"
    abi="$("${ADB_BIN}" -s "${serial}" shell getprop ro.product.cpu.abi </dev/null 2>/dev/null | tr -d '\r' | xargs || echo "arm64-v8a")"
    sdk="$("${ADB_BIN}" -s "${serial}" shell getprop ro.build.version.sdk </dev/null 2>/dev/null | tr -d '\r' | xargs || echo "?")"
    is_tv="$("${ADB_BIN}" -s "${serial}" shell pm list features </dev/null 2>/dev/null | grep -c "android.software.leanback" || true)"
    if [[ "${is_tv}" -gt 0 ]]; then
      kind="TV"
    else
      kind="Mobile"
    fi
    printf '%s\t%s\t%s\tAPI %s\t%s\n' "${serial}" "${model}" "${abi}" "${sdk}" "${kind}"
  done <<< "${serials}"
}

DEVICES="$(connected_devices)"
if [[ "${LIST}" -eq 1 ]]; then
  if [[ -z "${DEVICES}" ]]; then
    echo "No connected Android device. Enable USB/Wireless debugging or start an emulator."
  else
    echo "${DEVICES}" | awk -F'\t' '{printf "%-24s  %-22s  %-12s  %-8s  [%s]\n", $1, $2, $3, $4, $5}'
  fi
  exit 0
fi

if [[ -z "${DEVICES}" ]]; then
  echo "error: no connected Android device found via adb." >&2
  echo "  - Phone/Tablet: enable Developer Options -> USB debugging (or Wireless debugging + 'adb connect IP:PORT')." >&2
  echo "  - Android TV:   Settings -> System -> About -> click Build 7x -> Network debugging -> 'adb connect TV_IP:5555'." >&2
  exit 1
fi

if [[ -n "${DEVICE}" ]]; then
  TARGET_LINE="$(echo "${DEVICES}" | awk -F'\t' -v d="${DEVICE}" '
    tolower($1) == tolower(d) || tolower($2) == tolower(d) || index(tolower($1), tolower(d)) > 0 || index(tolower($2), tolower(d)) > 0 {print $0; exit}
  ')"
  if [[ -z "${TARGET_LINE}" ]]; then
    echo "error: Android device '${DEVICE}' is not connected. Available devices:" >&2
    echo "${DEVICES}" | awk -F'\t' '{printf "  %s (%s, %s, %s)\n", $2, $1, $3, $5}' >&2
    exit 1
  fi
else
  TARGET_LINE="$(echo "${DEVICES}" | head -n 1)"
fi

SERIAL="$(echo "${TARGET_LINE}" | cut -f1)"
MODEL="$(echo "${TARGET_LINE}" | cut -f2)"
DEVICE_ABI="$(echo "${TARGET_LINE}" | cut -f3)"
DEVICE_SDK="$(echo "${TARGET_LINE}" | cut -f4)"
DEVICE_KIND="$(echo "${TARGET_LINE}" | cut -f5)"

echo "==> Android target: ${MODEL} (${SERIAL}, ${DEVICE_ABI}, ${DEVICE_SDK}, ${DEVICE_KIND})"

if [[ "${REBUILD_CORE}" -eq 1 ]]; then
  echo "==> Rebuilding Rust core for Android (--force)"
  "${ROOT_DIR}/scripts/build-android.sh" --force
else
  "${ROOT_DIR}/scripts/build-android.sh"
fi

echo "==> Building Android APK (assemble${VARIANT})"
(cd "${ANDROID_DIR}" && ./gradlew ":app:assemble${VARIANT}")

APK_DIR="${ANDROID_DIR}/app/build/outputs/apk/${VARIANT_LOWER}"
APK_PATH="${APK_DIR}/app-${DEVICE_ABI}-${VARIANT_LOWER}.apk"
if [[ ! -f "${APK_PATH}" ]]; then
  APK_PATH="${APK_DIR}/app-universal-${VARIANT_LOWER}.apk"
fi
if [[ ! -f "${APK_PATH}" ]]; then
  APK_PATH="$(find "${APK_DIR}" -maxdepth 1 -name "*.apk" | head -n 1 || true)"
fi
if [[ -z "${APK_PATH}" || ! -f "${APK_PATH}" ]]; then
  echo "error: no APK found in ${APK_DIR}" >&2
  exit 1
fi

echo "==> Installing $(basename "${APK_PATH}") (${APP_ID}) onto ${MODEL}"
"${ADB_BIN}" -s "${SERIAL}" install -r "${APK_PATH}"

if [[ "${LAUNCH}" -eq 1 ]]; then
  CATEGORY="android.intent.category.LAUNCHER"
  if [[ "${FORCE_TV}" -eq 1 || "${DEVICE_KIND}" == "TV" ]]; then
    CATEGORY="android.intent.category.LEANBACK_LAUNCHER"
  fi
  echo "==> Launching ${APP_ID}/com.pcoundia.buntu.MainActivity (${CATEGORY##*.})"
  "${ADB_BIN}" -s "${SERIAL}" shell am start \
    -W \
    -a android.intent.action.MAIN \
    -c "${CATEGORY}" \
    -n "${APP_ID}/com.pcoundia.buntu.MainActivity" >/dev/null
fi

if [[ "${FOLLOW_LOGS}" -eq 1 ]]; then
  echo "==> Streaming Buntu logs (Ctrl+C to stop)"
  "${ADB_BIN}" -s "${SERIAL}" logcat -v time | grep -E --line-buffered "Buntu\.|CndCore|AndroidRuntime|${APP_ID}"
fi

echo "==> Done"

