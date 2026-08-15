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
WRAPPER_B64='IyEvdXNyL2Jpbi9lbnYgYmFzaApzZXQgLWV1byBwaXBlZmFpbAoKT1BFTkNPREVfVE9SX0RJUj0iJHtPUEVOQ09ERV9UT1JfRElSOi0kSE9NRS8ub3BlbmNvZGUtdG9yfSIKT1BFTkNPREVfVE9SX0JJTj0iJHtPUEVOQ09ERV9UT1JfQklOOi0kT1BFTkNPREVfVE9SX0RJUi9iaW4vb3BlbmNvZGV9IgpPUEVOQ09ERV9UT1JfSU1BR0U9IiR7T1BFTkNPREVfVE9SX0lNQUdFOi1kcGVyc29uL3RvcnByb3h5fSIKT1BFTkNPREVfVE9SX0NPTlRBSU5FUj0iJHtPUEVOQ09ERV9UT1JfQ09OVEFJTkVSOi1pcC1yb3RhdGUtdG9yfSIKT1BFTkNPREVfVE9SX1RPUlJDPSIkT1BFTkNPREVfVE9SX0RJUi90b3JyYyIKT1BFTkNPREVfVE9SX0NPTkZJRz0iJE9QRU5DT0RFX1RPUl9ESVIvb3BlbmNvZGUuanNvbiIKUkVBRFlfVElNRU9VVD0iJHtPUEVOQ09ERV9UT1JfUkVBRFlfVElNRU9VVDotOTB9IgpIVFRQX1RVTk5FTF9QT1JUPTgxMTgKU09DS1NfUE9SVD05MDUwCgppZiBbICEgLXggIiRPUEVOQ09ERV9UT1JfQklOIiBdOyB0aGVuCiAgZWNobyAib3BlbmNvZGUtdG9yOiBiaW5hcmlvIG5vIGVuY29udHJhZG86ICRPUEVOQ09ERV9UT1JfQklOIChlamVjdXRhIGVsIGluc3RhbGFkb3IgcHJpbWVybykiID4mMgogIGV4aXQgMQpmaQppZiBbICEgLWYgIiRPUEVOQ09ERV9UT1JfVE9SUkMiIF0gfHwgWyAhIC1mICIkT1BFTkNPREVfVE9SX0NPTkZJRyIgXTsgdGhlbgogIGVjaG8gIm9wZW5jb2RlLXRvcjogZmFsdGEgdG9ycmMgbyBvcGVuY29kZS5qc29uIGVuICRPUEVOQ09ERV9UT1JfRElSIChyZWluc3RhbGEpIiA+JjIKICBleGl0IDEKZmkKaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICBlY2hvICJvcGVuY29kZS10b3I6IGRvY2tlciBubyBlc3TDoSBpbnN0YWxhZG8iID4mMgogIGV4aXQgMQpmaQoKc3RhcnRfdG9yKCkgewogIGxvY2FsIHJ1bm5pbmcKICBzdGFydGVkX2J5X3VzPTAKICBydW5uaW5nPSQoZG9ja2VyIGluc3BlY3QgLWYgJ3t7LlN0YXRlLlJ1bm5pbmd9fScgIiRPUEVOQ09ERV9UT1JfQ09OVEFJTkVSIiAyPi9kZXYvbnVsbCB8fCBlY2hvICIiKQogIGlmIFsgIiRydW5uaW5nIiA9ICJ0cnVlIiBdOyB0aGVuCiAgICBlY2hvICJvcGVuY29kZS10b3I6IGNvbnRlbmVkb3IgVG9yIHlhIGNvcnJpZW5kbyIKICAgIHJldHVybiAwCiAgZmkKICBlY2hvICJvcGVuY29kZS10b3I6IGFycmFuY2FuZG8gY29udGVuZWRvciBUb3IgKCRPUEVOQ09ERV9UT1JfSU1BR0UpLi4uIgogIGlmIGRvY2tlciBpbnNwZWN0ICIkT1BFTkNPREVfVE9SX0NPTlRBSU5FUiIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBkb2NrZXIgc3RhcnQgIiRPUEVOQ09ERV9UT1JfQ09OVEFJTkVSIiA+L2Rldi9udWxsCiAgICBzdGFydGVkX2J5X3VzPTEKICBlbHNlCiAgICBkb2NrZXIgcnVuIC1kIC0tcm0gLS1uZXR3b3JrIGhvc3QgLS1uYW1lICIkT1BFTkNPREVfVE9SX0NPTlRBSU5FUiIgXAogICAgICAtdiAiJE9QRU5DT0RFX1RPUl9UT1JSQzovdG1wL3RvcnJjOnJvIiBcCiAgICAgIC0tZW50cnlwb2ludCB0b3IgIiRPUEVOQ09ERV9UT1JfSU1BR0UiIC1mIC90bXAvdG9ycmMgPi9kZXYvbnVsbAogICAgc3RhcnRlZF9ieV91cz0xCiAgZmkKfQoKcG9ydF9vcGVuKCkgewogIGxvY2FsIHBvcnQ9IiQxIgogIGlmIGNvbW1hbmQgLXYgbmMgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBuYyAteiAxMjcuMC4wLjEgIiRwb3J0IiAyPi9kZXYvbnVsbAogIGVsc2UKICAgIGJhc2ggLWMgImV4ZWMgMzw+L2Rldi90Y3AvMTI3LjAuMC4xLyRwb3J0IiAyPi9kZXYvbnVsbAogIGZpCn0KCndhaXRfcmVhZHkoKSB7CiAgbG9jYWwgZWxhcHNlZD0wCiAgZWNobyAtbiAib3BlbmNvZGUtdG9yOiBlc3BlcmFuZG8gYSBUb3IiCiAgd2hpbGUgWyAiJGVsYXBzZWQiIC1sdCAiJFJFQURZX1RJTUVPVVQiIF07IGRvCiAgICBpZiBwb3J0X29wZW4gIiRTT0NLU19QT1JUIiAmJiBwb3J0X29wZW4gIiRIVFRQX1RVTk5FTF9QT1JUIjsgdGhlbgogICAgICBlY2hvICIgbGlzdG8gKCRlbGFwc2VkIHMpIgogICAgICByZXR1cm4gMAogICAgZmkKICAgIHNsZWVwIDIKICAgIGVsYXBzZWQ9JCgoZWxhcHNlZCArIDIpKQogICAgZWNobyAtbiAiLiIKICBkb25lCiAgZWNobyAiIFRJTUVPVVQgdHJhcyAke1JFQURZX1RJTUVPVVR9cyIgPiYyCiAgZG9ja2VyIGxvZ3MgIiRPUEVOQ09ERV9UT1JfQ09OVEFJTkVSIiAyPiYxIHwgdGFpbCAtNSA+JjIKICByZXR1cm4gMQp9CgpzdG9wX3RvcigpIHsKICBpZiBbICIkc3RhcnRlZF9ieV91cyIgIT0gIjEiIF07IHRoZW4gcmV0dXJuIDA7IGZpCiAgaWYgWyAiJHtPUEVOQ09ERV9UT1JfS0VFUDotfSIgPSAiMSIgXTsgdGhlbiByZXR1cm4gMDsgZmkKICBsb2NhbCBvdGhlcnMKICBvdGhlcnM9MAogIGZvciBwaWQgaW4gJChwZ3JlcCAtZiAib3BlbmNvZGUtdG9yIiAyPi9kZXYvbnVsbCB8fCB0cnVlKTsgZG8KICAgIFsgIiRwaWQiID0gIiQkIiBdICYmIGNvbnRpbnVlCiAgICBraWxsIC0wICIkcGlkIiAyPi9kZXYvbnVsbCB8fCBjb250aW51ZQogICAgb3RoZXJzPSQoKG90aGVycyArIDEpKQogIGRvbmUKICBpZiBbICIkb3RoZXJzIiAtZ3QgMCBdOyB0aGVuCiAgICBlY2hvICJvcGVuY29kZS10b3I6IG90cmEgc2VzacOzbiBvcGVuY29kZS10b3Igc2lndWUgYWN0aXZhLCBubyBwYXJvIGVsIGNvbnRlbmVkb3IiCiAgICByZXR1cm4gMAogIGZpCiAgZWNobyAib3BlbmNvZGUtdG9yOiBwYXJhbmRvIGNvbnRlbmVkb3IgVG9yIgogIGRvY2tlciBzdG9wICIkT1BFTkNPREVfVE9SX0NPTlRBSU5FUiIgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKfQoKcHJpbnRfYmFubmVyKCkgewogIGlmIFsgIiR7T1BFTkNPREVfVE9SX05PX0JBTk5FUjotfSIgPSAiMSIgXTsgdGhlbiByZXR1cm4gMDsgZmkKICBsb2NhbCBhcnQ9IiRPUEVOQ09ERV9UT1JfRElSL3BsdWdpbnMvaXAtcm90YXRlL2FydC9vcGVuY29kZS10b3IudHh0IgogIFsgLWYgIiRhcnQiIF0gfHwgcmV0dXJuIDAKICBsb2NhbCBpPTAKICB3aGlsZSBJRlM9IHJlYWQgLXIgbGluZTsgZG8KICAgIGlmIFsgIiRpIiAtZXEgMSBdOyB0aGVuIHByaW50ZiAnXDAzM1swbSVzXDAzM1swbVxuJyAiJGxpbmUiID4mMgogICAgZWxzZSBwcmludGYgJ1wwMzNbMDs5MG0lc1wwMzNbMG1cbicgIiRsaW5lIiA+JjI7IGZpCiAgICBpPSQoKGkgKyAxKSkKICBkb25lIDwgIiRhcnQiCn0KCnRyYXAgc3RvcF90b3IgRVhJVAoKc3RhcnRfdG9yCmlmIFsgIiR7T1BFTkNPREVfVE9SX1NLSVBfUkVBRFk6LX0iICE9ICIxIiBdOyB0aGVuCiAgd2FpdF9yZWFkeQpmaQoKZXhwb3J0IEhUVFBfUFJPWFk9Imh0dHA6Ly8xMjcuMC4wLjE6JEhUVFBfVFVOTkVMX1BPUlQiCmV4cG9ydCBIVFRQU19QUk9YWT0iJEhUVFBfUFJPWFkiCmV4cG9ydCBBTExfUFJPWFk9IiRIVFRQX1BST1hZIgpleHBvcnQgTk9fUFJPWFk9IjEyNy4wLjAuMSxsb2NhbGhvc3QsOjoxIgpleHBvcnQgT1BFTkNPREVfQ09ORklHPSIkT1BFTkNPREVfVE9SX0NPTkZJRyIKZXhwb3J0IE9QRU5DT0RFX1RVSV9DT05GSUc9IiRPUEVOQ09ERV9UT1JfRElSL3R1aS5qc29uIgoKcHJpbnRfYmFubmVyCiIkT1BFTkNPREVfVE9SX0JJTiIgIiRAIgo='
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
