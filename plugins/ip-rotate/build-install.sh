#!/usr/bin/env bash
set -euo pipefail

# Genera install-opencode-tor.sh autocontenido con el plugin ip-rotate y el
# wrapper opencode-tor embebidos. Ejecuta: ./build-install.sh [output-path]
# (default: plugins/ip-rotate/install-opencode-tor.sh)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN_DIR="$ROOT/plugins/ip-rotate"
OUT="${1:-$PLUGIN_DIR/install-opencode-tor.sh}"

for f in index.ts package.json src/config.ts src/detector.ts src/rotator.ts src/resumer.ts src/state.ts; do
  [ -f "$PLUGIN_DIR/$f" ] || { echo "falta $f" >&2; exit 1; }
done
[ -f "$PLUGIN_DIR/opencode-tor" ] || { echo "falta opencode-tor" >&2; exit 1; }
[ -f "$PLUGIN_DIR/uninstall-opencode-tor.sh" ] || { echo "falta uninstall-opencode-tor.sh" >&2; exit 1; }
[ -f "$PLUGIN_DIR/ip-refresh.sh" ] || { echo "falta ip-refresh.sh" >&2; exit 1; }
[ -f "$PLUGIN_DIR/tui-logo.tsx" ] || { echo "falta tui-logo.tsx" >&2; exit 1; }
[ -f "$PLUGIN_DIR/torrc" ] || { echo "falta torrc" >&2; exit 1; }
[ -f "$PLUGIN_DIR/art/opencode-tor.txt" ] || { echo "falta art/opencode-tor.txt" >&2; exit 1; }
[ -f "$PLUGIN_DIR/exit-sweep-daemon.py" ] || { echo "falta exit-sweep-daemon.py" >&2; exit 1; }

PLUGIN_B64=$(tar -C "$PLUGIN_DIR" -czf - index.ts package.json src | base64 | tr -d '\n')
WRAPPER_B64=$(base64 < "$PLUGIN_DIR/opencode-tor" | tr -d '\n')
UNINSTALL_B64=$(base64 < "$PLUGIN_DIR/uninstall-opencode-tor.sh" | tr -d '\n')
REFRESH_B64=$(base64 < "$PLUGIN_DIR/ip-refresh.sh" | tr -d '\n')
TUI_LOGO_B64=$(base64 < "$PLUGIN_DIR/tui-logo.tsx" | tr -d '\n')
TORRC_B64=$(base64 < "$PLUGIN_DIR/torrc" | tr -d '\n')
ART_B64=$(base64 < "$PLUGIN_DIR/art/opencode-tor.txt" | tr -d '\n')
DAEMON_B64=$(base64 < "$PLUGIN_DIR/exit-sweep-daemon.py" | tr -d '\n')

cat > "$OUT" <<'INSTALLER_EOF'
#!/usr/bin/env bash
set -euo pipefail

APP=opencode-tor
INSTALL_DIR="$HOME/.opencode-tor"
MUTED='\033[0;2m'; RED='\033[0;31m'; ORANGE='\033[38;5;214m'; NC='\033[0m'

usage() {
  cat <<EOF
OpenCode-Tor Installer

Usage: install-opencode-tor.sh [options]

Options:
    -h, --help              Show this help
    -v, --version <version> Install a specific opencode version
    -b, --binary <path>     Install from a local opencode binary
        --no-modify-path    Don't modify shell config files
EOF
}

requested_version=${VERSION:-}
no_modify_path=false
binary_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v|--version)
      if [[ -n "${2:-}" ]]; then requested_version="$2"; shift 2; else echo -e "${RED}Error: --version requires an argument${NC}"; exit 1; fi
      ;;
    -b|--binary)
      if [[ -n "${2:-}" ]]; then binary_path="$2"; shift 2; else echo -e "${RED}Error: --binary requires an argument${NC}"; exit 1; fi
      ;;
    --no-modify-path) no_modify_path=true; shift ;;
    *) echo -e "${ORANGE}Warning: unknown option '$1'${NC}" >&2; shift ;;
  esac
done

# --- 0. No reinstalar con instancias en ejecución ---
# Sobrescribir el binario o el wrapper mientras corren falla (ETXTBSY) o
# corrompe el proceso vivo. Detectar y pedir al usuario que los cierre.
if command -v pgrep >/dev/null 2>&1; then
  running=$(pgrep -af "$INSTALL_DIR/bin/" 2>/dev/null | grep -v "^$$\|pgrep" || true)
  if [ -n "$running" ]; then
    echo -e "${RED}Error: hay instancias de opencode-tor en ejecución:${NC}" >&2
    echo "$running" >&2
    echo -e "${RED}Ciérralas (cada TUI/sesión) y vuelve a lanzar el instalador.${NC}" >&2
    exit 1
  fi
fi

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/plugins"

# --- 1. opencode binary ---
BIN_FILE="$INSTALL_DIR/bin/opencode"
if [ -n "$binary_path" ]; then
  if [ ! -f "$binary_path" ]; then
    echo -e "${RED}Error: binary not found at $binary_path${NC}"; exit 1
  fi
  # Temporal + mv atómico: cp directo falla con ETXTBSY si hay un opencode-tor corriendo.
  cp "$binary_path" "$BIN_FILE.tmp" && mv "$BIN_FILE.tmp" "$BIN_FILE"
  chmod 755 "$BIN_FILE"
else
  raw_os=$(uname -s); os=$(echo "$raw_os" | tr '[:upper:]' '[:lower:]')
  case "$raw_os" in
    Darwin*) os="darwin" ;; Linux*) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
  esac
  arch=$(uname -m)
  [ "$arch" = "aarch64" ] && arch="arm64"
  [ "$arch" = "x86_64" ] && arch="x64"
  case "$os-$arch" in
    linux-x64|linux-arm64|darwin-x64|darwin-arm64|windows-x64) ;;
    *) echo -e "${RED}Unsupported OS/Arch: $os/$arch${NC}"; exit 1 ;;
  esac
  is_musl=false
  if [ "$os" = "linux" ]; then
    { [ -f /etc/alpine-release ] || (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl); } && is_musl=true
  fi
  needs_baseline=false
  if [ "$arch" = "x64" ] && [ "$os" = "linux" ] && ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
    needs_baseline=true
  fi
  target="$os-$arch"
  [ "$needs_baseline" = "true" ] && target="$target-baseline"
  [ "$is_musl" = "true" ] && target="$target-musl"
  ext=".zip"; [ "$os" = "linux" ] && ext=".tar.gz"
  filename="opencode-$target$ext"
  url="https://github.com/anomalyco/opencode/releases/latest/download/$filename"
  [ -n "$requested_version" ] && url="https://github.com/anomalyco/opencode/releases/download/v${requested_version#v}/$filename"

  tmp="${TMPDIR:-/tmp}/opencode_tor_install_$$"
  mkdir -p "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/$filename" "$url"
  if [ "$os" = "linux" ]; then tar -xzf "$tmp/$filename" -C "$tmp"; else unzip -q "$tmp/$filename" -d "$tmp"; fi
  mv "$tmp/opencode" "$BIN_FILE"
  chmod 755 "$BIN_FILE"
  rm -rf "$tmp"
fi

# --- 2. Plugin ---
# Dependencias duras del entorno: docker es obligatorio en runtime (el wrapper
# lo requiere para el contenedor Tor); sin bun/npm el plugin no puede resolver
# @opencode-ai/plugin y no cargará. Fallar pronto y con mensaje claro.
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${RED}Error: docker no está instalado o no está en PATH.${NC}" >&2
  echo -e "${RED}opencode-tor necesita docker para el contenedor Tor. Instálalo (p. ej. 'sudo apt install docker.io') y reintenta.${NC}" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo -e "${RED}Error: el daemon de docker no responde (¿arrancado? ¿tu usuario en el grupo docker?).${NC}" >&2
  exit 1
fi
if ! command -v bun >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
  echo -e "${RED}Error: ni bun ni npm disponibles; se necesita uno para instalar las dependencias del plugin.${NC}" >&2
  exit 1
fi

PLUGIN_B64='__PLUGIN_B64__'
WRAPPER_B64='__WRAPPER_B64__'
UNINSTALL_B64='__UNINSTALL_B64__'
REFRESH_B64='__REFRESH_B64__'
TUI_LOGO_B64='__TUI_LOGO_B64__'
TORRC_B64='__TORRC_B64__'
ART_B64='__ART_B64__'
DAEMON_B64='__DAEMON_B64__'

PLUGIN_OUT="$INSTALL_DIR/plugins/ip-rotate"
mkdir -p "$PLUGIN_OUT"
echo "$PLUGIN_B64" | base64 -d | tar -xzf - -C "$PLUGIN_OUT"

# Reescribir la dep workspace por una versión npm y resolverla.
sed 's#"@opencode-ai/plugin": "workspace:\*"#"@opencode-ai/plugin": "latest"#' "$PLUGIN_OUT/package.json" > "$PLUGIN_OUT/package.json.tmp" && mv "$PLUGIN_OUT/package.json.tmp" "$PLUGIN_OUT/package.json"
if command -v bun >/dev/null 2>&1; then
  (cd "$PLUGIN_OUT" && bun install --no-save >/dev/null 2>&1)
elif command -v npm >/dev/null 2>&1; then
  echo -e "${ORANGE}Warning: bun no disponible, usando npm como fallback${NC}" >&2
  (cd "$PLUGIN_OUT" && npm install --no-save >/dev/null 2>&1)
fi

# --- 3. Tor control password + torrc ---
gen_password() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16
  else od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; fi
}
hash_password() {
  local pass="$1"
  if command -v tor >/dev/null 2>&1; then
    tor --hash-password "$pass" 2>/dev/null | tail -1
  elif docker info >/dev/null 2>&1; then
    docker run --rm --entrypoint tor dperson/torproxy --hash-password "$pass" 2>/dev/null | tail -1
  else
    echo "ERROR_NO_TOR"
  fi
}

CONTROL_PASSWORD="$(gen_password)"
HASH="$(hash_password "$CONTROL_PASSWORD" || true)"
if [ "$HASH" = "ERROR_NO_TOR" ] || [ -z "$HASH" ]; then
  echo -e "${RED}Error: no se pudo generar el hash de Tor (instala tor o docker)${NC}"
  exit 1
fi

echo "$TORRC_B64" | base64 -d > "$INSTALL_DIR/torrc"
sed "s|^HashedControlPassword .*|HashedControlPassword $HASH|" "$INSTALL_DIR/torrc" > "$INSTALL_DIR/torrc.tmp" && mv "$INSTALL_DIR/torrc.tmp" "$INSTALL_DIR/torrc"

# --- 4. opencode.json ---
# Provider local opcional: si hay un llama.cpp/OpenAI-compatible sirviendo en
# 127.0.0.1:8080 (o el modelo GGUF descargado), se registra `local/qwen36`.
# Condicional para que el instalador siga siendo genérico en otras máquinas.
LOCAL_PROVIDER=""
if curl -s --max-time 2 http://127.0.0.1:8080/health >/dev/null 2>&1 || [ -f "$HOME/llamacpp/models/qwen3.6/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf" ]; then
  LOCAL_PROVIDER=',
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Qwen3.6",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": { "qwen36": { "name": "Qwen3.6 35B-A3B (local)", "tool_call": true } }
    }
  }'
fi
cat > "$INSTALL_DIR/opencode.json" <<JSON
{
  "plugin": [["file://$INSTALL_DIR/plugins/ip-rotate", { "controlPassword": "$CONTROL_PASSWORD" }]]$LOCAL_PROVIDER
}
JSON
chmod 600 "$INSTALL_DIR/torrc" "$INSTALL_DIR/opencode.json"

# --- 5. wrapper ---
# Todas las escrituras en bin/ van por temporal + mv: si hay un opencode-tor en
# ejecución, sobrescribir in-place falla (ETXTBSY) o corrompe el script vivo.
echo "$WRAPPER_B64" | base64 -d > "$INSTALL_DIR/bin/opencode-tor.tmp" && mv "$INSTALL_DIR/bin/opencode-tor.tmp" "$INSTALL_DIR/bin/opencode-tor"
chmod 755 "$INSTALL_DIR/bin/opencode-tor"

# --- 5b. uninstaller ---
echo "$UNINSTALL_B64" | base64 -d > "$INSTALL_DIR/bin/uninstall-opencode-tor.sh.tmp" && mv "$INSTALL_DIR/bin/uninstall-opencode-tor.sh.tmp" "$INSTALL_DIR/bin/uninstall-opencode-tor.sh"
chmod 755 "$INSTALL_DIR/bin/uninstall-opencode-tor.sh"

# --- 5d. ip-refresh: rotación manual NEWNYM + prueba contra Zen ---
echo "$REFRESH_B64" | base64 -d > "$INSTALL_DIR/bin/ip-refresh.sh.tmp" && mv "$INSTALL_DIR/bin/ip-refresh.sh.tmp" "$INSTALL_DIR/bin/ip-refresh.sh"
chmod 755 "$INSTALL_DIR/bin/ip-refresh.sh"
mkdir -p "$INSTALL_DIR/xdg/config/opencode/command"
cat > "$INSTALL_DIR/xdg/config/opencode/command/ip-refresh.md" <<CMD_EOF
---
description: Rota la IP de salida Tor (NEWNYM) hasta encontrar un exit sin rate limit
agent: build
---

Ejecuta en bash el script \`$INSTALL_DIR/bin/ip-refresh.sh\` (acepta como
argumentos opcionales el modelo a probar y el máximo de intentos; por defecto
big-pickle y 10). Resume el resultado: la IP de salida final y si quedó limpia
o agotó los intentos. Si encontró un exit limpio, indica al usuario que ya
puede reintentar su prompt con normalidad.
CMD_EOF

# --- 5c. logo TUI ---
echo "$TUI_LOGO_B64" | base64 -d > "$PLUGIN_OUT/tui-logo.tsx"

mkdir -p "$PLUGIN_OUT/art"
echo "$ART_B64" | base64 -d > "$PLUGIN_OUT/art/opencode-tor.txt"
cat > "$INSTALL_DIR/tui.json" <<JSON
{
  "plugin": ["./plugins/ip-rotate/tui-logo.tsx"]
}
JSON

# --- 5e. exit-sweep daemon ---
echo "$DAEMON_B64" | base64 -d > "$PLUGIN_OUT/exit-sweep-daemon.py"
chmod 755 "$PLUGIN_OUT/exit-sweep-daemon.py"

# --- 6. PATH ---
add_to_path() {
  local config_file="$1" command="$2"
  if grep -Fxq "$command" "$config_file"; then return 0; fi
  if [ -w "$config_file" ]; then
    echo -e "\n# opencode-tor" >> "$config_file"
    echo "$command" >> "$config_file"
    echo -e "${MUTED}Added opencode-tor to \$PATH in ${NC}$config_file"
  else
    echo -e "${ORANGE}Manually add: ${NC}$command"
  fi
}

if [ "$no_modify_path" = "false" ] && [[ ":$PATH:" != *":$INSTALL_DIR/bin:"* ]]; then
  current_shell=$(basename "$SHELL")
  config_file=""
  path_cmd=""
  case "$current_shell" in
    fish) config_file="$HOME/.config/fish/config.fish" ;;
    zsh) config_file="$HOME/.zshrc" ;;
    *) config_file="$HOME/.bashrc" ;;
  esac
  case "$current_shell" in
    fish) path_cmd="fish_add_path $INSTALL_DIR/bin" ;;
    *) path_cmd="export PATH=$INSTALL_DIR/bin:\$PATH" ;;
  esac
  [ -f "$config_file" ] || config_file=""
  if [ -n "$config_file" ]; then
    add_to_path "$config_file" "$path_cmd"
  else
    echo -e "${ORANGE}No shell config found; add manually: $path_cmd${NC}"
  fi
fi

echo ""
echo -e "${MUTED}Instalado en ${NC}$INSTALL_DIR"
echo -e "${MUTED}Ejecuta: ${NC}opencode-tor${MUTED} (o ${NC}$INSTALL_DIR/bin/opencode-tor${MUTED} si PATH no está actualizado)${NC}"
echo -e "${MUTED}Desinstala: ${NC}$INSTALL_DIR/bin/uninstall-opencode-tor.sh"
echo ""
INSTALLER_EOF

# Sustituir los payloads en el instalador generado.
sed 's|__PLUGIN_B64__|'"$PLUGIN_B64"'|; s|__WRAPPER_B64__|'"$WRAPPER_B64"'|; s|__UNINSTALL_B64__|'"$UNINSTALL_B64"'|; s|__REFRESH_B64__|'"$REFRESH_B64"'|; s|__TUI_LOGO_B64__|'"$TUI_LOGO_B64"'|; s|__ART_B64__|'"$ART_B64"'|; s|__DAEMON_B64__|'"$DAEMON_B64"'|; s|__TORRC_B64__|'"$TORRC_B64"'|' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
chmod 755 "$OUT"
echo "generado: $OUT"
