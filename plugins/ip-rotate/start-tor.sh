#!/usr/bin/env bash
set -euo pipefail

PROXY="http://127.0.0.1:8118"
SOCKS_PORT=9050
HTTP_TUNNEL_PORT=8118
CONTROL_PORT=9051
TORRC="${TORRC:-$(dirname "$0")/torrc}"

if ! nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null; then
  if ! command -v tor >/dev/null 2>&1; then
    echo "[ip-rotate] tor no está instalado. Instálalo con: sudo apt install tor (o tu gestor de paquetes)." >&2
    exit 1
  fi
  echo "[ip-rotate] arrancando tor -f $TORRC (socks $SOCKS_PORT, http tunnel $HTTP_TUNNEL_PORT, control $CONTROL_PORT)"
  tor -f "$TORRC" &
  TOR_PID=$!
  trap 'kill "$TOR_PID" 2>/dev/null || true' EXIT

  for i in $(seq 1 30); do
    if nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null; then
    echo "[ip-rotate] tor no respondió en el puerto $SOCKS_PORT" >&2
    exit 1
  fi
  echo "[ip-rotate] tor listo"
else
  echo "[ip-rotate] tor ya estaba escuchando en $SOCKS_PORT"
fi

# Bun 1.3.14 (pin del repo) no soporta proxies socks5 en fetch: solo http(s).
# Tor expone un túnel HTTP CONNECT (HTTPTunnelPort 8118) que Bun sí honra.
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export ALL_PROXY="$PROXY"
# Mantener el servidor interno de opencode (localhost) fuera del proxy.
export NO_PROXY="127.0.0.1,localhost,::1"

exec "$@"
