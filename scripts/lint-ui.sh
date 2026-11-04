#!/usr/bin/env bash
# Reports sizes written straight into views instead of coming from the design tokens (PRD 30 § 8):
# literal frame(width:/height:), .font(.system(size:), GridItem(.adaptive(minimum: <number>).
# Warning only for now (exit 0); pass --strict to fail when something is reported.
# Allowed on a line with `// lint:ui-ignore <reason>` (decorative shapes, aspect ratios, monospaced console).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/apple/Sources"
STRICT=0; [[ "${1:-}" == "--strict" ]] && STRICT=1

pattern='frame\((min|max)?(width|height|Width|Height): *[0-9]|\.font\(\.system\(size:|GridItem\(\.adaptive\(minimum: *[0-9]'
hits="$(grep -rnE "${pattern}" --include='*.swift' . | grep -v 'Shared/Design/' | grep -v 'lint:ui-ignore' || true)"
count=0; [[ -n "${hits}" ]] && count="$(echo "${hits}" | wc -l | tr -d ' ')"

if [[ "${count}" -gt 0 ]]; then
  echo "${hits}" | cut -d: -f1 | sort | uniq -c | sort -rn | head -15 | sed 's/^ *\([0-9]*\) \(.*\)/  \1  \2/'
  echo "lint:ui: ${count} fixed size(s) outside Shared/Design (use UIMetrics from @Environment(\\.uiMetrics))."
else
  echo "lint:ui: clean"
fi

# PRD 31: a bare onTapGesture is neither a button for VoiceOver nor reachable by keyboard; use accessibleTap.
taps="$(grep -rnE '\.onTapGesture' --include='*.swift' . | grep -v 'Shared/Accessibility/' | grep -v 'lint:ui-ignore' || true)"
tapCount=0; [[ -n "${taps}" ]] && tapCount="$(echo "${taps}" | wc -l | tr -d ' ')"
if [[ "${tapCount}" -gt 0 ]]; then
  echo "${taps}" | cut -d: -f1,2 | sed 's/^/  onTapGesture: /'
  echo "lint:ui: ${tapCount} bare onTapGesture (use .accessibleTap, PRD 31)."
fi
[[ "${STRICT}" -eq 1 && $((count + tapCount)) -gt 0 ]] && exit 1
exit 0
