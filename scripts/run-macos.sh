#!/usr/bin/env bash
# Builds the app and launches it on macOS as a real .app bundle (Dock icon, focus, menu bar).
#
#   scripts/run-macos.sh                  debug build, then launch
#   scripts/run-macos.sh --release        optimized build
#   scripts/run-macos.sh --rebuild-core   rebuild the Rust XCFramework first
#   scripts/run-macos.sh --build-only     build the bundle, do not launch
#   scripts/run-macos.sh --foreground     run the executable in this terminal (logs on stdout)
#
# Output goes to build/ (git-ignored); the tracked apple/.build folders are left untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPLE_DIR="${ROOT_DIR}/apple"
SCRATCH_DIR="${ROOT_DIR}/build/swift"
BUNDLE_DIR="${ROOT_DIR}/build/CndIPTV.app"
PRODUCT="CndIptvApp"
BUNDLE_ID="com.cnd.iptv.native"

CONFIG="debug"
REBUILD_CORE=0
LAUNCH=1
FOREGROUND=0

for arg in "$@"; do
  case "${arg}" in
    --release) CONFIG="release" ;;
    --rebuild-core) REBUILD_CORE=1 ;;
    --build-only) LAUNCH=0 ;;
    --foreground) FOREGROUND=1 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: ${arg} (see --help)" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi
command -v swift >/dev/null || { echo "swift not found: install Xcode or the command line tools." >&2; exit 1; }

XCFRAMEWORK="${APPLE_DIR}/Packages/CndCoreBridge/cnd_coreFFI.xcframework"
if [[ "${REBUILD_CORE}" -eq 1 || ! -d "${XCFRAMEWORK}" ]]; then
  command -v cargo >/dev/null || { echo "cargo not found: the Rust core must be built (https://rustup.rs)." >&2; exit 1; }
  echo "==> Building the Rust core XCFramework"
  "${SCRIPT_DIR}/build-xcframework.sh"
fi

"${SCRIPT_DIR}/gen-default-keys.sh" --config "${CONFIG}"

echo "==> Building ${PRODUCT} (${CONFIG})"
(cd "${APPLE_DIR}" && swift build -c "${CONFIG}" --product "${PRODUCT}" --scratch-path "${SCRATCH_DIR}")
BIN_DIR="$(cd "${APPLE_DIR}" && swift build -c "${CONFIG}" --scratch-path "${SCRATCH_DIR}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${PRODUCT}"
[[ -x "${EXECUTABLE}" ]] || { echo "Build produced no executable at ${EXECUTABLE}" >&2; exit 1; }

if [[ "${FOREGROUND}" -eq 1 ]]; then
  echo "==> Running ${EXECUTABLE} (Ctrl-C to quit)"
  exec "${EXECUTABLE}"
fi

# `open` on an app that is already running only brings the old build to the front: stop it first.
if pgrep -f "${BUNDLE_DIR}/Contents/MacOS/${PRODUCT}" >/dev/null 2>&1; then
  echo "==> Quitting the running instance"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "${BUNDLE_DIR}/Contents/MacOS/${PRODUCT}" >/dev/null 2>&1 || break
    sleep 0.3
  done
  pkill -f "${BUNDLE_DIR}/Contents/MacOS/${PRODUCT}" >/dev/null 2>&1 || true
fi

echo "==> Assembling ${BUNDLE_DIR}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS" "${BUNDLE_DIR}/Contents/Resources"
cp "${EXECUTABLE}" "${BUNDLE_DIR}/Contents/MacOS/${PRODUCT}"

# Resource bundles produced by SwiftPM targets (none today, but copy them if they appear).
for resources in "${BIN_DIR}"/*.bundle; do
  [[ -e "${resources}" ]] && cp -R "${resources}" "${BUNDLE_DIR}/Contents/Resources/"
done

if [[ -f "${ROOT_DIR}/assets/AppIcon.icns" ]]; then
  cp "${ROOT_DIR}/assets/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
else
  echo "warning: assets/AppIcon.icns missing (run 'task icon'): the app will have a generic icon" >&2
fi

# No CndCloudKitContainerIdentifier key on purpose: this build never touches iCloud.
cat > "${BUNDLE_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Buntu</string>
  <key>CFBundleDisplayName</key><string>Buntu</string>
  <key>CFBundleExecutable</key><string>${PRODUCT}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}.share</string>
      <key>CFBundleURLSchemes</key><array><string>cndiptv</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>${BUNDLE_ID}.share</string>
      <key>UTTypeDescription</key><string>Partage de sources Buntu</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>cndshare</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Partage de sources Buntu</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>${BUNDLE_ID}.share</string></array>
    </dict>
  </array>
  <key>NSLocalNetworkUsageDescription</key><string>Requis pour envoyer ou recevoir des sources entre vos appareils sur le réseau local.</string>
  <key>NSBonjourServices</key><array><string>_cndiptv._tcp</string></array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature ("Sign to Run Locally"): enough for Gatekeeper on this machine.
codesign --force --sign - "${BUNDLE_DIR}" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed, launching unsigned" >&2

echo "==> Bundle ready: ${BUNDLE_DIR}"
if [[ "${LAUNCH}" -eq 1 ]]; then
  echo "==> Launching"
  open "${BUNDLE_DIR}"
fi
