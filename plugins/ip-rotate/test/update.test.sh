#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Binario fake (evita la descarga real del release) + HOME/instalación
# aislados: nada de esto toca ~/.opencode-tor de verdad.
cat > "$WORK/fake-opencode" <<'EOF'
#!/usr/bin/env bash
echo "1.0.0-fake"
EOF
chmod +x "$WORK/fake-opencode"

# El instalador siempre instala en $HOME/.opencode-tor (no respeta
# OPENCODE_TOR_DIR -- esa variable solo la usan el wrapper y el daemon en
# tiempo de ejecución), así que aislamos con un HOME falso.
INSTALL="$WORK/.opencode-tor"

HOME="$WORK" \
./update-opencode-tor.sh --binary "$WORK/fake-opencode" --no-modify-path \
  > "$WORK/out.log" 2>&1 || { echo "FAIL: update-opencode-tor.sh salió con error"; cat "$WORK/out.log"; exit 1; }

grep -q "regenerando el instalador" "$WORK/out.log" \
  || { echo "FAIL: no se regeneró el instalador desde el código actual"; cat "$WORK/out.log"; exit 1; }
[ -x "$INSTALL/bin/opencode" ] \
  || { echo "FAIL: binario no instalado en $INSTALL/bin/opencode"; cat "$WORK/out.log"; exit 1; }
[ -x "$INSTALL/bin/opencode-tor" ] \
  || { echo "FAIL: wrapper no instalado"; cat "$WORK/out.log"; exit 1; }
[ -f "$INSTALL/plugins/ip-rotate/exit-sweep-daemon.py" ] \
  || { echo "FAIL: daemon de sweep no desplegado (regeneración no se aplicó)"; cat "$WORK/out.log"; exit 1; }
echo "PASS: update-opencode-tor test"
