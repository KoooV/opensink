#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
APP_DIR="$ROOT_DIR/apps/app"
BUILD_DIR="$APP_DIR/build/web"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
COOP="${COOP:-}"
COEP="${COEP:-}"

if [[ "${ENABLE_CROSS_ORIGIN_ISOLATION:-0}" == "1" ]]; then
  COOP="${COOP:-same-origin}"
  COEP="${COEP:-require-corp}"
fi

bash "$ROOT_DIR/tool/fetch_web_assets.sh"
(
  cd "$APP_DIR"
  flutter build web --debug
)
(
  cd "$BUILD_DIR"
  sha256sum --check "$ROOT_DIR/tool/web_assets.sha256"
)

python3 - "$BUILD_DIR" "$HOST" "$PORT" "$COOP" "$COEP" <<'PY'
import http.server
import os
import sys

root, host, raw_port, coop, coep = sys.argv[1:]
os.chdir(root)

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".js": "application/javascript",
        ".wasm": "application/wasm",
    }

    def end_headers(self):
        if coop:
            self.send_header("Cross-Origin-Opener-Policy", coop)
        if coep:
            self.send_header("Cross-Origin-Embedder-Policy", coep)
        super().end_headers()

with http.server.ThreadingHTTPServer((host, int(raw_port)), Handler) as server:
    print(f"Serving debug web build at http://{host}:{raw_port}/", flush=True)
    server.serve_forever()
PY
