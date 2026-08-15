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

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/plugins"

# --- 1. opencode binary ---
BIN_FILE="$INSTALL_DIR/bin/opencode"
if [ -n "$binary_path" ]; then
  if [ ! -f "$binary_path" ]; then
    echo -e "${RED}Error: binary not found at $binary_path${NC}"; exit 1
  fi
  cp "$binary_path" "$BIN_FILE"
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
cat > "$INSTALL_DIR/opencode.json" <<JSON
{
  "plugin": [["file://$INSTALL_DIR/plugins/ip-rotate", { "controlPassword": "$CONTROL_PASSWORD" }]]
}
JSON
chmod 600 "$INSTALL_DIR/torrc" "$INSTALL_DIR/opencode.json"

# --- 5. wrapper ---
echo "$WRAPPER_B64" | base64 -d > "$INSTALL_DIR/bin/opencode-tor"
chmod 755 "$INSTALL_DIR/bin/opencode-tor"

# --- 5b. uninstaller ---
echo "$UNINSTALL_B64" | base64 -d > "$INSTALL_DIR/bin/uninstall-opencode-tor.sh"
chmod 755 "$INSTALL_DIR/bin/uninstall-opencode-tor.sh"

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
