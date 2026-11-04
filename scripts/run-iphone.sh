#!/usr/bin/env bash
# Builds the iOS app, signs it with your development team, installs it on a connected iPhone/iPad
# and launches it.
#
#   scripts/run-iphone.sh                      first connected device, debug build, launch
#   scripts/run-iphone.sh --release            optimized build
#   scripts/run-iphone.sh --device "icnd 14"   pick a device by name or UDID
#   scripts/run-iphone.sh --rebuild-core       rebuild the Rust XCFramework first
#   scripts/run-iphone.sh --no-launch          build and install only
#   scripts/run-iphone.sh --list               list the connected devices
#
# DEVELOPMENT_TEAM (env) is your Apple team id; the default is the one this project was signed with.
# The device must be unlocked, trusted, and in Developer Mode. Output goes to build/ (git-ignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPLE_DIR="${ROOT_DIR}/apple"
DERIVED_DATA="${ROOT_DIR}/build/DerivedData-device"
TEAM="${DEVELOPMENT_TEAM:-Q6V7UDW27J}"

CONFIG="Debug"
DEVICE=""
REBUILD_CORE=0
LAUNCH=1
LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG="Release" ;;
    --device) DEVICE="${2:?--device needs a name or UDID}"; shift ;;
    --rebuild-core) REBUILD_CORE=1 ;;
    --no-launch) LAUNCH=0 ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# Connected physical devices as "udid<TAB>name", from devicectl's JSON.
connected_devices() {
  local json
  json="$(mktemp -t cnd-devices)"
  xcrun devicectl list devices --json-output "${json}" >/dev/null 2>&1 || true
  python3 - "${json}" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality", "physical") == "physical" \
            and conn.get("tunnelState") != "unavailable" \
            and (conn.get("tunnelState") == "connected" or conn.get("pairingState") == "paired"):
        print(f'{hw.get("udid", d.get("identifier"))}\t{d.get("deviceProperties", {}).get("name", "?")}')
PY
  rm -f "${json}"
}

DEVICES="$(connected_devices)"
if [[ "${LIST}" -eq 1 ]]; then
  if [[ -z "${DEVICES}" ]]; then echo "No connected device."; else echo "${DEVICES}" | awk -F'\t' '{printf "%s  %s\n", $1, $2}'; fi
  exit 0
fi

if [[ -z "${DEVICES}" ]]; then
  echo "error: no connected iPhone/iPad. Plug it in, unlock it and trust this Mac." >&2
  exit 1
fi
if [[ -n "${DEVICE}" ]]; then
  UDID="$(echo "${DEVICES}" | awk -F'\t' -v d="${DEVICE}" '$1 == d || $2 == d {print $1; exit}')"
  [[ -n "${UDID}" ]] || { echo "error: device '${DEVICE}' is not connected. Connected:" >&2; echo "${DEVICES}" | awk -F'\t' '{print "  " $2 " (" $1 ")"}' >&2; exit 1; }
else
  UDID="$(echo "${DEVICES}" | head -1 | cut -f1)"
fi
NAME="$(echo "${DEVICES}" | awk -F'\t' -v u="${UDID}" '$1 == u {print $2; exit}')"
echo "==> Device: ${NAME} (${UDID})"

if [[ "${REBUILD_CORE}" -eq 1 ]]; then
  echo "==> Rebuilding the Rust XCFramework"
  "${ROOT_DIR}/scripts/build-xcframework.sh"
fi

"${SCRIPT_DIR}/gen-default-keys.sh" --config "${CONFIG}"

# The Xcode project is generated from apple/project.yml and not tracked: refresh it so new files are seen.
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> Generating the Xcode project"
  (cd "${APPLE_DIR}" && DEVELOPMENT_TEAM="${TEAM}" xcodegen generate >/dev/null)
fi

echo "==> Building (${CONFIG}, team ${TEAM})"
(cd "${APPLE_DIR}" && xcodebuild -project CndIPTV.xcodeproj -scheme CndIPTV-iOS -configuration "${CONFIG}" \
  -destination "id=${UDID}" -derivedDataPath "${DERIVED_DATA}" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${TEAM}" -quiet build)

APP="${DERIVED_DATA}/Build/Products/${CONFIG}-iphoneos/CndIPTV.app"
[[ -d "${APP}" ]] || { echo "error: ${APP} was not produced" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Info.plist")"

echo "==> Installing ${BUNDLE_ID}"
xcrun devicectl device install app --device "${UDID}" "${APP}" >/dev/null

if [[ "${LAUNCH}" -eq 1 ]]; then
  echo "==> Launching"
  if ! out="$(xcrun devicectl device process launch --device "${UDID}" --terminate-existing "${BUNDLE_ID}" 2>&1)"; then
    if grep -q "Locked" <<<"${out}"; then
      echo "Installed, but the device is locked: unlock it and open the app (or run this script again)." >&2
    else
      echo "${out}" >&2
    fi
    exit 1
  fi
  echo "${out}" | grep -E "Launched" || true
fi
echo "==> Done"
