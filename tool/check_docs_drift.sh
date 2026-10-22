#!/usr/bin/env bash
# Проверяет дрейф документации относительно кода:
#   (a) пакеты, упомянутые в docs/DESIGN.md, есть в pubspec.yaml workspace;
#   (b) идентификаторы дефектов D-xx, упомянутые в docs/DESIGN.md, есть в таблице docs/DEFECTS.md;
#   (c) индекс TODO(verify) в docs/OPEN_QUESTIONS.md vs TODO(verify) в коде.
# Возвращает ненулевой код при дрейфе в (a), (b) или (c).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESIGN="$REPO_ROOT/docs/DESIGN.md"
DEFECTS="$REPO_ROOT/docs/DEFECTS.md"
OPEN_Q="$REPO_ROOT/docs/OPEN_QUESTIONS.md"
PUBSPEC="$REPO_ROOT/pubspec.yaml"

FAIL=0

echo "== Проверка (a): пакеты в DESIGN.md vs pubspec.yaml workspace =="

# Рабочие пакеты из workspace (имена без префикса packages/ / apps/)
WORKSPACE_PKGS=$(grep -E '^\s+- (packages|apps)/' "$PUBSPEC" \
  | sed 's/^\s*- //; s|^packages/||; s|^apps/||' \
  | sort -u)

# Пакетные пути в DESIGN.md: packages/<name>, platform_<name>, apps/app
DESIGN_PKGS=$(grep -oE '(packages/|apps/)?[a-z0-9_]+(/[a-z0-9_]+)?' "$DESIGN" \
  | grep -E '^(packages/|apps/)?(core_[a-z0-9_]+|platform_[a-z0-9_]+|app)$' \
  | sed 's|^packages/||; s|^apps/||' \
  | sort -u)

echo "Рабочие пакеты из pubspec.yaml:"
echo "$WORKSPACE_PKGS"
echo ""
echo "Пакеты, найденные в DESIGN.md:"
echo "$DESIGN_PKGS"

for pkg in $DESIGN_PKGS; do
  if ! echo "$WORKSPACE_PKGS" | grep -qx "$pkg"; then
    echo "DRIFT (a): пакет '$pkg' упомянут в DESIGN.md, но отсутствует в pubspec.yaml workspace" >&2
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "OK (a): все пакеты из DESIGN.md присутствуют в workspace"
fi

echo ""
echo "== Проверка (b): D-xx в DESIGN.md vs DEFECTS.md =="

# Все D-xx в DESIGN.md (с префиксом D-)
DESIGN_DEFECTS=$(grep -oE 'D-[0-9]+' "$DESIGN" | sort -u)

# Все D-xx в таблице DEFECTS.md (с префиксом D-)
DEFECTS_TABLE_IDS=$(grep -oE '\| D-[0-9]+ \|' "$DEFECTS" | tr -d ' |' | sort -u)

echo "D-xx в DESIGN.md:"
echo "$DESIGN_DEFECTS"
echo ""
echo "D-xx в таблице DEFECTS.md:"
echo "$DEFECTS_TABLE_IDS"

for d in $DESIGN_DEFECTS; do
  if ! echo "$DEFECTS_TABLE_IDS" | grep -qx "$d"; then
    echo "DRIFT (b): дефект $d упомянут в DESIGN.md, но отсутствует в таблице docs/DEFECTS.md" >&2
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "OK (b): все D-xx из DESIGN.md есть в DEFECTS.md"
fi

echo ""
echo "== Проверка (c): индекс TODO(verify) в OPEN_QUESTIONS.md vs TODO(verify) в коде =="

Q_COUNT=$(grep -cE '^## Q[0-9]+' "$OPEN_Q" || true)
TODO_LOCS=$(grep -rIn "TODO(verify)" "$REPO_ROOT/packages" "$REPO_ROOT/apps" --include="*.dart" 2>/dev/null \
  | cut -d: -f1,2 | sed "s|$REPO_ROOT/||" | sort || true)
TODO_COUNT=$(printf '%s\n' "$TODO_LOCS" | sed '/^$/d' | wc -l)
INDEX_LOCS=$(grep -oE '\| `?(packages|apps)/[^| `]+:[0-9]+`? \|' "$OPEN_Q" \
  | tr -d '| `' | sort || true)
INDEX_COUNT=$(printf '%s\n' "$INDEX_LOCS" | sed '/^$/d' | wc -l)

echo "Q-xx записей в OPEN_QUESTIONS.md: $Q_COUNT"
echo "TODO(verify) в dart-коде: $TODO_COUNT"
echo "Записей в индексе TODO: $INDEX_COUNT"

if [ "$TODO_COUNT" -ne "$INDEX_COUNT" ]; then
  echo "DRIFT (c): число TODO(verify) ($TODO_COUNT) не совпадает с числом записей индекса ($INDEX_COUNT)" >&2
  FAIL=1
elif [ "$TODO_LOCS" != "$INDEX_LOCS" ]; then
  echo "DRIFT (c): список TODO(verify) не совпадает с индексом" >&2
  diff <(printf '%s\n' "$TODO_LOCS") <(printf '%s\n' "$INDEX_LOCS") >&2 || true
  FAIL=1
else
  echo "OK (c): все TODO(verify) учтены в индексе ($TODO_COUNT = $INDEX_COUNT)"
fi

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "check_docs_drift: ОБНАРУЖЕН ДРЕЙФ ДОКУМЕНТАЦИИ (a или b)" >&2
  exit 1
fi

echo "check_docs_drift: OK — критических расхождений не обнаружено"
exit 0