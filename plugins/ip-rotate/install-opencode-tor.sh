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
  (cd "$PLUGIN_OUT" && npm install --no-save >/dev/null 2>&1)
else
  echo -e "${ORANGE}Warning: ni bun ni npm disponibles; el plugin puede fallar al cargar${NC}" >&2
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
