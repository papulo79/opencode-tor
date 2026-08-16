#!/usr/bin/env bash
set -euo pipefail

APP=opencode-tor
INSTALL_DIR="${OPENCODE_TOR_DIR:-$HOME/.opencode-tor}"
CONTAINER="${OPENCODE_TOR_CONTAINER:-ip-rotate-tor}"
MUTED='\033[0;2m'; RED='\033[0;31m'; ORANGE='\033[38;5;214m'; NC='\033[0m'

usage() {
  cat <<EOF
OpenCode-Tor Uninstaller

Usage: uninstall-opencode-tor.sh [options]

Options:
    -h, --help      Show this help
    -y, --yes       Skip the confirmation prompt

Removes:
    - $INSTALL_DIR (binario opencode, plugin, torrc, opencode.json, wrapper)
    - La línea de PATH de .bashrc/.zshrc/config.fish (si existe)
    - El contenedor docker $CONTAINER (si existe)
EOF
}

assume_yes=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) assume_yes=true; shift ;;
    *) echo -e "${ORANGE}Warning: unknown option '$1'${NC}" >&2; shift ;;
  esac
done

if [ "$assume_yes" = "false" ]; then
  echo -e "Se eliminará: ${RED}$INSTALL_DIR${NC} (instalación opencode-tor), su línea de PATH y el contenedor ${RED}$CONTAINER${NC}."
  read -r -p "¿Continuar? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo -e "${MUTED}Cancelado.${NC}"; exit 0 ;;
  esac
fi

# --- 1. Contenedor docker ---
if command -v docker >/dev/null 2>&1 && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "uninstall-opencode-tor: eliminando contenedor $CONTAINER"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || echo -e "${ORANGE}No se pudo eliminar el contenedor (¿docker daemon activo?)${NC}"
fi

# --- 2. Línea de PATH de los configs de shell ---
remove_path_line() {
  local config_file="$1"
  [ -f "$config_file" ] || return 0
  if ! grep -q "# opencode-tor" "$config_file"; then return 0; fi
  # Quitar el comentario y la línea de PATH que añadió el instalador.
  grep -v -e "^# opencode-tor$" -e "^export PATH=$INSTALL_DIR/bin:" -e "^fish_add_path $INSTALL_DIR/bin$" \
    "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
  echo -e "${MUTED}Línea opencode-tor eliminada de ${NC}$config_file"
}

remove_path_line "$HOME/.bashrc"
remove_path_line "$HOME/.zshrc"
remove_path_line "$HOME/.config/fish/config.fish"

# --- 3. Directorio de instalación ---
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  echo -e "${MUTED}Eliminado ${NC}$INSTALL_DIR"
else
  echo -e "${MUTED}No existía $INSTALL_DIR${NC}"
fi

echo -e ""
echo -e "${MUTED}opencode-tor desinstalado. Abre una terminal nueva (o ejecuta ${NC}source ~/.bashrc${MUTED}) para refrescar PATH.${NC}"
