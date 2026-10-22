#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
PACKAGE_DIR="$ROOT_DIR/packages/platform_web"
ASSET_DIR="$PACKAGE_DIR/.dart_tool/storage_test_web_assets"

bash "$ROOT_DIR/tool/fetch_web_assets.sh"
rm -rf "$ASSET_DIR"
mkdir -p "$ASSET_DIR"
trap 'rm -rf "$ASSET_DIR"' EXIT
cp "$ROOT_DIR/apps/app/web/sqlite3.wasm" "$ASSET_DIR/sqlite3.wasm"
cp "$ROOT_DIR/apps/app/web/drift_worker.js" "$ASSET_DIR/drift_worker.js"

cd "$PACKAGE_DIR"
dart test -p chrome -c dart2js
