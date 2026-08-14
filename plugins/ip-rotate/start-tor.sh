#!/usr/bin/env bash
set -euo pipefail

PROXY="socks5h://127.0.0.1:9050"
PORT=9050
CONTROL_PORT=9051
TORRC="${TORRC:-$(dirname "$0")/torrc}"

if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  if ! command -v tor >/dev/null 2>&1; then
    echo "[ip-rotate] tor no está instalado. Instálalo con: sudo apt install tor (o tu gestor de paquetes)." >&2
    exit 1
  fi
  echo "[ip-rotate] arrancando tor -f $TORRC (SOCKS $PORT, control $CONTROL_PORT)"
  tor -f "$TORRC" &
  TOR_PID=$!
  trap 'kill "$TOR_PID" 2>/dev/null || true' EXIT

  for i in $(seq 1 30); do
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "[ip-rotate] tor no respondió en el puerto $PORT" >&2
    exit 1
  fi
  echo "[ip-rotate] tor listo"
else
  echo "[ip-rotate] tor ya estaba escuchando en $PORT"
fi

export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export ALL_PROXY="$PROXY"

exec "$@"
