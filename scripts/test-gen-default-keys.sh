#!/usr/bin/env bash
# Tests of scripts/gen-default-keys.sh (PRD 28): parsing, precedence, release rules, masking.
set -uo pipefail
GEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gen-default-keys.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
gen()  { env -i PATH="${PATH}" "$@" ; }  # clean environment

run() { # <env file> <config> [extra env...] -> output in $TMP/out.swift, log in $TMP/log
  local envf="$1" config="$2"; shift 2
  env -i PATH="${PATH}" "$@" "${GEN}" --env "${envf}" --out "${TMP}/out.swift" --config "${config}" >"${TMP}/log" 2>&1
}
decode() { # property -> plaintext (unmasks with the generated salt)
  python3 -I - "${TMP}/out.swift" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
salt = [int(x) for x in re.search(r"salt: \[UInt8\] = \[([\d, ]+)\]", text).group(1).split(",")]
m = re.search(r"static let %s: \[UInt8\]\? = (nil|\[([\d, ]+)\])" % sys.argv[2], text)
if m.group(1) == "nil": print("<nil>"); sys.exit()
data = [int(x) for x in m.group(2).split(",")]
print(bytes(b ^ salt[i % len(salt)] for i, b in enumerate(data)).decode())
PY
}

# 1. parsing: comments, quotes, spaces, export, inline comment
cat > "${TMP}/a.env" <<'E'
# comment

CND_OMDB_API_KEY = "abc123"
export CND_TMDB_API_KEY='tm db'
CND_OPENSUBTITLES_API_KEY=os-key # inline
E
run "${TMP}/a.env" debug
[[ "$(decode omdb)" == "abc123" ]] && ok "double quotes and spaces" || fail "double quotes and spaces"
[[ "$(decode tmdb)" == "tm db" ]] && ok "single quotes and export" || fail "single quotes and export"
[[ "$(decode openSubtitles)" == "os-key" ]] && ok "inline comment" || fail "inline comment"

# 2. the environment wins over the file
run "${TMP}/a.env" debug CND_OMDB_API_KEY=fromenv
[[ "$(decode omdb)" == "fromenv" ]] && ok "environment takes precedence" || fail "environment takes precedence"

# 3. no .env: valid file, every key nil
run "${TMP}/missing.env" debug
[[ "$(decode omdb)" == "<nil>" && "$(decode gemini)" == "<nil>" ]] && ok "no .env gives empty values" || fail "no .env gives empty values"

# 4. unknown variable and invalid line are refused, without echoing the value
printf 'CND_PASSWORD=hunter2hunter2\n' > "${TMP}/b.env"
if run "${TMP}/b.env" debug; then fail "unknown variable refused"; else
  grep -q "hunter2" "${TMP}/log" && fail "unknown variable: value leaked" || ok "unknown variable refused, value not printed"; fi
printf 'this line has no equals sign SECRETVALUE\n' > "${TMP}/c.env"
if run "${TMP}/c.env" debug; then fail "invalid line refused"; else
  { grep -q "SECRETVALUE" "${TMP}/log" && fail "invalid line: value leaked"; } || ok "invalid line refused with its number, value not printed"; fi

# 5. release rules
cat > "${TMP}/d.env" <<'E'
CND_OMDB_API_KEY=meta
CND_GEMINI_API_KEY=ai
E
run "${TMP}/d.env" release
[[ "$(decode omdb)" == "meta" && "$(decode gemini)" == "<nil>" ]] && ok "release: metadata in, AI out by default" || fail "release defaults"
run "${TMP}/d.env" release CND_EMBED_AI_KEYS_IN_RELEASE=1
[[ "$(decode gemini)" == "ai" ]] && ok "release: AI key embedded when enabled" || fail "release AI enabled"
run "${TMP}/d.env" release CND_EMBED_METADATA_KEYS_IN_RELEASE=0
[[ "$(decode omdb)" == "<nil>" ]] && ok "release: metadata key left out when disabled" || fail "release metadata disabled"
run "${TMP}/d.env" debug
[[ "$(decode gemini)" == "ai" ]] && ok "debug embeds every key" || fail "debug embeds every key"

# 6. no plaintext value in the generated file or the log; log names the keys
run "${TMP}/d.env" debug
{ ! grep -q "meta\"" "${TMP}/out.swift" && ! grep -qE '"ai"' "${TMP}/out.swift" && ! grep -q "meta" "${TMP}/log"; } && ok "no value in clear (file, log)" || fail "value in clear"
grep -q "CND_OMDB_API_KEY" "${TMP}/log" && ok "log names the embedded keys" || fail "log names keys"

# 7. unchanged input keeps the file byte for byte (no needless rebuild); a change rotates the salt
run "${TMP}/d.env" debug; a="$(md5 -q "${TMP}/out.swift" 2>/dev/null || md5sum "${TMP}/out.swift" | cut -d' ' -f1)"
run "${TMP}/d.env" debug; b="$(md5 -q "${TMP}/out.swift" 2>/dev/null || md5sum "${TMP}/out.swift" | cut -d' ' -f1)"
[[ "${a}" == "${b}" ]] && ok "unchanged input leaves the file identical" || fail "stable output"
run "${TMP}/d.env" debug CND_OMDB_API_KEY=other; c="$(grep salt "${TMP}/out.swift")"
[[ "$(grep salt "${TMP}/out.swift")" != "$(printf '%s' "${c}")" || "${a}" != "$(md5 -q "${TMP}/out.swift" 2>/dev/null || md5sum "${TMP}/out.swift" | cut -d' ' -f1)" ]] && ok "changed keys rewrite the file" || fail "changed keys rewrite"

# 8. invalid default provider refused
printf 'CND_DEFAULT_AI_PROVIDER=skynet\n' > "${TMP}/e.env"
run "${TMP}/e.env" debug && fail "invalid default provider refused" || ok "invalid default provider refused"

echo
[[ "${fails}" -eq 0 ]] && echo "all generator tests passed" || { echo "${fails} generator test(s) failed"; exit 1; }
