#!/usr/bin/env bash
set -euo pipefail

# update-opencode-tor: un solo comando para llevar tu instalación local de
# opencode-tor (~/.opencode-tor por defecto) al código actual de este repo.
# Encadena build-install.sh (regenera el instalador desde plugins/ip-rotate/)
# y el instalador resultante (reinstala binario + plugin + wrapper).
#
# Uso: ./plugins/ip-rotate/update-opencode-tor.sh [flags del instalador]
# Ejemplos:
#   ./plugins/ip-rotate/update-opencode-tor.sh                  # último release
#   ./plugins/ip-rotate/update-opencode-tor.sh --version 1.18.20
#   ./plugins/ip-rotate/update-opencode-tor.sh --binary /path/to/opencode

cd "$(dirname "$0")"

echo "update-opencode-tor: regenerando el instalador desde el código del plugin..."
./build-install.sh

echo "update-opencode-tor: reinstalando en \${OPENCODE_TOR_DIR:-\$HOME/.opencode-tor}..."
exec ./install-opencode-tor.sh "$@"
