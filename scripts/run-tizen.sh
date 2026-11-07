#!/usr/bin/env bash
# Builds, signs, installs and launches Buntu (CND IPTV) on a Samsung Tizen Smart TV.
#
#   scripts/run-tizen.sh                        build, install & launch on the connected sdb TV
#   scripts/run-tizen.sh 192.168.x.x            connect to TV IP, build, install & launch
#   scripts/run-tizen.sh --ip 192.168.x.x       same with explicit flag
#   scripts/run-tizen.sh --no-build             install existing build/tizen/cnd-iptv-tizen.wgt without rebuilding
#   scripts/run-tizen.sh --no-launch            build and install only
#   scripts/run-tizen.sh --debug                enable Web Inspector (port 9222) after launching
#   scripts/run-tizen.sh --list                 list connected Samsung TVs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WGT_PATH="${ROOT_DIR}/build/tizen/cnd-iptv-tizen.wgt"
APP_ID="cnd001iptv.CndIptv"

if [[ -d "${HOME}/tizen-studio/tools" ]]; then
  export PATH="${PATH}:${HOME}/tizen-studio/tools:${HOME}/tizen-studio/tools/ide/bin"
fi

TV_IP="${TV_IP:-}"
DO_BUILD=1
DO_LAUNCH=1
DO_DEBUG=0
DO_LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip|--device|-d)
      TV_IP="${2:?--ip requires a TV IP address}"
      shift
      ;;
    --no-build) DO_BUILD=0 ;;
    --no-launch) DO_LAUNCH=0 ;;
    --debug) DO_DEBUG=1 ;;
    --list) DO_LIST=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1 (try --help)" >&2
      exit 2
      ;;
    *)
      TV_IP="$1"
      ;;
  esac
  shift
done

# Normalize accidental comma in IP address (e.g. 192.168.1,x -> 192.168.1.x)
TV_IP="${TV_IP//,/.}"

if ! command -v sdb >/dev/null 2>&1; then
  echo "error: 'sdb' not found. Install Tizen Studio in ~/tizen-studio or add sdb to PATH." >&2
  exit 1
fi

if [[ "${DO_LIST}" -eq 1 ]]; then
  sdb devices
  exit 0
fi

# 1. Connect to the Samsung TV
if [[ -n "${TV_IP}" ]]; then
  echo "==> Connecting to Samsung TV at ${TV_IP}..."
  sdb connect "${TV_IP}" || true
fi

DEVICE_LINE="$(sdb devices | awk 'NR>1 && $2 == "device" {print $1 "\t" $3; exit}')"
if [[ -z "${DEVICE_LINE}" ]]; then
  echo "error: No Samsung TV connected via sdb. Check Developer Mode on TV and run: $0 <TV_IP>" >&2
  sdb devices
  exit 1
fi

SERIAL="$(printf '%s' "${DEVICE_LINE}" | cut -f1)"
TARGET_NAME="$(printf '%s' "${DEVICE_LINE}" | cut -f2)"
echo "==> Target Samsung TV: ${TARGET_NAME} (${SERIAL})"

# 2. Build & sign .wgt package
if [[ "${DO_BUILD}" -eq 1 || ! -f "${WGT_PATH}" ]]; then
  "${SCRIPT_DIR}/build-tizen.sh"
fi

# 3. Stop any previous running instance on the TV so the new package is loaded cleanly
echo "==> Stopping any running instance of ${APP_ID}..."
sdb -s "${SERIAL}" shell 0 was_kill "${APP_ID}" >/dev/null 2>&1 || true

# 4. Install .wgt onto the TV (Samsung tv-samsung profile requires `tizen install`, as `sdb install` only pushes the file)
echo "==> Installing ${WGT_PATH} onto ${TARGET_NAME}..."
WGT_DIR="$(dirname "${WGT_PATH}")"
WGT_NAME="$(basename "${WGT_PATH}")"
tizen install -n "${WGT_NAME}" -t "${TARGET_NAME}" -- "${WGT_DIR}"

# 5. Launch app on the TV
if [[ "${DO_LAUNCH}" -eq 1 ]]; then
  echo "==> Launching ${APP_ID} on ${TARGET_NAME}..."
  sleep 1
  if command -v tizen >/dev/null 2>&1; then
    tizen run -p "${APP_ID}" -t "${TARGET_NAME}" || sdb -s "${SERIAL}" shell 0 was_execute "${APP_ID}"
  else
    sdb -s "${SERIAL}" shell 0 was_execute "${APP_ID}"
  fi
fi

# 6. Optional Chrome DevTools remote inspector port forwarding
if [[ "${DO_DEBUG}" -eq 1 ]]; then
  echo "==> Enabling Web Inspector on tcp:9222..."
  sdb -s "${SERIAL}" dpm --on || true
  sdb -s "${SERIAL}" forward tcp:9222 tcp:9222 || true
  echo "==> Open chrome://inspect or http://localhost:9222 in Chrome."
fi

echo "==> Done."

