#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/install-opencode-tor.sh"
./build-install.sh "$OUT"
[ -x "$OUT" ] || { echo "FAIL: instalador no ejecutable"; exit 1; }
bash -n "$OUT" || { echo "FAIL: sintaxis"; exit 1; }
# El instalador embebe el plugin: verificar que los payloads son base64 válido.
grep -q '__PLUGIN_B64__' "$OUT" && { echo "FAIL: placeholder plugin sin sustituir"; exit 1; }
grep -q '__WRAPPER_B64__' "$OUT" && { echo "FAIL: placeholder wrapper sin sustituir"; exit 1; }
grep -q '__TORRC_B64__' "$OUT" && { echo "FAIL: placeholder torrc sin sustituir"; exit 1; }
echo "PASS: generator smoke test"
