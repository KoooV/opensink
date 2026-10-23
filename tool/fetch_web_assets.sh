#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
LOCK_FILE="$ROOT_DIR/tool/web_assets.lock"
CHECKSUM_FILE="$ROOT_DIR/tool/web_assets.sha256"
WEB_DIR="$ROOT_DIR/apps/app/web"

readarray -t versions < <(python3 - "$ROOT_DIR/pubspec.lock" "$LOCK_FILE" <<'PY'
import json
import re
import sys

lock_path, assets_path = sys.argv[1:]
text = open(lock_path, encoding="utf-8").read()
assets = json.load(open(assets_path, encoding="utf-8"))

def locked_version(name):
    marker = f"  {name}:\n"
    start = text.index(marker) + len(marker)
    block = []
    for line in text[start:].splitlines():
        if line and not line.startswith(" "):
            break
        block.append(line)
    match = re.search(r'^    version: "([^\"]+)"$', "\n".join(block), re.M)
    if not match:
        raise SystemExit(f"Не найдена версия {name} в pubspec.lock")
    return match.group(1)

locked_drift = locked_version("drift")
locked_sqlite3 = locked_version("sqlite3")
if assets["drift"] != locked_drift:
    raise SystemExit(f"Версия drift в web_assets.lock ({assets['drift']}) != pubspec.lock ({locked_drift})")
if assets["sqlite3"] != locked_sqlite3:
    raise SystemExit(f"Версия sqlite3 в web_assets.lock ({assets['sqlite3']}) != pubspec.lock ({locked_sqlite3})")
if assets["driftRelease"] != locked_drift.split("+", 1)[0]:
    raise SystemExit("GitHub-тег drift не соответствует версии пакета в pubspec.lock")
if assets["sqlite3Release"] != locked_sqlite3:
    raise SystemExit("GitHub-тег sqlite3 не соответствует версии пакета в pubspec.lock")

print(assets["driftRelease"])
print(assets["sqlite3Release"])
PY
)

DRIFT_RELEASE="${versions[0]}"
SQLITE3_RELEASE="${versions[1]}"

if [[ "${1:-}" == "--check" ]]; then
  (
    cd "$WEB_DIR"
    sha256sum --check "$CHECKSUM_FILE"
  )
  printf 'OK: drift %s / sqlite3 %s ресурсы соответствуют lock и SHA-256.\n' \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["drift"])' "$LOCK_FILE")" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sqlite3"])' "$LOCK_FILE")"
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  printf 'Использование: %s [--check]\n' "$0" >&2
  exit 64
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

SQLITE3_URL="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_RELEASE}/sqlite3.wasm"
DRIFT_WORKER_URL="https://github.com/simolus3/drift/releases/download/drift-${DRIFT_RELEASE}/drift_worker.js"
curl --fail --location --silent --show-error "$SQLITE3_URL" -o "$TEMP_DIR/sqlite3.wasm"
curl --fail --location --silent --show-error "$DRIFT_WORKER_URL" -o "$TEMP_DIR/drift_worker.js"
(
  cd "$TEMP_DIR"
  sha256sum --check "$CHECKSUM_FILE"
)
cp "$TEMP_DIR/sqlite3.wasm" "$WEB_DIR/sqlite3.wasm"
cp "$TEMP_DIR/drift_worker.js" "$WEB_DIR/drift_worker.js"
printf 'Ресурсы сохранены в %s.\n' "$WEB_DIR"
