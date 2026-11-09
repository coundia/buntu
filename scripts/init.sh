#!/usr/bin/env bash
# One-time setup of a fresh clone (or a repair after `git clean`): checks the tools, prepares the
# git-ignored files and builds what is not versioned (the Apple XCFramework of the Rust core).
#
#   scripts/init.sh                 everything that is missing
#   scripts/init.sh --force         rebuild the XCFramework even if it exists
#   scripts/init.sh --skip-core     do not build the XCFramework (checks only)
#
# Never prints a key value. Safe to run again: it only does what is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
XCFRAMEWORK="${ROOT_DIR}/apple/Packages/CndCoreBridge/cnd_coreFFI.xcframework"

FORCE=0
SKIP_CORE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --skip-core) SKIP_CORE=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

cd "${ROOT_DIR}"
missing=0
have() { command -v "$1" >/dev/null 2>&1; }

echo "=== 1/5 Required tools ==="
for tool in cargo rustc rustup swift xcodebuild xcodegen task node npm python3; do
  if have "$tool"; then printf '  ok       %s\n' "$tool"
  else
    case "$tool" in
      xcodegen) hint="brew install xcodegen" ;;
      task)     hint="brew install go-task" ;;
      node|npm) hint="brew install node" ;;
      cargo|rustc|rustup) hint="https://rustup.rs" ;;
      *)        hint="install Xcode and run: xcode-select --install" ;;
    esac
    printf '  MISSING  %s  (%s)\n' "$tool" "$hint"; missing=1
  fi
done

echo "=== 2/5 Rust targets for the Apple XCFramework ==="
targets="aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-visionos aarch64-apple-visionos-sim"
if have rustup; then
  installed="$(rustup target list --installed 2>/dev/null || true)"
  for target in ${targets}; do
    if grep -qx "${target}" <<<"${installed}"; then printf '  ok       %s\n' "${target}"
    else printf '  MISSING  %s  (rustup target add %s)\n' "${target}" "${target}"; missing=1; fi
  done
fi

if [[ "${missing}" != 0 ]]; then
  echo "Some required tools or targets are missing: install them, then run \`task init\` again." >&2
  exit 1
fi

echo "=== 3/5 Local files (git-ignored) ==="
if [[ -f .env ]]; then
  echo "  ok       .env already exists (left untouched)"
elif [[ -f .env.example ]]; then
  cp .env.example .env
  echo "  created  .env from .env.example: put your own API keys in it (optional)"
fi
./scripts/gen-default-keys.sh >/dev/null && echo "  ok       default API keys file generated"

echo "=== 4/5 Rust core as an Apple XCFramework ==="
if [[ "${SKIP_CORE}" == 1 ]]; then
  echo "  skipped  (--skip-core)"
elif [[ -f "${XCFRAMEWORK}/Info.plist" && "${FORCE}" != 1 ]]; then
  echo "  ok       ${XCFRAMEWORK#"${ROOT_DIR}"/} already built (use --force to rebuild)"
else
  echo "  building: several minutes (Rust for macOS, iOS, tvOS and visionOS)…"
  ./scripts/build-xcframework.sh
fi

echo "=== 5/5 Xcode project and Samsung TV dependencies ==="
(cd apple && xcodegen generate >/dev/null) && echo "  ok       apple/CndIPTV.xcodeproj generated"
if [[ -d tizen/node_modules && "${FORCE}" != 1 ]]; then
  echo "  ok       tizen/node_modules already installed"
else
  (cd tizen && npm ci --no-audit --no-fund >/dev/null) && echo "  ok       tizen dependencies installed"
fi

echo
echo "Ready. Next: \`task run\` (Mac), \`task run:iphone\`, \`task tizen:build\`, or \`task check\`."
echo "Android is separate: \`task android:core\` (needs the NDK, see docs/BUILD_ANDROID.md)."
