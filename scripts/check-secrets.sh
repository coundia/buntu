#!/usr/bin/env bash
# Refuses a tree where .env is versioned or a versioned file holds something shaped like an API key
# (PRD 28). Prints file:line only, never the match.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status=0
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  echo "error: .env is tracked by git; run 'git rm --cached .env'." >&2
  status=1
fi

# OpenAI / Anthropic secret keys and Google API keys.
pattern='(sk-(ant-)?[A-Za-z0-9_]{24,}|AIza[0-9A-Za-z_-]{35})'
hits="$(git grep -nIE -l "${pattern}" -- . ':!PRD' ':!docs' ':!scripts/check-secrets.sh' ':!scripts/test-gen-default-keys.sh' 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  while IFS= read -r file; do
    git grep -nIE "${pattern}" -- "${file}" | cut -d: -f1,2 | sed 's/^/error: API key shape at /' >&2
  done <<< "${hits}"
  status=1
fi
[[ "${status}" -eq 0 ]] && echo "secrets check: clean"
exit "${status}"
