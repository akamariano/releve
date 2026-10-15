#!/usr/bin/env bash
# Starts a local web server for the Relevé landing and opens it in the browser.
# Usage: ./servir.sh [port]   (default port: 8000). Press Ctrl+C to stop.

set -euo pipefail

cd "$(dirname "$0")"

PORT="${1:-8000}"

# Move to the next port if the requested one is already taken
while lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  PORT=$((PORT + 1))
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: se necesita python3 para levantar el servidor." >&2
  exit 1
fi

URL="http://localhost:${PORT}/"

echo "Relevé corriendo en ${URL}"
echo "Página 404 de prueba: ${URL}404.html"
echo "Presiona Ctrl+C para detener el servidor."

# Open the browser once the server has had a moment to start
(sleep 1 && open "$URL") &

exec python3 -m http.server "$PORT" --bind 127.0.0.1
