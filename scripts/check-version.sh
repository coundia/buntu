#!/usr/bin/env bash
# Refuses a tree whose platforms disagree on the release version.
#
#   scripts/check-version.sh           prints the version and checks every platform against Cargo.toml
#   scripts/check-version.sh 1.0.2     also checks that Cargo.toml says 1.0.2 (a tag v1.0.2 must match)
#   scripts/check-version.sh --print   prints "<version> <build number>" and nothing else
#
# Version sources: Cargo.toml (workspace), Android (versionName / versionCode and the About page constants), the four
# Apple Info.plist, the macOS bundle written by scripts/run-macos.sh, AppBrand.swift, Tizen config.xml, package.json,
# package-lock.json and appInfo.ts.
# The build number (Android versionCode, CFBundleVersion) must be the same everywhere.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

plist_value() { # file key
  awk -v key="$2" '$0 ~ "<key>" key "</key>" { if ($0 ~ "<string>") { v = $0 } else { getline; v = $0 }
    gsub(/.*<string>|<\/string>.*/, "", v); print v; exit }' "$1"
}

version="$(awk -F'"' '/^version = / { print $2; exit }' Cargo.toml)"
build="$(sed -nE 's/^ *versionCode = ([0-9]+).*/\1/p' android/app/build.gradle.kts | head -n 1)"

if [[ -z "${version}" || -z "${build}" ]]; then
  echo "error: could not read the version from Cargo.toml or the build number from android/app/build.gradle.kts" >&2
  exit 1
fi

if [[ "${1:-}" == "--print" ]]; then
  echo "${version} ${build}"
  exit 0
fi

status=0
expect() { # label actual expected
  if [[ "$2" != "$3" ]]; then
    echo "error: $1 is '$2', expected '$3'" >&2
    status=1
  fi
}

if [[ -n "${1:-}" ]]; then
  expect "requested version" "${1#v}" "${version}"
fi

expect "android versionName" "$(sed -nE 's/^ *versionName = "([^"]+)".*/\1/p' android/app/build.gradle.kts | head -n 1)" "${version}"
expect "tizen/config.xml version" "$(sed -nE 's/^ *version="([^"]+)">?.*/\1/p' tizen/config.xml | head -n 1)" "${version}"
expect "tizen/package.json version" "$(sed -nE 's/^ *"version": "([^"]+)".*/\1/p' tizen/package.json | head -n 1)" "${version}"
expect "tizen/package-lock.json version" "$(sed -nE 's/^ *"version": "([^"]+)".*/\1/p' tizen/package-lock.json | head -n 1)" "${version}"
expect "tizen appInfo APP_VERSION" "$(sed -nE "s/.*APP_VERSION = '([^']+)'.*/\1/p" tizen/src/core/appInfo.ts | head -n 1)" "${version}"
expect "tizen appInfo APP_BUILD" "$(sed -nE "s/.*APP_BUILD = '([^']+)'.*/\1/p" tizen/src/core/appInfo.ts | head -n 1)" "${build}"
about=android/feature/settings/src/main/kotlin/com/pcoundia/buntu/feature/settings/SettingsScreen.kt
expect "android About APP_VERSION" "$(sed -nE 's/.*const val APP_VERSION = "([^"]+)".*/\1/p' "${about}" | head -n 1)" "${version}"
expect "android About APP_BUILD" "$(sed -nE 's/.*const val APP_BUILD = "([^"]+)".*/\1/p' "${about}" | head -n 1)" "${build}"
expect "AppBrand.appBuild" "$(sed -nE 's/.*appBuild = "([^"]+)".*/\1/p' apple/Sources/CndIptvKit/Shared/Design/AppBrand.swift | head -n 1)" "${build}"
expect "AppBrand.appVersion" "$(sed -nE 's/.*appVersion = "([^"]+)".*/\1/p' apple/Sources/CndIptvKit/Shared/Design/AppBrand.swift | head -n 1)" "${version}"
expect "run-macos.sh bundle version" "$(sed -nE 's/.*CFBundleShortVersionString<\/key><string>([^<]+)<.*/\1/p' scripts/run-macos.sh | head -n 1)" "${version}"
expect "run-macos.sh bundle build" "$(sed -nE 's/.*CFBundleVersion<\/key><string>([^<]+)<.*/\1/p' scripts/run-macos.sh | head -n 1)" "${build}"

for platform in macOS iOS tvOS visionOS; do
  plist="apple/Resources/Info-${platform}.plist"
  expect "${plist} CFBundleShortVersionString" "$(plist_value "${plist}" CFBundleShortVersionString)" "${version}"
  expect "${plist} CFBundleVersion" "$(plist_value "${plist}" CFBundleVersion)" "${build}"
done

if [[ "${status}" -eq 0 ]]; then
  echo "version check: ${version} (build ${build}) on every platform"
fi
exit "${status}"
