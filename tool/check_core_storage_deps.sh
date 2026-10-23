#!/usr/bin/env bash
# Проверяет, что Flutter-зависимости хранения остались вне core_storage.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="$REPO_ROOT/packages/core_storage/pubspec.yaml"
PACKAGE="$REPO_ROOT/packages/core_storage"
FOUND=0

if grep -nE 'sqlite3_flutter_libs|path_provider' "$PUBSPEC"; then
  FOUND=1
fi

if grep -RInE --include='*.dart' \
  "package:(sqlite3_flutter_libs|path_provider)/" "$PACKAGE"; then
  FOUND=1
fi

if [ "$FOUND" -ne 0 ]; then
  printf '%s\n' 'check_core_storage_deps: запрещённая Flutter-зависимость в core_storage' >&2
  exit 1
fi

printf '%s\n' 'check_core_storage_deps: OK — sqlite3_flutter_libs и path_provider отсутствуют'
