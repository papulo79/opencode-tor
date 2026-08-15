# Diseño: barrido continuo de exits Tor + fallback a modelo local

Fecha: 2026-08-15. Repo: OpenCode (monorepo TypeScript/Bun). Rama base: `ip-rotate-e2e`.
Contexto previo: `specs/ip-rotate.md` (fases 0-4), `docs/superpowers/specs/2026-08-14-opencode-tor-design.md`
(wrapper `opencode-tor`), `docs/superpowers/specs/2026-08-15-local-model-qwen36.md` (runbook del modelo local).

## Contexto

El plugin `plugins/ip-rotate` detecta rate limits del provider `opencode`/Zen y
rota la IP de salida vía Tor (`SIGNAL NEWNYM`). Un hallazgo ya documentado en
`2026-08-14-opencode-tor-design.md` ("Riesgos"): **Zen banea los exits de Tor en
masa** — tras 10+ rotaciones ciegas, casi todas las IPs de salida siguen dando
`FreeUsageLimitError`. La rotación ciega no es suficiente.

Existe además `plugins/ip-rotate/sweep-exits.py`, un script manual que prueba
exits de la lista oficial de Tor (Onionoo) uno a uno contra el endpoint de Zen y
anota el resultado en un JSONL. Y existe un modelo local (`local/qwen36` vía
`llama.cpp`, ver `2026-08-15-local-model-qwen36.md`) sin límite de tokens, ya
instalable condicionalmente por `build-install.sh`, pero sin cablear al plugin.

Este diseño cubre dos mejoras, ambas viviendo fuera de `packages/` (el core que
se sincroniza con upstream), para que sobrevivan a cualquier actualización del
core:

1. **Barrido continuo de exits** en background: en vez de rotar a ciegas y
   esperar, el rotator consulta una lista de exits ya conocidos como buenos.
2. **Fallback a modelo local**: cuando no queda ninguna IP viable, la sesión
   cambia de modelo (Zen → local) en caliente sin perder el historial, y todas
   las sesiones vuelven a intentar Zen automáticamente cuando el límite se
   resetea.

## Objetivos

- Mantener una lista de exits Tor conocidos como "ok" (pasan el endpoint de
  Zen), refrescada automáticamente sin intervención manual.
- El rotator elige un exit conocido-bueno antes que rotar a ciegas.
- Si no queda ningún exit viable y el límite gratuito está agotado, la sesión
  activa sigue funcionando sola cambiando a un modelo local sin límite.
- Cuando el límite de Zen se resetea (dato exacto que Zen ya expone), todas las
  sesiones vuelven a intentar Zen automáticamente.
- Nunca romper la sesión: cualquier fallo de estas dos mejoras se degrada al
  comportamiento actual (rotación ciega / sin fallback).

## Decisiones acordadas

1. Ambas features viven en `plugins/ip-rotate/` (Python para el daemon de
   sweep, TS para el resto), igual que hoy. Nada toca `packages/`.
2. El daemon de sweep se lanza como proceso independiente al arrancar
   `opencode-tor`, sobrevive al cierre de opencode, y termina solo al agotar su
   presupuesto de una pasada (no es un servicio perpetuo).
3. Consulta del rotator al resultado del sweep: lectura directa del JSONL en
   disco. Sin servidor HTTP ni IPC — menos partes móviles, menos recursos.
4. El fallback a local se dispara solo tras agotar rotaciones (conocidas y a
   ciegas) dentro de una sesión, nunca antes.
5. El bloqueo de Zen tras el fallback es **global** (compartido entre
   sesiones), con hora de reset exacta tomada de la cabecera `retry-after` que
   Zen ya devuelve — sin heurísticas de tiempo.
6. `localModel` es opt-in por config; si no está configurado, el
   comportamiento no cambia respecto a hoy.

## Arquitectura

```
plugins/ip-rotate/
├── exit-sweep-daemon.py      # (renombra sweep-exits.py) barrido acotado, se lanza y termina solo
├── src/
│   ├── config.ts             # + localModel?: { providerID, modelID }
│   ├── state.ts               # + zenBlockedUntil, localFallbackSessions (persistido)
│   ├── detector.ts            # + extractRetryAfterMs(event)
│   ├── rotator.ts             # + lee exits-sweep.jsonl antes de NEWNYM ciego
│   └── resumer.ts             # sin cambios de interfaz; se reutiliza tal cual
└── index.ts                   # orquesta: exits conocidos -> ciego -> fallback local -> revert global
```

Estado en disco (`~/.opencode-tor/`, fuera del repo, por proceso/host):

- `exits-sweep.jsonl` — igual que hoy, pero mutable por fingerprint (reescribe
  el registro en vez de solo `append`) + `checked_at` (epoch ms).
- `exit-sweep.lock` — PID del daemon en curso, evita duplicados si se lanza
  `opencode-tor` varias veces.
- `zen-block.json` — `{ "until": <epoch ms> }`, estado global del bloqueo de
  Zen; ausente o `until` pasado = Zen no bloqueado.

## Componente 1 — Daemon de barrido de exits

`exit-sweep-daemon.py` (evolución de `sweep-exits.py`, mismo lenguaje y
mecanismo de control Tor ya validado: `SETCONF ExitNodes=<fp> StrictNodes=1` +
verificación contra el endpoint de Zen).

**Lanzamiento**: el wrapper `opencode-tor` lo lanza con `setsid`/`nohup`
redirigido a un log, desacoplado del proceso padre, justo después de levantar
Tor. Antes de lanzar, comprueba `exit-sweep.lock`: si el PID ahí sigue vivo, no
lanza uno nuevo.

**Presupuesto por pasada**: flags `--budget-minutes N` (default 30) y
`--budget-count N` (default 40), lo que se cumpla primero corta la pasada.
Dentro del presupuesto, orden de prioridad:

1. Re-validar entradas `ok` existentes (son las que usa el rotator ahora
   mismo — si una deja de servir, hay que saberlo cuanto antes).
2. Exits nuevos: diff entre la lista de Onionoo y los fingerprints ya
   conocidos en el JSONL.
3. Re-revisar entradas `limited`/`unreachable` (menor prioridad: ya hay
   alternativas `ok`, esto solo amplía el pool a futuro).

Si se agota el presupuesto a mitad de una categoría, el resto queda para la
siguiente pasada (el siguiente lanzamiento de `opencode-tor`). Al terminar
(presupuesto agotado o cola vacía), el proceso termina y borra el lock.

**Test manual** (documentado en README): lanzar con `--budget-count 3` y
verificar que el JSONL se actualiza y el proceso termina solo.

## Componente 2 — Selección de exit conocido en el rotator

`src/rotator.ts`: antes de rotar a ciegas (comportamiento actual de Fase 2),
lee `exits-sweep.jsonl`, filtra `verdict: "ok"`, ordena por `checked_at`
descendente, descarta el fingerprint en uso actual, y fuerza ese exit vía
`SETCONF ExitNodes=<fp> StrictNodes=1` (mismo puerto de control ya usado).
Verifica con `currentIp()` como hoy. Si el JSONL no existe, está vacío de
`ok`, o el `SETCONF` falla, cae al `NEWNYM` ciego ya implementado — ninguna
ruta nueva puede dejar al rotator sin salida.

## Componente 3 — Fallback a modelo local

**Config** (`src/config.ts`): nueva opción opcional `localModel: { providerID:
string; modelID: string }`. `build-install.sh`, que ya detecta llama.cpp
corriendo en `127.0.0.1:8080` y registra el provider `local` (ver
`2026-08-15-local-model-qwen36.md`), pasa también esta opción al registrar el
plugin en `opencode.json` cuando detecta esa condición — sin paso manual.

**Detección del reset exacto** (`src/detector.ts`): el evento `session.error`
para `FreeUsageLimitError` incluye `error.data.responseHeaders` (schema
`APIError` en `packages/schema/src/v1/session.ts:48-55`). Nueva función
`extractRetryAfterMs(event)` lee `"retry-after-ms"` o, si no está, `"retry-after"`
(segundos) de esas cabeceras. Sin ese dato, se usa un default conservador de
24h (ventana diaria de Zen).

**Estado global** (`src/state.ts`, persistido en `zen-block.json`):
- `isZenBlocked(): boolean` — `Date.now() < zenBlockedUntil`.
- `setZenBlocked(untilMs)` / `clearZenBlocked()`.
- `localFallbackSessions: Set<string>` — sesiones que están en local por este
  mecanismo (para revertirlas cuando el bloqueo expire).

**Flujo en `index.ts`**, al detectar rate limit en una sesión:

1. Si `isZenBlocked()` ya es cierto: no intenta rotar (ya se sabe que Zen está
   caído para todos), va directo al paso 3.
2. Si no, sigue el flujo de rotación existente (Componente 2 → NEWNYM ciego)
   hasta `maxRotationsPerSession`.
3. Si se agotan las rotaciones (o el paso 1 saltó directo aquí) y el error es
   terminal (`FreeUsageLimitError`) y `config.localModel` está seteado:
   a. `until = now + (extractRetryAfterMs(event) ?? 24h)`.
   b. `state.setZenBlocked(until)` + añade `sessionID` a `localFallbackSessions`.
   c. `client.session.switchModel({ sessionID, model: config.localModel })`.
   d. `resumer.resume(sessionID)` (reutiliza `RepromptResumer` tal cual:
      relee el último mensaje de usuario y lo reenvía, ahora contra local).
   e. Programa un `setTimeout(until - now)` global (uno solo activo a la vez;
      si ya hay uno programado para una hora posterior, no se reemplaza) que,
      al cumplirse: `clearZenBlocked()`, y para cada `sessionID` en
      `localFallbackSessions`, `switchModel` de vuelta a Zen (`opencode/big-pickle`
      o el modelo que tuviera la sesión antes del fallback) y limpia el set.
4. Si `config.localModel` no está seteado o el `switchModel`/`resume` falla:
   se degrada al comportamiento actual (la sesión queda en su error original).

**Sesiones nuevas durante el bloqueo**: no hay hook de plugin que intercepte
antes del primer envío a un provider (`chat.params`/`chat.message` no exponen
cambiar el modelo). Una sesión nueva que arranca en Zen durante la ventana de
bloqueo hará un intento, recibirá el mismo error terminal, y el flujo de arriba
(paso 1, directo) la manda a local sin gastar rotaciones — coste: un
round-trip fallido por sesión nueva durante el bloqueo, aceptable y sin tocar
`packages/`.

## Riesgos

- El `setTimeout` de revert vive en memoria del proceso: si se reinicia
  `opencode-tor` antes de que expire, se pierde el timer pero no el estado
  (`zen-block.json` persiste `until`); el siguiente lanzamiento debe releer
  `zen-block.json` al arrancar el plugin y reprogramar el timer restante si
  `until` sigue en el futuro.
- Una pasada de sweep con presupuesto acotado puede tardar varios
  lanzamientos en cubrir toda la red Tor (~1500-2000 exits); es aceptable
  porque el pool `ok` se amplía de forma incremental sin bloquear el uso.
- Si `retry-after` no viene en la respuesta, el default de 24h puede ser
  pesimista (bloquea Zen más tiempo del necesario) — preferible a reintentar
  antes de tiempo y gastar otra rotación fallida.
- El `switchModel` de vuelta a Zen al expirar el bloqueo puede interrumpir una
  sesión en mitad de una tarea en local; se acepta el riesgo (elegido
  explícitamente frente a dejarlo en local indefinidamente).

## Alcance fuera (no en este diseño)

- No se toca `packages/` ni el runtime core de sesiones.
- No se implementa servidor HTTP para consultar el estado del sweep.
- No se reintenta Zen antes de que expire el bloqueo global.
- No se cambia el mecanismo de control de Tor (`SETCONF`/`NEWNYM` via puerto
  9051), ya validado en `specs/ip-rotate.md` y `2026-08-14-opencode-tor-design.md`.
