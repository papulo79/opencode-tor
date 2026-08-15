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

PLUGIN_B64='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'
WRAPPER_B64='IyEvdXNyL2Jpbi9lbnYgYmFzaApzZXQgLWV1byBwaXBlZmFpbAoKT1BFTkNPREVfVE9SX0RJUj0iJHtPUEVOQ09ERV9UT1JfRElSOi0kSE9NRS8ub3BlbmNvZGUtdG9yfSIKT1BFTkNPREVfVE9SX0JJTj0iJHtPUEVOQ09ERV9UT1JfQklOOi0kT1BFTkNPREVfVE9SX0RJUi9iaW4vb3BlbmNvZGV9IgpPUEVOQ09ERV9UT1JfSU1BR0U9IiR7T1BFTkNPREVfVE9SX0lNQUdFOi1kcGVyc29uL3RvcnByb3h5fSIKT1BFTkNPREVfVE9SX0NPTlRBSU5FUj0iJHtPUEVOQ09ERV9UT1JfQ09OVEFJTkVSOi1pcC1yb3RhdGUtdG9yfSIKT1BFTkNPREVfVE9SX1RPUlJDPSIkT1BFTkNPREVfVE9SX0RJUi90b3JyYyIKT1BFTkNPREVfVE9SX0NPTkZJRz0iJE9QRU5DT0RFX1RPUl9ESVIvb3BlbmNvZGUuanNvbiIKUkVBRFlfVElNRU9VVD0iJHtPUEVOQ09ERV9UT1JfUkVBRFlfVElNRU9VVDotOTB9IgpIVFRQX1RVTk5FTF9QT1JUPTgxMTgKU09DS1NfUE9SVD05MDUwCgppZiBbICEgLXggIiRPUEVOQ09ERV9UT1JfQklOIiBdOyB0aGVuCiAgZWNobyAib3BlbmNvZGUtdG9yOiBiaW5hcmlvIG5vIGVuY29udHJhZG86ICRPUEVOQ09ERV9UT1JfQklOIChlamVjdXRhIGVsIGluc3RhbGFkb3IgcHJpbWVybykiID4mMgogIGV4aXQgMQpmaQppZiBbICEgLWYgIiRPUEVOQ09ERV9UT1JfVE9SUkMiIF0gfHwgWyAhIC1mICIkT1BFTkNPREVfVE9SX0NPTkZJRyIgXTsgdGhlbgogIGVjaG8gIm9wZW5jb2RlLXRvcjogZmFsdGEgdG9ycmMgbyBvcGVuY29kZS5qc29uIGVuICRPUEVOQ09ERV9UT1JfRElSIChyZWluc3RhbGEpIiA+JjIKICBleGl0IDEKZmkKaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICBlY2hvICJvcGVuY29kZS10b3I6IGRvY2tlciBubyBlc3TDoSBpbnN0YWxhZG8iID4mMgogIGV4aXQgMQpmaQoKc3RhcnRfdG9yKCkgewogIGxvY2FsIHJ1bm5pbmcKICBzdGFydGVkX2J5X3VzPTAKICBydW5uaW5nPSQoZG9ja2VyIGluc3BlY3QgLWYgJ3t7LlN0YXRlLlJ1bm5pbmd9fScgIiRPUEVOQ09ERV9UT1JfQ09OVEFJTkVSIiAyPi9kZXYvbnVsbCB8fCBlY2hvICIiKQogIGlmIFsgIiRydW5uaW5nIiA9ICJ0cnVlIiBdOyB0aGVuCiAgICBlY2hvICJvcGVuY29kZS10b3I6IGNvbnRlbmVkb3IgVG9yIHlhIGNvcnJpZW5kbyIKICAgIHJldHVybiAwCiAgZmkKICBlY2hvICJvcGVuY29kZS10b3I6IGFycmFuY2FuZG8gY29udGVuZWRvciBUb3IgKCRPUEVOQ09ERV9UT1JfSU1BR0UpLi4uIgogIGlmIGRvY2tlciBpbnNwZWN0ICIkT1BFTkNPREVfVE9SX0NPTlRBSU5FUiIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBkb2NrZXIgc3RhcnQgIiRPUEVOQ09ERV9UT1JfQ09OVEFJTkVSIiA+L2Rldi9udWxsCiAgICBzdGFydGVkX2J5X3VzPTEKICBlbHNlCiAgICBkb2NrZXIgcnVuIC1kIC0tcm0gLS1uZXR3b3JrIGhvc3QgLS1uYW1lICIkT1BFTkNPREVfVE9SX0NPTlRBSU5FUiIgXAogICAgICAtdiAiJE9QRU5DT0RFX1RPUl9UT1JSQzovdG1wL3RvcnJjOnJvIiBcCiAgICAgIC0tZW50cnlwb2ludCB0b3IgIiRPUEVOQ09ERV9UT1JfSU1BR0UiIC1mIC90bXAvdG9ycmMgPi9kZXYvbnVsbAogICAgc3RhcnRlZF9ieV91cz0xCiAgZmkKfQoKcG9ydF9vcGVuKCkgewogIGxvY2FsIHBvcnQ9IiQxIgogIGlmIGNvbW1hbmQgLXYgbmMgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBuYyAteiAxMjcuMC4wLjEgIiRwb3J0IiAyPi9kZXYvbnVsbAogIGVsc2UKICAgIGJhc2ggLWMgImV4ZWMgMzw+L2Rldi90Y3AvMTI3LjAuMC4xLyRwb3J0IiAyPi9kZXYvbnVsbAogIGZpCn0KCndhaXRfcmVhZHkoKSB7CiAgbG9jYWwgZWxhcHNlZD0wCiAgZWNobyAtbiAib3BlbmNvZGUtdG9yOiBlc3BlcmFuZG8gYSBUb3IiCiAgd2hpbGUgWyAiJGVsYXBzZWQiIC1sdCAiJFJFQURZX1RJTUVPVVQiIF07IGRvCiAgICBpZiBwb3J0X29wZW4gIiRTT0NLU19QT1JUIiAmJiBwb3J0X29wZW4gIiRIVFRQX1RVTk5FTF9QT1JUIjsgdGhlbgogICAgICBlY2hvICIgbGlzdG8gKCRlbGFwc2VkIHMpIgogICAgICByZXR1cm4gMAogICAgZmkKICAgIHNsZWVwIDIKICAgIGVsYXBzZWQ9JCgoZWxhcHNlZCArIDIpKQogICAgZWNobyAtbiAiLiIKICBkb25lCiAgZWNobyAiIFRJTUVPVVQgdHJhcyAke1JFQURZX1RJTUVPVVR9cyIgPiYyCiAgZG9ja2VyIGxvZ3MgIiRPUEVOQ09ERV9UT1JfQ09OVEFJTkVSIiAyPiYxIHwgdGFpbCAtNSA+JjIKICByZXR1cm4gMQp9CgpzdG9wX3RvcigpIHsKICBpZiBbICIkc3RhcnRlZF9ieV91cyIgIT0gIjEiIF07IHRoZW4gcmV0dXJuIDA7IGZpCiAgaWYgWyAiJHtPUEVOQ09ERV9UT1JfS0VFUDotfSIgPSAiMSIgXTsgdGhlbiByZXR1cm4gMDsgZmkKICBsb2NhbCBvdGhlcnMKICBvdGhlcnM9MAogIGZvciBwaWQgaW4gJChwZ3JlcCAtZiAib3BlbmNvZGUtdG9yIiAyPi9kZXYvbnVsbCB8fCB0cnVlKTsgZG8KICAgIFsgIiRwaWQiID0gIiQkIiBdICYmIGNvbnRpbnVlCiAgICBraWxsIC0wICIkcGlkIiAyPi9kZXYvbnVsbCB8fCBjb250aW51ZQogICAgb3RoZXJzPSQoKG90aGVycyArIDEpKQogIGRvbmUKICBpZiBbICIkb3RoZXJzIiAtZ3QgMCBdOyB0aGVuCiAgICBlY2hvICJvcGVuY29kZS10b3I6IG90cmEgc2VzacOzbiBvcGVuY29kZS10b3Igc2lndWUgYWN0aXZhLCBubyBwYXJvIGVsIGNvbnRlbmVkb3IiCiAgICByZXR1cm4gMAogIGZpCiAgZWNobyAib3BlbmNvZGUtdG9yOiBwYXJhbmRvIGNvbnRlbmVkb3IgVG9yIgogIGRvY2tlciBzdG9wICIkT1BFTkNPREVfVE9SX0NPTlRBSU5FUiIgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKfQoKcHJpbnRfYmFubmVyKCkgewogIGlmIFsgIiR7T1BFTkNPREVfVE9SX05PX0JBTk5FUjotfSIgPSAiMSIgXTsgdGhlbiByZXR1cm4gMDsgZmkKICBsb2NhbCBhcnQ9IiRPUEVOQ09ERV9UT1JfRElSL3BsdWdpbnMvaXAtcm90YXRlL2FydC9vcGVuY29kZS10b3IudHh0IgogIFsgLWYgIiRhcnQiIF0gfHwgcmV0dXJuIDAKICBsb2NhbCBpPTAKICB3aGlsZSBJRlM9IHJlYWQgLXIgbGluZTsgZG8KICAgIGlmIFsgIiRpIiAtZXEgMSBdOyB0aGVuIHByaW50ZiAnXDAzM1swbSVzXDAzM1swbVxuJyAiJGxpbmUiID4mMgogICAgZWxzZSBwcmludGYgJ1wwMzNbMDs5MG0lc1wwMzNbMG1cbicgIiRsaW5lIiA+JjI7IGZpCiAgICBpPSQoKGkgKyAxKSkKICBkb25lIDwgIiRhcnQiCn0KCnRyYXAgc3RvcF90b3IgRVhJVAoKc3RhcnRfdG9yCmlmIFsgIiR7T1BFTkNPREVfVE9SX1NLSVBfUkVBRFk6LX0iICE9ICIxIiBdOyB0aGVuCiAgd2FpdF9yZWFkeQpmaQoKZXhwb3J0IEhUVFBfUFJPWFk9Imh0dHA6Ly8xMjcuMC4wLjE6JEhUVFBfVFVOTkVMX1BPUlQiCmV4cG9ydCBIVFRQU19QUk9YWT0iJEhUVFBfUFJPWFkiCmV4cG9ydCBBTExfUFJPWFk9IiRIVFRQX1BST1hZIgpleHBvcnQgTk9fUFJPWFk9IjEyNy4wLjAuMSxsb2NhbGhvc3QsOjoxIgpleHBvcnQgT1BFTkNPREVfQ09ORklHPSIkT1BFTkNPREVfVE9SX0NPTkZJRyIKZXhwb3J0IE9QRU5DT0RFX1RVSV9DT05GSUc9IiRPUEVOQ09ERV9UT1JfRElSL3R1aS5qc29uIgoKIyBBaXNsYW1pZW50byB0b3RhbDogb3BlbmNvZGUtdG9yIG5vIGNvbXBhcnRlIGNvbmZpZywgZGF0b3MgKGF1dGgpIG5pIGVzdGFkbwojIChtb2RlbG8gc2VsZWNjaW9uYWRvLCBzZXNpb25lcykgY29uIGVsIG9wZW5jb2RlIG5vcm1hbCBkZWwgdXN1YXJpby4KZXhwb3J0IFhER19DT05GSUdfSE9NRT0iJE9QRU5DT0RFX1RPUl9ESVIveGRnL2NvbmZpZyIKZXhwb3J0IFhER19EQVRBX0hPTUU9IiRPUEVOQ09ERV9UT1JfRElSL3hkZy9kYXRhIgpleHBvcnQgWERHX1NUQVRFX0hPTUU9IiRPUEVOQ09ERV9UT1JfRElSL3hkZy9zdGF0ZSIKbWtkaXIgLXAgIiRYREdfQ09ORklHX0hPTUUiICIkWERHX0RBVEFfSE9NRSIgIiRYREdfU1RBVEVfSE9NRSIKCnByaW50X2Jhbm5lcgoiJE9QRU5DT0RFX1RPUl9CSU4iICIkQCIK'
UNINSTALL_B64='IyEvdXNyL2Jpbi9lbnYgYmFzaApzZXQgLWV1byBwaXBlZmFpbAoKQVBQPW9wZW5jb2RlLXRvcgpJTlNUQUxMX0RJUj0iJHtPUEVOQ09ERV9UT1JfRElSOi0kSE9NRS8ub3BlbmNvZGUtdG9yfSIKQ09OVEFJTkVSPSIke09QRU5DT0RFX1RPUl9DT05UQUlORVI6LWlwLXJvdGF0ZS10b3J9IgpNVVRFRD0nXDAzM1swOzJtJzsgUkVEPSdcMDMzWzA7MzFtJzsgT1JBTkdFPSdcMDMzWzM4OzU7MjE0bSc7IE5DPSdcMDMzWzBtJwoKdXNhZ2UoKSB7CiAgY2F0IDw8RU9GCk9wZW5Db2RlLVRvciBVbmluc3RhbGxlcgoKVXNhZ2U6IHVuaW5zdGFsbC1vcGVuY29kZS10b3Iuc2ggW29wdGlvbnNdCgpPcHRpb25zOgogICAgLWgsIC0taGVscCAgICAgIFNob3cgdGhpcyBoZWxwCiAgICAteSwgLS15ZXMgICAgICAgU2tpcCB0aGUgY29uZmlybWF0aW9uIHByb21wdAoKUmVtb3ZlczoKICAgIC0gJElOU1RBTExfRElSIChiaW5hcmlvIG9wZW5jb2RlLCBwbHVnaW4sIHRvcnJjLCBvcGVuY29kZS5qc29uLCB3cmFwcGVyKQogICAgLSBMYSBsw61uZWEgZGUgUEFUSCBkZSAuYmFzaHJjLy56c2hyYy9jb25maWcuZmlzaCAoc2kgZXhpc3RlKQogICAgLSBFbCBjb250ZW5lZG9yIGRvY2tlciAkQ09OVEFJTkVSIChzaSBleGlzdGUpCkVPRgp9Cgphc3N1bWVfeWVzPWZhbHNlCndoaWxlIFtbICQjIC1ndCAwIF1dOyBkbwogIGNhc2UgIiQxIiBpbgogICAgLWh8LS1oZWxwKSB1c2FnZTsgZXhpdCAwIDs7CiAgICAteXwtLXllcykgYXNzdW1lX3llcz10cnVlOyBzaGlmdCA7OwogICAgKikgZWNobyAtZSAiJHtPUkFOR0V9V2FybmluZzogdW5rbm93biBvcHRpb24gJyQxJyR7TkN9IiA+JjI7IHNoaWZ0IDs7CiAgZXNhYwpkb25lCgppZiBbICIkYXNzdW1lX3llcyIgPSAiZmFsc2UiIF07IHRoZW4KICBlY2hvIC1lICJTZSBlbGltaW5hcsOhOiAke1JFRH0kSU5TVEFMTF9ESVIke05DfSAoaW5zdGFsYWNpw7NuIG9wZW5jb2RlLXRvciksIHN1IGzDrW5lYSBkZSBQQVRIIHkgZWwgY29udGVuZWRvciAke1JFRH0kQ09OVEFJTkVSJHtOQ30uIgogIHJlYWQgLXIgLXAgIsK/Q29udGludWFyPyBbeS9OXSAiIGFuc3dlcgogIGNhc2UgIiRhbnN3ZXIiIGluCiAgICB5fFl8eWVzfFlFUykgOzsKICAgICopIGVjaG8gLWUgIiR7TVVURUR9Q2FuY2VsYWRvLiR7TkN9IjsgZXhpdCAwIDs7CiAgZXNhYwpmaQoKIyAtLS0gMS4gQ29udGVuZWRvciBkb2NrZXIgLS0tCmlmIGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgMj4mMSAmJiBkb2NrZXIgaW5zcGVjdCAiJENPTlRBSU5FUiIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgZWNobyAidW5pbnN0YWxsLW9wZW5jb2RlLXRvcjogZWxpbWluYW5kbyBjb250ZW5lZG9yICRDT05UQUlORVIiCiAgZG9ja2VyIHJtIC1mICIkQ09OVEFJTkVSIiA+L2Rldi9udWxsIDI+JjEgfHwgZWNobyAtZSAiJHtPUkFOR0V9Tm8gc2UgcHVkbyBlbGltaW5hciBlbCBjb250ZW5lZG9yICjCv2RvY2tlciBkYWVtb24gYWN0aXZvPykke05DfSIKZmkKCiMgLS0tIDIuIEzDrW5lYSBkZSBQQVRIIGRlIGxvcyBjb25maWdzIGRlIHNoZWxsIC0tLQpyZW1vdmVfcGF0aF9saW5lKCkgewogIGxvY2FsIGNvbmZpZ19maWxlPSIkMSIKICBbIC1mICIkY29uZmlnX2ZpbGUiIF0gfHwgcmV0dXJuIDAKICBpZiAhIGdyZXAgLXEgIiMgb3BlbmNvZGUtdG9yIiAiJGNvbmZpZ19maWxlIjsgdGhlbiByZXR1cm4gMDsgZmkKICAjIFF1aXRhciBlbCBjb21lbnRhcmlvIHkgbGEgbMOtbmVhIGRlIFBBVEggcXVlIGHDsWFkacOzIGVsIGluc3RhbGFkb3IuCiAgZ3JlcCAtdiAtZSAiXiMgb3BlbmNvZGUtdG9yJCIgLWUgIl5leHBvcnQgUEFUSD0kSU5TVEFMTF9ESVIvYmluOiIgLWUgIl5maXNoX2FkZF9wYXRoICRJTlNUQUxMX0RJUi9iaW4kIiBcCiAgICAiJGNvbmZpZ19maWxlIiA+ICIkY29uZmlnX2ZpbGUudG1wIiAmJiBtdiAiJGNvbmZpZ19maWxlLnRtcCIgIiRjb25maWdfZmlsZSIKICBlY2hvIC1lICIke01VVEVEfUzDrW5lYSBvcGVuY29kZS10b3IgZWxpbWluYWRhIGRlICR7TkN9JGNvbmZpZ19maWxlIgp9CgpyZW1vdmVfcGF0aF9saW5lICIkSE9NRS8uYmFzaHJjIgpyZW1vdmVfcGF0aF9saW5lICIkSE9NRS8uenNocmMiCnJlbW92ZV9wYXRoX2xpbmUgIiRIT01FLy5jb25maWcvZmlzaC9jb25maWcuZmlzaCIKCiMgLS0tIDMuIERpcmVjdG9yaW8gZGUgaW5zdGFsYWNpw7NuIC0tLQppZiBbIC1kICIkSU5TVEFMTF9ESVIiIF07IHRoZW4KICBybSAtcmYgIiRJTlNUQUxMX0RJUiIKICBlY2hvIC1lICIke01VVEVEfUVsaW1pbmFkbyAke05DfSRJTlNUQUxMX0RJUiIKZWxzZQogIGVjaG8gLWUgIiR7TVVURUR9Tm8gZXhpc3TDrWEgJElOU1RBTExfRElSJHtOQ30iCmZpCgplY2hvIC1lICIiCmVjaG8gLWUgIiR7TVVURUR9b3BlbmNvZGUtdG9yIGRlc2luc3RhbGFkby4gQWJyZSB1bmEgdGVybWluYWwgbnVldmEgKG8gZWplY3V0YSAke05DfXNvdXJjZSB+Ly5iYXNocmMke01VVEVEfSkgcGFyYSByZWZyZXNjYXIgUEFUSC4ke05DfSIK'
REFRESH_B64='IyEvdXNyL2Jpbi9lbnYgYmFzaApzZXQgLWV1byBwaXBlZmFpbAoKIyBpcC1yZWZyZXNoOiByb3RhIGxhIElQIGRlIHNhbGlkYSBUb3IgKE5FV05ZTSkgeSBwcnVlYmEgZWwgZW5kcG9pbnQgZGUgWmVuCiMgaGFzdGEgZW5jb250cmFyIHVuIGV4aXQgbm8gbGltaXRhZG8uIFVzbzogaXAtcmVmcmVzaC5zaCBbbW9kZWxvXSBbbWF4LWludGVudG9zXQojIE5vIGNvbnN1bWUgdG9rZW5zIGRlIG5pbmfDum4gbW9kZWxvOiB0b2RvIGVzIGN1cmwgKyBwdWVydG8gZGUgY29udHJvbCBkZSBUb3IuCgpPUEVOQ09ERV9UT1JfRElSPSIke09QRU5DT0RFX1RPUl9ESVI6LSRIT01FLy5vcGVuY29kZS10b3J9IgpNT0RFTD0iJHsxOi1iaWctcGlja2xlfSIKTUFYPSIkezI6LTEwfSIKUFJPWFk9Imh0dHA6Ly8xMjcuMC4wLjE6ODExOCIKQ09OVFJPTF9QT1JUPTkwNTEKTkVXTllNX0RFTEFZPTEyICMgVG9yIHJlY2hhemEgTkVXTllNIGNvbiBtZW5vcyBkZSB+MTAgcyBlbnRyZSBzZcOxYWxlcwoKUEFTUz0kKGdyZXAgLW8gJyJjb250cm9sUGFzc3dvcmQiOiAqIlteIl0qIicgIiRPUEVOQ09ERV9UT1JfRElSL29wZW5jb2RlLmpzb24iIHwgY3V0IC1kJyInIC1mNCB8fCB0cnVlKQppZiBbIC16ICIke1BBU1M6LX0iIF07IHRoZW4KICBlY2hvICJpcC1yZWZyZXNoOiBubyBlbmN1ZW50cm8gY29udHJvbFBhc3N3b3JkIGVuICRPUEVOQ09ERV9UT1JfRElSL29wZW5jb2RlLmpzb24iID4mMgogIGV4aXQgMQpmaQoKbmV3bnltKCkgewogIGV4ZWMgMzw+Ii9kZXYvdGNwLzEyNy4wLjAuMS8kQ09OVFJPTF9QT1JUIgogIHByaW50ZiAnQVVUSEVOVElDQVRFICIlcyJcclxuU0lHTkFMIE5FV05ZTVxyXG5RVUlUXHJcbicgIiRQQVNTIiA+JjMKICBsb2NhbCByZXBseQogIHJlcGx5PSQoaGVhZCAtYyAyNTYgPCYzIHx8IHRydWUpCiAgZXhlYyAzPCYtIDM+Ji0KICBjYXNlICIkcmVwbHkiIGluCiAgICAqIjI1MCBPSyIqKSByZXR1cm4gMCA7OwogICAgKikgZWNobyAiaXAtcmVmcmVzaDogTkVXTllNIHJlY2hhemFkbzogJHJlcGx5IiA+JjI7IHJldHVybiAxIDs7CiAgZXNhYwp9CgpjdXJyZW50X2lwKCkgeyBjdXJsIC1zIC0tbWF4LXRpbWUgMjAgLS1wcm94eSAiJFBST1hZIiBodHRwczovL2FwaS5pcGlmeS5vcmcgMj4vZGV2L251bGwgfHwgZWNobyAiPyI7IH0KCnByb2JlKCkgewogIGxvY2FsIGJvZHkKICBib2R5PSQoY3VybCAtcyAtLW1heC10aW1lIDQ1IC0tcHJveHkgIiRQUk9YWSIgaHR0cHM6Ly9vcGVuY29kZS5haS96ZW4vdjEvY2hhdC9jb21wbGV0aW9ucyBcCiAgICAtSCAiQXV0aG9yaXphdGlvbjogQmVhcmVyIHB1YmxpYyIgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogICAgLWQgIntcIm1vZGVsXCI6XCIkTU9ERUxcIixcIm1lc3NhZ2VzXCI6W3tcInJvbGVcIjpcInVzZXJcIixcImNvbnRlbnRcIjpcImRpIGhvbGFcIn1dLFwibWF4X3Rva2Vuc1wiOjh9IiAyPi9kZXYvbnVsbCB8fCB0cnVlKQogIGNhc2UgIiRib2R5IiBpbgogICAgKkZyZWVVc2FnZUxpbWl0RXJyb3IqfCoiUmF0ZSBsaW1pdCIqfCoiVG9vIE1hbnkiKikgcmV0dXJuIDEgOzsKICAgIConImNoYXQuY29tcGxldGlvbiInKikgcmV0dXJuIDAgOzsKICAgICopIGVjaG8gImlwLXJlZnJlc2g6IHJlc3B1ZXN0YSBpbmVzcGVyYWRhOiAke2JvZHk6MDoxMjB9IiA+JjI7IHJldHVybiAxIDs7CiAgZXNhYwp9CgplY2hvICJpcC1yZWZyZXNoOiBtb2RlbG89JE1PREVMIG1heD0kTUFYIChwcm94aWVkIHZpYSAkUFJPWFkpIgpmb3IgYXR0ZW1wdCBpbiAkKHNlcSAwICIkTUFYIik7IGRvCiAgaXA9JChjdXJyZW50X2lwKQogIGlmIHByb2JlOyB0aGVuCiAgICBlY2hvICJpcC1yZWZyZXNoOiBleGl0IGxpbXBpbyBlbmNvbnRyYWRvIGVuIGludGVudG8gJGF0dGVtcHQ6ICRpcCIKICAgIGV4aXQgMAogIGZpCiAgaWYgWyAiJGF0dGVtcHQiIC1lcSAiJE1BWCIgXTsgdGhlbiBicmVhazsgZmkKICBlY2hvICJpcC1yZWZyZXNoOiBpbnRlbnRvICRhdHRlbXB0OiAkaXAgbGltaXRhZG8sIHJvdGFuZG8uLi4iCiAgbmV3bnltCiAgc2xlZXAgIiRORVdOWU1fREVMQVkiCmRvbmUKZWNobyAiaXAtcmVmcmVzaDogc2luIGV4aXRzIGxpbXBpb3MgdHJhcyAkKChNQVggKyAxKSkgaW50ZW50b3MiID4mMgpleGl0IDEK'
TUI_LOGO_B64='LyoqIEBqc3hJbXBvcnRTb3VyY2UgQG9wZW50dWkvc29saWQgKi8KaW1wb3J0IHsgVGV4dEF0dHJpYnV0ZXMgfSBmcm9tICJAb3BlbnR1aS9jb3JlIgppbXBvcnQgeyByZWFkRmlsZVN5bmMgfSBmcm9tICJub2RlOmZzIgppbXBvcnQgeyBqb2luIH0gZnJvbSAibm9kZTpwYXRoIgppbXBvcnQgdHlwZSB7IFR1aVBsdWdpbiwgVHVpUGx1Z2luTW9kdWxlIH0gZnJvbSAiQG9wZW5jb2RlLWFpL3BsdWdpbi90dWkiCgpjb25zdCBhcnQgPSByZWFkRmlsZVN5bmMoam9pbihpbXBvcnQubWV0YS5kaXIsICJhcnQiLCAib3BlbmNvZGUtdG9yLnR4dCIpLCAidXRmOCIpLnRyaW0oKS5zcGxpdCgiXG4iKQoKY29uc3QgdHVpOiBUdWlQbHVnaW4gPSBhc3luYyAoYXBpKSA9PiB7CiAgYXBpLnNsb3RzLnJlZ2lzdGVyKHsKICAgIHNsb3RzOiB7CiAgICAgIGhvbWVfbG9nbyhjdHgpIHsKICAgICAgICBjb25zdCB7IHRleHQsIHRleHRNdXRlZCB9ID0gY3R4LnRoZW1lLmN1cnJlbnQKICAgICAgICByZXR1cm4gKAogICAgICAgICAgPGJveCBmbGV4RGlyZWN0aW9uPSJjb2x1bW4iPgogICAgICAgICAgICA8dGV4dCBmZz17dGV4dE11dGVkfT57YXJ0WzBdfTwvdGV4dD4KICAgICAgICAgICAgPHRleHQgZmc9e3RleHR9IGF0dHJpYnV0ZXM9e1RleHRBdHRyaWJ1dGVzLkJPTER9PgogICAgICAgICAgICAgIHthcnRbMV19CiAgICAgICAgICAgIDwvdGV4dD4KICAgICAgICAgICAgPHRleHQgZmc9e3RleHRNdXRlZH0+e2FydFsyXX08L3RleHQ+CiAgICAgICAgICA8L2JveD4KICAgICAgICApCiAgICAgIH0sCiAgICB9LAogIH0pCn0KCmNvbnN0IHBsdWdpbjogVHVpUGx1Z2luTW9kdWxlICYgeyBpZDogc3RyaW5nIH0gPSB7CiAgaWQ6ICJvcGVuY29kZS10b3IubG9nbyIsCiAgdHVpLAp9CgpleHBvcnQgZGVmYXVsdCBwbHVnaW4K'
TORRC_B64='U29ja3NQb3J0IDEyNy4wLjAuMTo5MDUwCkhUVFBUdW5uZWxQb3J0IDEyNy4wLjAuMTo4MTE4CkNvbnRyb2xQb3J0IDEyNy4wLjAuMTo5MDUxCkNvb2tpZUF1dGhlbnRpY2F0aW9uIDAKSGFzaGVkQ29udHJvbFBhc3N3b3JkIDE2OjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwCk1heENpcmN1aXREaXJ0aW5lc3MgODY0MDAK'
ART_B64='4paI4paA4paA4paIIOKWiOKWgOKWgOKWiCDilojiloDiloDilogg4paI4paA4paA4paEIOKWiOKWgOKWgOKWgCDilojiloDiloDilogg4paI4paA4paA4paIIOKWiOKWgOKWgOKWiCAgICDiloDilojiloDiloAg4paI4paA4paA4paIIOKWiOKWgOKWgOKWiAriloggIOKWiCDiloggIOKWiCDilojiloDiloDiloAg4paIICDilogg4paIICAgIOKWiCAg4paIIOKWiCAg4paIIOKWiOKWgOKWgOKWgCDiloDiloAgIOKWiCAgIOKWiCAg4paIIOKWiOKWgOKWgOKWhAriloDiloDiloDiloAg4paI4paA4paA4paAIOKWgOKWgOKWgOKWgCDiloAgIOKWgCDiloDiloDiloDiloAg4paA4paA4paA4paAIOKWgOKWgOKWgOKWgCDiloDiloDiloDiloAgICAgIOKWgCAgIOKWgOKWgOKWgOKWgCDiloAgIOKWgAo='

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
