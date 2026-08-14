#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub docker que registra las llamadas en un log.
export LOG="$WORK/docker.log"
cat > "$WORK/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
case "$1" in
  inspect)
    # Contenedor inexistente: stderr vacío y exit 1 (como docker real).
    echo "" >&2
    exit 1
    ;;
  run)
    # Simula arranque: toca los puertos no se simulan; listo.
    exit 0
    ;;
  stop) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/docker"
: > "$LOG"

# Binario fake + config + torrc mínimos.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode llamado con: $*"
echo "HTTP_PROXY=$HTTP_PROXY"
echo "OPENCODE_CONFIG=$OPENCODE_CONFIG"
EOF
chmod +x "$WORK/bin/opencode"
cat > "$WORK/torrc" <<'EOF'
SocksPort 9050
HTTPTunnelPort 8118
ControlPort 9051
HashedControlPassword 16:0000000000000000000000000000000000000000000000000000
MaxCircuitDirtiness 86400
EOF
cat > "$WORK/opencode.json" <<'EOF'
{ "plugin": [] }
EOF

# Ejecutar el wrapper con overrides de test y "docker" del stub en PATH.
OPENCODE_TOR_DIR="$WORK" \
OPENCODE_TOR_BIN="$WORK/bin/opencode" \
OPENCODE_TOR_CONTAINER="ip-rotate-tor-test" \
OPENCODE_TOR_SKIP_READY=1 \
OPENCODE_TOR_KEEP=1 \
PATH="$WORK:$PATH" \
"$PWD/opencode-tor" "run" "hola mundo" > "$WORK/out.log" 2>&1 || true

grep -q "opencode llamado con: run hola mundo" "$WORK/out.log" \
  || { echo "FAIL: opencode no ejecutado con args"; cat "$WORK/out.log"; exit 1; }
grep -q "HTTP_PROXY=http://127.0.0.1:8118" "$WORK/out.log" \
  || { echo "FAIL: no se exportó HTTP_PROXY"; cat "$WORK/out.log"; exit 1; }
grep -q "OPENCODE_CONFIG=$WORK/opencode.json" "$WORK/out.log" \
  || { echo "FAIL: no se exportó OPENCODE_CONFIG"; cat "$WORK/out.log"; exit 1; }
grep -q "docker run" "$WORK/docker.log" \
  || { echo "FAIL: no se invocó docker run"; cat "$WORK/docker.log"; exit 1; }
echo "PASS: wrapper test"
