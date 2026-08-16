#!/usr/bin/env bash
set -euo pipefail

# ip-refresh: rota la IP de salida Tor (NEWNYM) y prueba el endpoint de Zen
# hasta encontrar un exit no limitado. Uso: ip-refresh.sh [modelo] [max-intentos]
# No consume tokens de ningún modelo: todo es curl + puerto de control de Tor.

OPENCODE_TOR_DIR="${OPENCODE_TOR_DIR:-$HOME/.opencode-tor}"
MODEL="${1:-big-pickle}"
MAX="${2:-10}"
PROXY="http://127.0.0.1:8118"
CONTROL_PORT=9051
NEWNYM_DELAY=12 # Tor rechaza NEWNYM con menos de ~10 s entre señales

PASS=$(grep -o '"controlPassword": *"[^"]*"' "$OPENCODE_TOR_DIR/opencode.json" | cut -d'"' -f4 || true)
if [ -z "${PASS:-}" ]; then
  echo "ip-refresh: no encuentro controlPassword en $OPENCODE_TOR_DIR/opencode.json" >&2
  exit 1
fi

newnym() {
  exec 3<>"/dev/tcp/127.0.0.1/$CONTROL_PORT"
  printf 'AUTHENTICATE "%s"\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$PASS" >&3
  local reply
  reply=$(head -c 256 <&3 || true)
  exec 3<&- 3>&-
  case "$reply" in
    *"250 OK"*) return 0 ;;
    *) echo "ip-refresh: NEWNYM rechazado: $reply" >&2; return 1 ;;
  esac
}

current_ip() { curl -s --max-time 20 --proxy "$PROXY" https://api.ipify.org 2>/dev/null || echo "?"; }

probe() {
  local body
  body=$(curl -s --max-time 45 --proxy "$PROXY" https://opencode.ai/zen/v1/chat/completions \
    -H "Authorization: Bearer public" -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"di hola\"}],\"max_tokens\":8}" 2>/dev/null || true)
  case "$body" in
    *FreeUsageLimitError*|*"Rate limit"*|*"Too Many"*) return 1 ;;
    *'"chat.completion"'*) return 0 ;;
    *) echo "ip-refresh: respuesta inesperada: ${body:0:120}" >&2; return 1 ;;
  esac
}

echo "ip-refresh: modelo=$MODEL max=$MAX (proxied via $PROXY)"
for attempt in $(seq 0 "$MAX"); do
  ip=$(current_ip)
  if probe; then
    echo "ip-refresh: exit limpio encontrado en intento $attempt: $ip"
    exit 0
  fi
  if [ "$attempt" -eq "$MAX" ]; then break; fi
  echo "ip-refresh: intento $attempt: $ip limitado, rotando..."
  newnym
  sleep "$NEWNYM_DELAY"
done
echo "ip-refresh: sin exits limpios tras $((MAX + 1)) intentos" >&2
exit 1
