#!/usr/bin/env bash
# Writes apple/Sources/CndIptvKit/Generated/DefaultApiKeys.generated.swift from the environment and
# the git-ignored .env at the repository root (PRD 28). Never prints a key value.
#
#   scripts/gen-default-keys.sh                 Debug rules: embed every key present
#   scripts/gen-default-keys.sh --config release   Release rules: honour CND_EMBED_*_IN_RELEASE
#   scripts/gen-default-keys.sh --env FILE --out FILE   (tests)
#
# Xcode passes CONFIGURATION; it is used when --config is not given.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
OUT_FILE="${ROOT_DIR}/apple/Sources/CndIptvKit/Generated/DefaultApiKeys.generated.swift"
CONFIG="${CONFIGURATION:-Debug}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs debug or release}"; shift ;;
    --env) ENV_FILE="${2:?--env needs a file}"; shift ;;
    --out) OUT_FILE="${2:?--out needs a file}"; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$(dirname "${OUT_FILE}")"
python3 -I - "${ENV_FILE}" "${OUT_FILE}" "${CONFIG}" <<'PY'
import os, secrets, sys

env_file, out_file, config = sys.argv[1], sys.argv[2], sys.argv[3].lower()

KEYS = {  # variable -> (Swift property, group)
    "CND_OMDB_API_KEY": ("omdb", "metadata"),
    "CND_TMDB_API_KEY": ("tmdb", "metadata"),
    "CND_OPENSUBTITLES_API_KEY": ("openSubtitles", "metadata"),
    "CND_GEMINI_API_KEY": ("gemini", "ai"),
    "CND_OPENAI_API_KEY": ("openAI", "ai"),
    "CND_ANTHROPIC_API_KEY": ("anthropic", "ai"),
}
SETTINGS = {  # plain (non secret) values
    "CND_DEFAULT_AI_PROVIDER": ("defaultAiProvider", {"gemini", "openai", "anthropic", "none"}),
    "CND_OPENAI_BASE_URL": ("openAIBaseURL", None),
    "CND_OPENAI_MODEL": ("openAIModel", None),
}
FLAGS = {"CND_EMBED_METADATA_KEYS_IN_RELEASE": "1", "CND_EMBED_AI_KEYS_IN_RELEASE": "0"}
KNOWN = set(KEYS) | set(SETTINGS) | set(FLAGS)

def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)

values = {}
if os.path.exists(env_file):
    for number, raw in enumerate(open(env_file, encoding="utf-8"), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            fail(f"{env_file}:{number}: expected NAME=value")  # the value is never printed
        name, _, value = line.partition("=")
        name, value = name.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        elif " #" in value:
            value = value.split(" #", 1)[0].rstrip()
        if name not in KNOWN:
            fail(f"{env_file}:{number}: unknown variable {name} (only API keys and the settings of .env.example are accepted)")
        values[name] = value

for name in KNOWN:  # the environment wins over the file
    if os.environ.get(name):
        values[name] = os.environ[name].strip()

release = config == "release"
def enabled(flag):
    return values.get(flag, FLAGS[flag]).strip() == "1"
allowed = {"metadata": not release or enabled("CND_EMBED_METADATA_KEYS_IN_RELEASE"),
           "ai": not release or enabled("CND_EMBED_AI_KEYS_IN_RELEASE")}

def old_salt():
    # The salt only rotates when the content changes: an unchanged .env must not force a rebuild.
    try:
        text = open(out_file, encoding="utf-8").read()
        start = text.index("salt: [UInt8] = [") + len("salt: [UInt8] = [")
        return bytes(int(x) for x in text[start:text.index("]", start)].split(","))
    except Exception:
        return None

def render(salt):
    def masked(text):
        data = text.encode("utf-8")
        return [b ^ salt[i % len(salt)] for i, b in enumerate(data)]
    def swift_bytes(items):
        return "[" + ", ".join(str(x) for x in items) + "]"
    embedded, skipped, lines = [], [], []
    for name, (prop, group) in KEYS.items():
        value = values.get(name, "")
        if not value:
            lines.append(f"    static let {prop}: [UInt8]? = nil")
        elif not allowed[group]:
            skipped.append(name)
            lines.append(f"    static let {prop}: [UInt8]? = nil")
        else:
            embedded.append(name)
            lines.append(f"    static let {prop}: [UInt8]? = {swift_bytes(masked(value))}")
    for name, (prop, choices) in SETTINGS.items():
        value = values.get(name, "")
        if choices is not None and value and value not in choices:
            fail(f"{name} must be one of: {', '.join(sorted(choices))}")
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    static let {prop}: String? = {"nil" if not value else chr(34) + escaped + chr(34)}')
    body = "\n".join(lines)
    text = f"""// Generated by scripts/gen-default-keys.sh. Do not edit, do not commit (PRD 28).
// The values are masked so they do not show up in `strings`; this is not a protection.
enum DefaultApiKeysGenerated {{
    static let salt: [UInt8] = {swift_bytes(salt)}
{body}
}}
"""
    return text, embedded, skipped

previous = old_salt()
text, embedded, skipped = render(previous) if previous else render(secrets.token_bytes(16))
existing = open(out_file, encoding="utf-8").read() if os.path.exists(out_file) else None
if existing != text:
    if existing is not None and previous:
        text, embedded, skipped = render(secrets.token_bytes(16))
    open(out_file, "w", encoding="utf-8").write(text)
print(f"default API keys ({'release' if release else 'debug'}): "
      f"embedded {', '.join(embedded) if embedded else 'none'}"
      + (f"; left out of this build: {', '.join(skipped)}" if skipped else ""))
PY
