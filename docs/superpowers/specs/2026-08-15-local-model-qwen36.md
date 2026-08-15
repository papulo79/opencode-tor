# Modelo local Qwen3.6-35B-A3B con llama.cpp (runbook)

Fecha: 2026-08-15. Host: ASUS TUF F15 (RTX 4070 Laptop 8 GB VRAM, 30 GB RAM, i7-13620H).

## Piezas

- **llama.cpp**: `~/llamacpp` (build CUDA del 2026-07-23, binarios en `~/llamacpp/build/bin/`).
- **Modelo**: `Qwen3.6-35B-A3B` (MoE, ~3B activos), quant `Q4_K_M` (~22 GB),
  descargado de `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` a
  `~/llamacpp/models/qwen3.6/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf`.

## Arranque del servidor

Requisito: **~22 GB de RAM libres** (cerrar navegador/apps pesadas antes). Los
expertos MoE van a RAM (`--n-cpu-moe 999`) y la GPU solo carga atención +
experto compartido (~4 GB VRAM, queda margen para el escritorio).

```bash
~/llamacpp/build/bin/llama-server \
  -m ~/llamacpp/models/qwen3.6/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf \
  -ngl 99 --n-cpu-moe 999 --flash-attn \
  -c 32768 -t 8 \
  --host 127.0.0.1 --port 8080
```

- `-ngl 99`: sube a GPU todo lo que quepa.
- `--n-cpu-moe 999`: expertos MoE en CPU/RAM (clave para 8 GB VRAM).
- `-c 32768`: contexto 32K (subible; más contexto = más RAM/VRAM).
- `-t 8`: 8 hilos (deja 2 núcleos libres al sistema).

Verificación:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen36","messages":[{"role":"user","content":"di hola"}],"max_tokens":32}'
```

Velocidad esperada: ~10-15 tok/s. Servicio permanente: systemd user unit
`llama-qwen36.service` (enabled, con linger — arranca tras reinicio;
gestionar con `systemctl --user restart llama-qwen36`).

## Integración con opencode(-tor)

Ollama no hace falta: `llama-server` expone API OpenAI-compatible en
`http://127.0.0.1:8080/v1`. En el config (`~/.opencode-tor/opencode.json` o el
global), provider custom:

```json
{
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Qwen3.6",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": { "qwen36": { "name": "Qwen3.6 35B-A3B (local)" } }
    }
  }
}
```

Selección: `local/qwen36` en el TUI (`ctrl+p` → modelos) o `-m local/qwen36`.

## Uso previsto

- **Fallback ilimitado**: cuando Zen (u otro provider cloud) agote cuota, el
  modelo local no tiene límite de tokens. El plugin ip-rotate podrá hacer
  fallback de modelo a `local/qwen36` tras agotar `probeMaxAttempts` (pendiente
  de implementar).
- También usable directamente como modelo principal para trabajo offline.

## Notas

- El barrido de exits Tor (`sweep-exits.py`) y este servidor comparten CPU;
  para benchmarking del modelo, parar el barrido antes.
- Si el build de llama.cpp queda viejo para futuros modelos:
  `cd ~/llamacpp && git pull && cmake --build build -j --target llama-server`.
