#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
PACKAGE_DIR="$ROOT_DIR/packages/platform_web"
ASSET_DIR="$PACKAGE_DIR/.dart_tool/storage_test_web_assets"

if [[ -e "$ASSET_DIR" ]]; then
  printf 'Test asset staging path already exists: %s\n' "$ASSET_DIR" >&2
  exit 1
fi

bash "$ROOT_DIR/tool/fetch_web_assets.sh"
mkdir "$ASSET_DIR"
trap 'rm -rf "$ASSET_DIR"' EXIT
cp "$ROOT_DIR/apps/app/web/sqlite3.wasm" "$ASSET_DIR/sqlite3.wasm"
cp "$ROOT_DIR/apps/app/web/drift_worker.js" "$ASSET_DIR/drift_worker.js"

cd "$PACKAGE_DIR"
dart test \
  test/storage_database_factory_web_test.dart \
  test/storage_performance_web_test.dart \
  -p chrome -c dart2js
