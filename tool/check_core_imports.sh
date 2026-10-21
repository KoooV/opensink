#!/usr/bin/env bash
# Проверяет, что в packages/core_* нет запрещённых импортов:
# dart:io, dart:html, package:web, dart:js_interop.
# core_crypto — чистый Dart; платформенные реализации живут в platform_*.
# Возвращает ненулевой код при находках.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORBIDDEN='dart:io|dart:html|package:web|dart:js_interop'

FOUND=0
while IFS= read -r -d '' file; do
  if grep -qnE "$FORBIDDEN" "$file" 2>/dev/null; then
    echo "FORBIDDEN import in $file:" >&2
    grep -nE "$FORBIDDEN" "$file" >&2
    FOUND=1
  fi
done < <(find "$REPO_ROOT/packages" -path '*/core_*' -name '*.dart' -print0)

if [ "$FOUND" -ne 0 ]; then
  echo "check_core_imports: найдены запрещённые импорты в core_* пакетах" >&2
  exit 1
fi

echo "check_core_imports: OK — нет запрещённых импортов в core_* пакетах"
exit 0
