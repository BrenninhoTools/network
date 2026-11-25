#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export NETWORK_PORT="${NETWORK_PORT:-17777}"
node server/index.js --port "$NETWORK_PORT" --host 127.0.0.1 --quiet &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
for i in $(seq 1 50); do
  if node -e "fetch('http://127.0.0.1:$NETWORK_PORT/health').then(()=>process.exit(0)).catch(()=>process.exit(1))"; then break; fi
  sleep 0.1
done
haxe -cp src -cp tests -main TestClient --interp
haxe -cp src -cp tests -main TestClient -js bin/test.js
node bin/test.js
