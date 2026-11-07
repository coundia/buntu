#!/usr/bin/env bash
# Builds, signs, installs and launches Buntu (CND IPTV) on a Samsung Tizen Smart TV.
#
#   scripts/run-tizen.sh [IP]             build, install & launch (IP is remembered in ~/.cache/cnd-iptv)
#   scripts/run-tizen.sh --ip IP          same with explicit flag (or TV_IP=IP env var)
#   scripts/run-tizen.sh --no-build       install the existing build/tizen/cnd-iptv-tizen.wgt
#   scripts/run-tizen.sh --no-launch      build and install only
#   scripts/run-tizen.sh --launch-only    just (re)launch the installed app, no build or install
#   scripts/run-tizen.sh --debug          launch in debug mode and forward the Web Inspector to localhost:9222
#   scripts/run-tizen.sh --logs           after launch, stream the app's console logs (Ctrl-C to stop)
#   scripts/run-tizen.sh --uninstall      remove the app from the TV
#   scripts/run-tizen.sh --list           list connected Samsung TVs
#   scripts/run-tizen.sh --reset          restart the sdb server (fixes flaky connections), then continue
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WGT_PATH="${ROOT_DIR}/build/tizen/cnd-iptv-tizen.wgt"
LAST_IP_FILE="${XDG_CACHE_HOME:-${HOME}/.cache}/cnd-iptv/last-tv-ip"
APP_ID="cnd001iptv.CndIptv"
SDB_PORT=26101
INSPECTOR_PORT=9222

if [[ -d "${HOME}/tizen-studio/tools" ]]; then
  export PATH="${PATH}:${HOME}/tizen-studio/tools:${HOME}/tizen-studio/tools/ide/bin"
fi

TV_IP="${TV_IP:-}"
DO_BUILD=1
DO_INSTALL=1
DO_LAUNCH=1
DO_DEBUG=0
DO_LOGS=0
DO_LIST=0
DO_RESET=0
DO_UNINSTALL=0

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip|--device|-d)
      [[ $# -ge 2 ]] || die "--ip requires a TV IP address"
      TV_IP="$2"
      shift
      ;;
    --no-build) DO_BUILD=0 ;;
    --no-launch) DO_LAUNCH=0 ;;
    --launch-only) DO_BUILD=0; DO_INSTALL=0 ;;
    --debug) DO_DEBUG=1 ;;
    --logs) DO_LOGS=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    --list) DO_LIST=1 ;;
    --reset) DO_RESET=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *)
      # A stray word (e.g. "lance on tv") must not silently become the IP.
      if [[ -n "${POSITIONAL_SEEN:-}" ]]; then
        die "unexpected argument '$1' (only one TV IP is accepted; options start with --)"
      fi
      POSITIONAL_SEEN=1
      TV_IP="$1"
      ;;
  esac
  shift
done

# Accept "192.168.1,9" typos and "ip:port" forms.
TV_IP="${TV_IP//,/.}"
TV_IP="${TV_IP%%:*}"

command -v sdb >/dev/null 2>&1 || die "'sdb' not found. Install Tizen Studio in ~/tizen-studio or add sdb to PATH."

if [[ "${DO_RESET}" -eq 1 ]]; then
  step "Restarting the sdb server..."
  sdb kill-server >/dev/null 2>&1 || true
  sdb start-server >/dev/null 2>&1 || true
fi

if [[ "${DO_LIST}" -eq 1 ]]; then
  sdb devices
  exit 0
fi

# Fail early, before a 1-minute build, when the signing/installation CLI is missing.
if [[ "${DO_INSTALL}" -eq 1 || "${DO_UNINSTALL}" -eq 1 ]]; then
  command -v tizen >/dev/null 2>&1 || die "'tizen' CLI not found (expected in ~/tizen-studio/tools/ide/bin). Install Tizen Studio."
fi

# Reuse the last IP when none given and nothing is connected yet.
if [[ -z "${TV_IP}" && -f "${LAST_IP_FILE}" ]]; then
  if ! sdb devices | awk 'NR>1 && $2 == "device"' | grep -q .; then
    TV_IP="$(<"${LAST_IP_FILE}")"
    step "Using the last TV IP: ${TV_IP}"
  fi
fi

if [[ -n "${TV_IP}" && ! "${TV_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "'${TV_IP}' is not a valid IPv4 address"
fi

# 1. Connect to the Samsung TV (retry once after an sdb server restart: the TV's sdb is flaky).
connected() {
  sdb devices | awk -v ip="${TV_IP}:" 'NR>1 && $2 == "device" && index($1, ip) == 1 {found=1} END {exit !found}'
}

if [[ -n "${TV_IP}" ]]; then
  step "Connecting to Samsung TV at ${TV_IP}..."
  sdb connect "${TV_IP}:${SDB_PORT}" >/dev/null 2>&1 || true
  if ! connected; then
    echo "    not connected, restarting the sdb server and retrying..."
    sdb kill-server >/dev/null 2>&1 || true
    sdb start-server >/dev/null 2>&1 || true
    sleep 1
    sdb connect "${TV_IP}:${SDB_PORT}" >/dev/null 2>&1 || true
  fi
  connected || die "cannot reach ${TV_IP}:${SDB_PORT}. Check: TV on and on the same network, Developer Mode on with this Mac's IP, TV IP unchanged."
  mkdir -p "$(dirname "${LAST_IP_FILE}")"
  printf '%s\n' "${TV_IP}" >"${LAST_IP_FILE}"
fi

# Select the device that matches the IP; otherwise the first one.
DEVICE_LINE="$(sdb devices | awk -v ip="${TV_IP}:" '
  NR>1 && $2 == "device" && (ip == ":" || index($1, ip) == 1) {print $1 "\t" $3; exit}')"
if [[ -z "${DEVICE_LINE}" ]]; then
  sdb devices >&2
  die "no Samsung TV connected via sdb. Check Developer Mode on the TV and run: $0 <TV_IP>"
fi

SERIAL="$(printf '%s' "${DEVICE_LINE}" | cut -f1)"
TARGET_NAME="$(printf '%s' "${DEVICE_LINE}" | cut -f2)"
step "Target Samsung TV: ${TARGET_NAME} (${SERIAL})"

if [[ "${DO_UNINSTALL}" -eq 1 ]]; then
  step "Uninstalling ${APP_ID}..."
  tizen uninstall -p "${APP_ID}" -t "${TARGET_NAME}"
  exit 0
fi

if [[ "${DO_INSTALL}" -eq 1 ]]; then
  # 2. Build & sign the .wgt package
  if [[ "${DO_BUILD}" -eq 1 || ! -f "${WGT_PATH}" ]]; then
    step "Building and signing the package..."
    "${SCRIPT_DIR}/build-tizen.sh"
  fi
  [[ -f "${WGT_PATH}" ]] || die "package not found: ${WGT_PATH}"

  # 3. Stop any previous instance so the new package loads cleanly
  step "Stopping any running instance of ${APP_ID}..."
  sdb -s "${SERIAL}" shell 0 was_kill "${APP_ID}" >/dev/null 2>&1 || true

  # 4. Install (the TV profile needs `tizen install`; `sdb install` only pushes the file).
  #    Progress lines are hidden; the full log is shown only on failure.
  step "Installing $(basename "${WGT_PATH}") ($(du -h "${WGT_PATH}" | cut -f1)) onto ${TARGET_NAME}..."
  INSTALL_LOG="$(mktemp -t tizen-install)"
  trap 'rm -f "${INSTALL_LOG}"' EXIT
  if ! tizen install -n "$(basename "${WGT_PATH}")" -t "${TARGET_NAME}" -- "$(dirname "${WGT_PATH}")" >"${INSTALL_LOG}" 2>&1 \
     || ! grep -q "successfully installed" "${INSTALL_LOG}"; then
    cat "${INSTALL_LOG}" >&2
    die "installation failed (signature error? run scripts/build-tizen.sh and check the active certificate profile)"
  fi
  grep -E "successfully installed|Total time" "${INSTALL_LOG}" | sed 's/^/    /'
fi

# 5. Launch (debug mode returns the port of the app's Web Inspector)
if [[ "${DO_LAUNCH}" -eq 1 ]]; then
  sleep 1
  if [[ "${DO_DEBUG}" -eq 1 ]]; then
    step "Launching ${APP_ID} in debug mode..."
    # The TV only starts a debuggable instance when the app is not already running, and
    # the command can hang: read its output with a 15 s limit.
    sdb -s "${SERIAL}" shell 0 was_kill "${APP_ID}" >/dev/null 2>&1 || true
    sleep 2
    DEBUG_LOG="$(mktemp -t tizen-debug)"
    sdb -s "${SERIAL}" shell 0 debug "${APP_ID}" >"${DEBUG_LOG}" 2>&1 &
    DEBUG_PID=$!
    for _ in $(seq 1 15); do
      grep -q 'port:' "${DEBUG_LOG}" 2>/dev/null && break
      sleep 1
    done
    kill "${DEBUG_PID}" >/dev/null 2>&1 || true
    DEBUG_OUT="$(<"${DEBUG_LOG}")"
    rm -f "${DEBUG_LOG}"
    echo "${DEBUG_OUT}" | sed 's/^/    /'
    APP_DEBUG_PORT="$(printf '%s' "${DEBUG_OUT}" | grep -Eo 'port: *[0-9]+' | grep -Eo '[0-9]+' | tail -1 || true)"
    if [[ -n "${APP_DEBUG_PORT}" ]]; then
      sdb -s "${SERIAL}" forward "tcp:${INSPECTOR_PORT}" "tcp:${APP_DEBUG_PORT}" >/dev/null
      step "Web Inspector: open http://localhost:${INSPECTOR_PORT} in Chrome (or chrome://inspect)."
    else
      echo "warning: could not read the debug port from the TV output" >&2
    fi
  else
    step "Launching ${APP_ID} on ${TARGET_NAME}..."
    tizen run -p "${APP_ID}" -t "${TARGET_NAME}" >/dev/null 2>&1 \
      || sdb -s "${SERIAL}" shell 0 was_execute "${APP_ID}" >/dev/null \
      || die "launch failed"
  fi
fi

step "Done."

# 6. Optional: stream the web console of the app
if [[ "${DO_LOGS}" -eq 1 ]]; then
  step "Streaming app logs (Ctrl-C to stop)..."
  sdb -s "${SERIAL}" dlog -c >/dev/null 2>&1 || true
  sdb -s "${SERIAL}" dlog ConsoleMessage:D 'CndIptv:V' '*:E'
fi
