#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Directorio de instalación fake + configs con la línea de opencode-tor.
INSTALL="$WORK/inst"
mkdir -p "$INSTALL/bin" "$INSTALL/plugins/ip-rotate"
touch "$INSTALL/bin/opencode" "$INSTALL/bin/opencode-tor" "$INSTALL/plugins/ip-rotate/index.ts"
printf '\nexport PATH=%s/bin:$PATH\n' "$INSTALL" > "$WORK/.bashrc"
printf '\n# opencode-tor\nexport PATH=%s/bin:$PATH\n' "$INSTALL" >> "$WORK/.bashrc"

# Stub docker que simula un contenedor existente.
cat > "$WORK/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
case "$1" in
  inspect) echo "{}" >&1; exit 0 ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/docker"
export LOG="$WORK/docker.log"
: > "$LOG"

# Ejecutar el desinstalador con HOME fake, --yes y docker stub.
HOME="$WORK" \
OPENCODE_TOR_DIR="$INSTALL" \
OPENCODE_TOR_CONTAINER="ip-rotate-tor-test" \
PATH="$WORK:$PATH" \
"$PWD/uninstall-opencode-tor.sh" --yes > "$WORK/out.log" 2>&1

[ ! -e "$INSTALL" ] || { echo "FAIL: $INSTALL no se eliminó"; cat "$WORK/out.log"; exit 1; }
grep -q "opencode-tor" "$WORK/.bashrc" && { echo "FAIL: línea de PATH no se quitó"; cat "$WORK/.bashrc"; exit 1; }
grep -q "docker rm" "$WORK/docker.log" || { echo "FAIL: no se eliminó el contenedor"; cat "$WORK/docker.log"; exit 1; }
echo "PASS: uninstall test"
