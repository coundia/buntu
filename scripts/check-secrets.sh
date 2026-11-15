#!/usr/bin/env bash
# Refuses a tree where .env, signing/swap files, API key shapes, or local /Users/ paths are versioned
# (PRD 28). Prints file:line only, never the match.
# Looks at tracked files and at new files that are not ignored yet, so that a secret is caught before `git add`.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status=0
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  echo "error: .env is tracked by git; run 'git rm --cached .env'." >&2
  status=1
fi

tracked_sensitive="$(git ls-files --cached --others --exclude-standard | grep -E '\.(p12|keystore|jks|mobileprovision|swp)$' || true)"
if [[ -n "${tracked_sensitive}" ]]; then
  while IFS= read -r file; do
    echo "error: sensitive or swap file tracked by git: ${file} (run 'git rm --cached ${file}')" >&2
  done <<< "${tracked_sensitive}"
  status=1
fi

# OpenAI / Anthropic secret keys and Google API keys.
pattern='(sk-(ant-)?[A-Za-z0-9_]{24,}|AIza[0-9A-Za-z_-]{35})'
hits="$(git grep --untracked -nIE -l "${pattern}" -- . ':!PRD' ':!docs' ':!scripts/check-secrets.sh' ':!scripts/test-gen-default-keys.sh' 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  while IFS= read -r file; do
    git grep --untracked -nIE "${pattern}" -- "${file}" | cut -d: -f1,2 | sed 's/^/error: API key shape at /' >&2
  done <<< "${hits}"
  status=1
fi

# Local developer paths (/Users/<name>/), ignoring synthetic unit-test placeholders (/Users/x/, /Users/me/, /Users/test/).
local_path_hits="$(
  git grep --untracked -nF '/Users/' -- crates/ apple/ android/ tizen/ scripts/ docs/ ':!scripts/check-secrets.sh' 2>/dev/null \
    | awk -F: '{
        file = $1; line_no = $2;
        content = substr($0, length(file) + length(line_no) + 3);
        gsub(/\/Users\/x\//, "", content);
        gsub(/\/Users\/me\//, "", content);
        gsub(/\/Users\/test\//, "", content);
        if (index(content, "/Users/") > 0) print file ":" line_no;
      }' || true
)"
if [[ -n "${local_path_hits}" ]]; then
  while IFS= read -r hit; do
    echo "error: local /Users/ path at ${hit}" >&2
  done <<< "${local_path_hits}"
  status=1
fi

[[ "${status}" -eq 0 ]] && echo "secrets check: clean"
exit "${status}"
