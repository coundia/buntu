#!/usr/bin/env bash
# Installs CND IPTV into macOS Applications folder (/Applications or ~/Applications).
#
# Usage:
#   ./scripts/install-macos.sh              # Build release & install into /Applications
#   ./scripts/install-macos.sh --user       # Install into ~/Applications (user-only)
#   ./scripts/install-macos.sh --debug      # Install debug build instead of release
#   ./scripts/install-macos.sh --rebuild-core # Recompile Rust XCFramework first
#   ./scripts/install-macos.sh --no-launch  # Do not launch after installation
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEST_DIR="/Applications"
CONFIG="release"
REBUILD_CORE=0
LAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      DEST_DIR="${HOME}/Applications"
      ;;
    --system)
      DEST_DIR="/Applications"
      ;;
    --debug)
      CONFIG="debug"
      ;;
    --release)
      CONFIG="release"
      ;;
    --rebuild-core)
      REBUILD_CORE=1
      ;;
    --no-launch)
      LAUNCH=0
      ;;
    --launch)
      LAUNCH=1
      ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Option inconnue : $1 (consultez --help)" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Erreur : ce script ne s'exécute que sur macOS." >&2
  exit 1
fi

APP_NAME="CND IPTV.app"
SOURCE_BUNDLE="${ROOT_DIR}/build/CndIPTV.app"
TARGET_APP="${DEST_DIR}/${APP_NAME}"

echo "=================================================="
echo "  Installation de CND IPTV sur votre Mac"
echo "=================================================="
echo "• Mode : ${CONFIG}"
echo "• Destination : ${TARGET_APP}"
echo ""

# 1. Vérification des permissions du dossier de destination
mkdir -p "${DEST_DIR}"
SUDO=""
if [[ ! -w "${DEST_DIR}" ]]; then
  echo "==> Le dossier ${DEST_DIR} nécessite des droits administrateur (sudo)"
  SUDO="sudo"
fi

# 2. Compilation de l'application
BUILD_FLAGS=(--build-only)
if [[ "${CONFIG}" == "release" ]]; then
  BUILD_FLAGS+=(--release)
fi
if [[ "${REBUILD_CORE}" -eq 1 ]]; then
  BUILD_FLAGS+=(--rebuild-core)
fi

echo "==> Compilation du bundle applicatif (${CONFIG})..."
"${SCRIPT_DIR}/run-macos.sh" "${BUILD_FLAGS[@]}"

if [[ ! -d "${SOURCE_BUNDLE}" ]]; then
  echo "Erreur : le bundle source ${SOURCE_BUNDLE} n'a pas pu être créé." >&2
  exit 1
fi

# 3. Fermer l'application si elle est en cours d'exécution
BUNDLE_ID="com.cnd.iptv.native"
if pgrep -f "${TARGET_APP}/Contents/MacOS" >/dev/null 2>&1 || pgrep -f "CndIptvApp" >/dev/null 2>&1; then
  echo "==> Fermeture de l'instance en cours..."
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -f "${TARGET_APP}/Contents/MacOS" >/dev/null 2>&1 || break
    sleep 0.4
  done
  pkill -f "${TARGET_APP}/Contents/MacOS" >/dev/null 2>&1 || true
fi

# 4. Installation dans le dossier Applications
echo "==> Copie vers ${TARGET_APP}..."
${SUDO} rm -rf "${TARGET_APP}"
${SUDO} cp -R "${SOURCE_BUNDLE}" "${TARGET_APP}"

# Nettoyage des attributs de quarantaine macOS (Gatekeeper)
${SUDO} xattr -cr "${TARGET_APP}" 2>/dev/null || true

# Re-signature ad-hoc locale
${SUDO} codesign --force --deep --sign - "${TARGET_APP}" >/dev/null 2>&1 || true

# 5. Enregistrement auprès de LaunchServices (Spotlight, Finder, Launchpad)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
  echo "==> Enregistrement auprès de LaunchServices..."
  "${LSREGISTER}" -f "${TARGET_APP}" >/dev/null 2>&1 || true
fi

echo ""
echo "=================================================="
echo "  ✅ CND IPTV a été installé avec succès !"
echo "=================================================="
echo "Emplacement : ${TARGET_APP}"
echo "Disponible dans : Launchpad, Spotlight (⌘ + Espace -> CND IPTV) et Finder."
echo ""

# 6. Lancement optionnel
if [[ "${LAUNCH}" -eq 1 ]]; then
  echo "==> Lancement de l'application..."
  open "${TARGET_APP}"
fi

