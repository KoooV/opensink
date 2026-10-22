#!/usr/bin/env bash
# Проверяет импорты в исходниках packages/core_*/lib.
# Тесты могут использовать платформенные executor-ы и не входят в эту проверку.
# Возвращает ненулевой код при находках.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Общие запреты для всех core_* пакетов.
FORBIDDEN_ALL='dart:io|dart:html|package:web|dart:js_interop'

# Дополнительные запреты только для core_storage.
FORBIDDEN_STORAGE='package:drift/native.dart|package:drift/wasm.dart|dart:io|dart:ffi|dart:html|package:web|dart:js_interop|sqlite3_flutter_libs|path_provider'

FOUND=0
IMPORT_DIRECTIVE='^[[:space:]]*(import|export|part)[[:space:]]+[\x27\x22]'
while IFS= read -r -d '' file; do
  if grep -qnE "${IMPORT_DIRECTIVE}(${FORBIDDEN_ALL})[\x27\x22]" "$file" 2>/dev/null; then
    echo "FORBIDDEN import in $file:" >&2
    grep -nE "${IMPORT_DIRECTIVE}(${FORBIDDEN_ALL})[\x27\x22]" "$file" >&2
    FOUND=1
  fi
done < <(find "$REPO_ROOT/packages" -type f -path '*/core_*/lib/*.dart' -print0)

while IFS= read -r -d '' file; do
  if grep -qnE "${IMPORT_DIRECTIVE}(${FORBIDDEN_STORAGE})[\x27\x22]" "$file" 2>/dev/null; then
    echo "FORBIDDEN import in $file:" >&2
    grep -nE "${IMPORT_DIRECTIVE}(${FORBIDDEN_STORAGE})[\x27\x22]" "$file" >&2
    FOUND=1
  fi
done < <(find "$REPO_ROOT/packages/core_storage/lib" -type f -name '*.dart' -print0)

if [ "$FOUND" -ne 0 ]; then
  echo "check_core_imports: найдены запрещённые импорты в core_* пакетах" >&2
  exit 1
fi

echo "check_core_imports: OK — нет запрещённых импортов в core_* пакетах"
exit 0
