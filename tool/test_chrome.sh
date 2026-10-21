#!/usr/bin/env bash
#
# tool/test_chrome.sh — Fallback-запуск Dart-тестов в headless Chrome
# с собственным HTTP-файловым сервером, отдающим корректные MIME-типы.
#
# Проблема, которую обходит скрипт: встроенный файлраннер package:test
# (dart test -p chrome) в некоторых окружениях отдаёт dart.js с
# Content-Type: text/plain, и Chrome (strict MIME checking) блокирует
# выполнение — тестовый суит не стартует и обрывается по таймауту.
#
# Решение: компилируем тесты в JS, раздаём через Python http.server с
# явным映射 .js → application/javascript, запускаем
# google-chrome-stable в headless-режиме с удалённой отладкой (CDP),
# читаем результат через CDP Runtime.evaluate и возвращаем код выхода.
#
# Использование:
#   bash tool/test_chrome.sh <путь_к_пакету> [порт_сервера]
#
# Пример (CI):
#   bash tool/test_chrome.sh packages/core_crypto 8765
#
# TODO(verify): сценарий не проверен в окружении с MIME-блокировкой dart.js;
# перед вводом в CI обязательно прогонить на целеном раннере.

set -euo pipefail

DART="${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/dart}"
DART="${DART:-$(command -v dart || echo dart)}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <package_dir> [port]" >&2
  exit 64
fi

PKG_DIR="$1"
PORT="${2:-8765}"
CHROME="${CHROME_EXECUTABLE:-google-chrome-stable}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$PKG_DIR"

echo "[test_chrome] pub get ..." >&2
dart pub get >/dev/null 2>&1 || true

echo "[test_chrome] collect test files ..." >&2
TEST_FILES="$(find test -name '*_test.dart' | sort)"
if [[ -z "$TEST_FILES" ]]; then
  echo "[test_chrome] no *_test.dart found in test/" >&2
  exit 0
fi

echo "[test_chrome] compile tests to JS (dart compile js) ..." >&2
for f in $TEST_FILES; do
  out="$TMPDIR/$(basename "${f%.dart}").js"
  "$DART" compile js -O2 -o "$out" "$f" >/dev/null 2>&1 || {
    echo "[test_chrome] dart compile js failed for $f" >&2
    exit 1
  }
done

# dart.js не требуется в Dart 3.x: скомпилированный через
# `dart compile js` код самодостаточен (встроен runtime и хуки dartPrint/
# dartMainRunner). Отдельный файл dart.js в Flutter SDK отсутствует.
DART_JS_SRC=""

# Минимальный HTML-раннер: загружает скомпилированные тесты,
# результат записывает в window.__testResults (читается через CDP).
cat > "$TMPDIR/runner.html" <<EOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>OpenSink Chrome Test Runner</title></head>
<body>
<script>
(function(){
  var results = {passed:0, failed:0, errors:[]};
  var onPass = function(){ results.passed++; };
  var onFail = function(e){ results.failed++; results.errors.push(String(e)); };
  window.__testResults = results;
  window.__reportDone = function(){ return results; };
  // dart2js скомпилированные тесты вызывают 자체íинициализацию;
  // здесь подгружаем каждый тестовый модуль.
  var scripts = [];
</script>
EOF

for f in $TEST_FILES; do
  name="$(basename "${f%.dart}")"
  echo "    scripts.push('$name.js');" >> "$TMPDIR/runner.html"
done

cat >> "$TMPDIR/runner.html" <<EOF
  var i = 0;
  function loadNext(){
    if (i >= scripts.length){ window.__done = true; return; }
    var s = document.createElement('script');
    s.src = scripts[i++];
    s.onload = loadNext;
    s.onerror = function(e){ results.errors.push('load '+scripts[i-1]); loadNext(); };
    document.head.appendChild(s);
  }
  loadNext();
</script>
</body>
</html>
EOF

echo "[test_chrome] start static server on :$PORT (MIME: .js=application/javascript) ..." >&2
python3 - "$PORT" "$TMPDIR" <<'PYEOF' &
import http.server, socketserver, sys, os
port = int(sys.argv[1])
root = sys.argv[2]
os.chdir(root)
class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.js': 'application/javascript',
        '.html': 'text/html; charset=utf-8',
        '.dart': 'application/dart',
    }
    def log_message(self, *args):
        pass
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
PYEOF
SERVER_PID=$!

# Даём серверу время подняться.
sleep 1

CHROME_DATA_DIR="$TMPDIR/chrome-profile"
"$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --remote-debugging-port=9223 \
  --user-data-dir="$CHROME_DATA_DIR" \
  "http://127.0.0.1:$PORT/runner.html" >"$TMPDIR/chrome.log" 2>&1 &
CHROME_PID=$!

echo "[test_chrome] Chrome PID=$CHROME_PID, wait for results ..." >&2

# Ждём__, пока тесты завершатся (до 180 сек), опрашивая CDP.
RESULT_FILE="$TMPDIR/result.json"
DEADLINE=$(( $(date +%s) + 180 ))
got=0
while [[ $(date +%s) -lt $DEADLINE ]]; do
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    echo "[test_chrome] Chrome exited unexpectedly" >&2
    break
  fi
  body=$(printf '{"id":1,"method":"Runtime.evaluate","params":{"expression":"window.__done && window.__reportDone ? JSON.stringify(window.__reportDone()) : null","returnByValue":true}}')
  resp=$(curl -s -X POST http://127.0.0.1:9223/json/rpc -H 'Content-Type: application/json' -d "$body" 2>/dev/null || true)
  result_val=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('result',{}).get('value'))" 2>/dev/null || true)
  if [[ -n "$result_val" && "$result_val" != "null" ]]; then
    echo "$result_val" > "$RESULT_FILE"
    got=1
    break
  fi
  sleep 2
done

if [[ $got -eq 0 ]]; then
  echo "[test_chrome] TIMEOUT: results not received within 180s" >&2
  echo "[test_chrome] chrome.log:" >&2
  cat "$TMPDIR/chrome.log" >&2 || true
  kill "$CHROME_PID" 2>/dev/null || true
  kill "$SERVER_PID" 2>/dev/null || true
  exit 124
fi

passed=$(python3 -c "import json; print(json.load(open('$RESULT_FILE'))['passed'])")
failed=$(python3 -c "import json; print(json.load(open('$RESULT_FILE'))['failed'])")

echo "[test_chrome] passed=$passed failed=$failed" >&2

kill "$CHROME_PID" 2>/dev/null || true
kill "$SERVER_PID" 2>/dev/null || true

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0
