# opencode-ip-rotate

Plugin para opencode que detecta rate limits por IP en los modelos gratuitos
(provider `opencode`/Zen) y rota la IP de salida a través de Tor.
El alcance es **app-only**: todo el tráfico del proceso opencode sale por el proxy
Tor; el resto del sistema no se ve afectado.

> **Fork note — `opencode-tor`**: este fork añade un lanzador aislado
> (`opencode-tor`) con Tor integrado: rotación de IP ante rate limits de los
> modelos gratuitos, barrido continuo de exits y fallback a modelo local.
> Instalación YOLO (no requiere ningún paso manual):
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/papulo79/opencode-tor/ip-rotate-e2e/plugins/ip-rotate/install-opencode-tor.sh | bash
> ```
>
> Luego ejecuta `opencode-tor`. Requiere `docker` y `bun` (o `npm`) instalados;
> el instalador falla pronto y con mensaje claro si faltan. Todo lo demás
> (contraseña de control de Tor, registro del plugin, provider local si
> procede) se genera y configura solo — ver
> [opencode-tor (lanzador aislado)](#opencode-tor-lanzador-aislado) más abajo. La sección [Desarrollo del plugin](#desarrollo-del-plugin) es solo
> para quien trabaje en el código del plugin dentro de este repo; no hace
> falta para instalar/usar `opencode-tor`.

## opencode-tor (lanzador aislado)

Instala un comando global `opencode-tor` con su propia copia de opencode, su
propio contenedor docker de Tor y el plugin `ip-rotate` ya registrado. No toca
el opencode instalado en `~/.opencode/bin` ni tu config global. **Todo el
proceso es automático**: contraseña de Tor, `opencode.json`, provider local
(si detecta `llama.cpp`) — nada que copiar ni editar a mano.

### Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/papulo79/opencode-tor/ip-rotate-e2e/plugins/ip-rotate/install-opencode-tor.sh | bash
```

O, trabajando desde un checkout del repo:

```bash
# Generar el instalador (solo si has tocado el código del plugin):
./plugins/ip-rotate/build-install.sh

# Ejecutarlo localmente:
./plugins/ip-rotate/install-opencode-tor.sh
```

Flags: `--version <v>`, `--binary <path>`, `--no-modify-path`.

### Desinstalación

El instalador deja un desinstalador en `~/.opencode-tor/bin/uninstall-opencode-tor.sh`:

```bash
uninstall-opencode-tor.sh          # pide confirmación
uninstall-opencode-tor.sh --yes    # sin confirmación
```

Elimina el directorio `~/.opencode-tor/`, la línea de PATH añadida en
`.bashrc`/`.zshrc`/`config.fish` y el contenedor docker `ip-rotate-tor`.

### Uso

```bash
opencode-tor                    # TUI con Tor + plugin ip-rotate
opencode-tor run "..."          # run headless con Tor
```

El wrapper: arranca el contenedor `ip-rotate-tor` (`dperson/torproxy`,
`--network host`), espera readiness, exporta `HTTP_PROXY`/`HTTPS_PROXY`
`=http://127.0.0.1:8118`, inyecta `OPENCODE_CONFIG` + `OPENCODE_TUI_CONFIG` y
ejecuta su binario. Imprime un banner ASCII `opencode-tor` antes del TUI, y un
plugin de TUI sustituye el logo de la home por `opencode-tor` (así sabes que
estás en el entorno Tor). Al salir, para el contenedor. Además lanza en
background el [daemon de barrido de exits](#daemon-de-barrido-de-exits-exit-sweep-daemonpy),
en su propia instancia de Tor aislada.

El entorno es 100% independiente del opencode normal: el wrapper exporta
`XDG_CONFIG_HOME`, `XDG_DATA_HOME` y `XDG_STATE_HOME` bajo
`~/.opencode-tor/xdg/`, así que no comparte config global, sesiones, modelo
seleccionado ni credenciales. La primera vez hay que hacer login:
`opencode-tor auth login`.

El banner del wrapper y el logo de la home del TUI comparten el mismo arte ASCII
en `plugins/ip-rotate/art/opencode-tor.txt` (única fuente). Para rediseñarlo,
solo se edita ese fichero y se regenera el instalador con
`./plugins/ip-rotate/build-install.sh`.

### Limitación conocida: Zen y los exits de Tor

Verificado el 2026-08-15: el provider `opencode` (Zen) devuelve
`FreeUsageLimitError` para **todos** los exits de Tor probados (10+ rotaciones
NEWNYM), mientras que la IP directa del usuario responde con normalidad. Es
decir, Zen bloquea los exits de Tor en masa y la rotación de IP no desbloquea
sus modelos gratuitos por sí sola. El
[barrido continuo de exits](#daemon-de-barrido-de-exits-exit-sweep-daemonpy)
y el [fallback a modelo local](#barrido-de-exits-y-fallback-a-modelo-local)
existen precisamente para cubrir este caso; el mecanismo de rotación en sí
funciona y queda disponible para providers que limiten por IP sin banear Tor.

Para buscar exits no baneados a mano existe `bin/ip-refresh.sh` (también como
comando `/ip-refresh` en el TUI): itera NEWNYM + prueba contra Zen hasta N
intentos sin consumir tokens del modelo. Uso: `ip-refresh.sh [modelo] [max-intentos]`.

### Actualizar tu instalación local

Un solo comando (desde un checkout del repo) regenera el instalador con el
código actual del plugin y lo reaplica a tu `~/.opencode-tor`: descarga el
último binario de opencode publicado y redistribuye el plugin, el wrapper y
el daemon actualizados. No hace falta ningún paso manual ni cerrar sesión
antes salvo que tengas un `opencode-tor` corriendo (el instalador lo detecta
y avisa):

```bash
./plugins/ip-rotate/update-opencode-tor.sh
```

Acepta los mismos flags que el instalador (`--version <v>`, `--binary <path>`,
`--no-modify-path`), por ejemplo para fijar una versión concreta de opencode:

```bash
./plugins/ip-rotate/update-opencode-tor.sh --version 1.18.20
```

Tu login y sesiones (`~/.opencode-tor/xdg/`) no se tocan — solo se
regeneran el binario, `torrc`/`opencode.json` y los ficheros del plugin.

### Personalización

| Variable | Default | Efecto |
| -------- | ------- | ------ |
| `OPENCODE_TOR_DIR` | `$HOME/.opencode-tor` | Directorio de instalación |
| `OPENCODE_TOR_BIN` | `$OPENCODE_TOR_DIR/bin/opencode` | Binario a ejecutar |
| `OPENCODE_TOR_IMAGE` | `dperson/torproxy` | Imagen docker de Tor |
| `OPENCODE_TOR_CONTAINER` | `ip-rotate-tor` | Nombre del contenedor |
| `OPENCODE_TOR_READY_TIMEOUT` | `90` | Timeout de readiness (s) |
| `OPENCODE_TOR_SKIP_READY` | `1` = saltar espera de readiness | Para tests/depuración |
| `OPENCODE_TOR_KEEP` | `1` = no parar al salir | Útil para depuración |
| `OPENCODE_TOR_NO_BANNER` | `1` = no imprimir el banner ASCII | Útil para scripts |
| `EXIT_SWEEP_DAEMON_CMD` | `python3 $OPENCODE_TOR_DIR/plugins/ip-rotate/exit-sweep-daemon.py` | Comando de lanzamiento del daemon de barrido |

### Tests

```bash
plugins/ip-rotate/test/generator.test.sh
plugins/ip-rotate/test/wrapper.test.sh
plugins/ip-rotate/test/uninstall.test.sh
plugins/ip-rotate/test/update.test.sh
cd plugins/ip-rotate && bun test
python3 plugins/ip-rotate/test/sweep-budget.test.py
```

---

## Desarrollo del plugin

Todo lo que sigue es para quien trabaje en el **código del plugin** dentro de
este repo (arrancar `opencode` en modo dev con Tor a mano, entender los
módulos internos, extenderlo). Si solo quieres **usar** `opencode-tor`, no
necesitas nada de esta sección — el instalador de arriba lo hace todo.

> **Desviación técnica documentada del plan (`specs/ip-rotate.md`):**
> El plan asume que el `fetch` de Bun acepta proxies `socks5://` (opción `proxy`
> y variables `HTTP_PROXY`/`HTTPS_PROXY`). **Eso es falso en Bun 1.3.14** (pin del
> repo): todas las variantes socks (`socks`, `socks4`, `socks5`, `socks5h`) lanzan
> `UnsupportedProxyProtocol`, tanto en la opción `proxy` como por variable de
> entorno. Bun solo soporta proxies `http://`/`https://` (HTTP CONNECT).
>
> La adaptación preserva el diseño (tráfico app-only, IP sticky, rotación NEWNYM):
> Tor expone además un **túnel HTTP CONNECT** vía `HTTPTunnelPort 8118`, que Bun
> sí honra. El plugin verifica la IP por ese túnel y rota por el puerto de control
> `9051` (TCP plano, sin cambios). `start-tor.sh` exporta
> `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:8118` + `NO_PROXY=127.0.0.1,localhost,::1`.

### Requisitos (desarrollo)

- Tor instalado en el host: `sudo apt install tor` (Debian/Ubuntu) o tu
  gestor de paquetes. (`opencode-tor`, en cambio, usa Tor en un contenedor
  docker — no necesitas `tor` instalado en el host para eso.)
- Puertos libres: SOCKS `9050`, túnel HTTP `8118`, control `9051`.

### Arrancar opencode en dev con Tor (`start-tor.sh`)

Solo para desarrollar/depurar el plugin directamente en este repo, sin pasar
por `opencode-tor`. Necesita `tor` instalado en el host y un `torrc` con
contraseña de control propia:

```bash
tor --hash-password "mi-password-secreto"
# 16:91735B4CFE9FC57160F90E722114CA372D0C4273BB87263B7199784247  (ejemplo)
```

Copia el hash en `plugins/ip-rotate/torrc`:

```
SocksPort 9050
HTTPTunnelPort 8118
ControlPort 9051
CookieAuthentication 0
HashedControlPassword 16:<TU-HASH>
MaxCircuitDirtiness 86400
```

`MaxCircuitDirtiness 86400` hace que Tor mantenga el mismo circuito (y por tanto
la misma IP de salida) durante 24h, de modo que la IP se mantiene estable entre
bloqueos y solo rota cuando el plugin envía `SIGNAL NEWNYM`.

Registra el plugin en tu `opencode.json` de desarrollo (la ruta se resuelve
relativa al archivo de config):

```json
{
  "plugin": ["./plugins/ip-rotate"]
}
```

> Nota: la forma `file://./plugins/ip-rotate` **no** es válida; el loader de
> plugins falla al resolverla (`File URL host must be "localhost" or empty`).
> Usa la ruta relativa `./plugins/ip-rotate` o una URL absoluta
> `file:///abs/path/plugins/ip-rotate`.

Con opciones:

```json
{
  "plugin": [["file:///abs/path/plugins/ip-rotate", { "controlPassword": "mi-password-secreto" }]]
}
```

Arranca opencode con el proxy Tor activo:

```bash
./plugins/ip-rotate/start-tor.sh bun dev
```

El script:
1. Arranca `tor -f torrc` si el puerto 9050 no responde.
2. Espera readiness.
3. Exporta `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:8118` y `NO_PROXY=127.0.0.1,localhost,::1`.
4. Ejecuta el comando que reciba como argumentos (`bun dev` en este caso).

Cualquier comando que reciba como argumentos se ejecutará bajo el proxy:

```bash
./start-tor.sh curl -s https://api.ipify.org   # IP de salida Tor
```

### Opciones del plugin

| Opción                | Default                         | Descripción                              |
| --------------------- | ------------------------------- | ---------------------------------------- |
| `proxyUrl`            | `http://127.0.0.1:8118`         | Proxy HTTP CONNECT (túnel Tor) de salida |
| `controlPort`         | `9051`                          | Puerto de control de Tor                 |
| `controlPassword`     | `""`                            | Password del control de Tor              |
| `cooldownMs`          | `15000`                         | Mínimo entre rotaciones (NEWNYM ~10s)    |
| `maxRotationsPerSession` | `5`                          | Máximo de rotaciones por sesión          |
| `resume`              | `"reprompt"`                    | Estrategia de reanudación (`"reprompt"` \| `"none"`) |
| `verifyUrl`           | `https://api.ipify.org`         | URL para verificar la IP de salida       |
| `probeUrl`            | `https://opencode.ai/zen/v1/chat/completions` | Endpoint para probar si el exit está limpio |
| `probeModel`          | `big-pickle`                    | Modelo usado en la prueba de exit limpio |
| `probeMaxAttempts`    | `5`                             | Máximo de rotaciones NEWNYM con verificación por bloqueo (~12 s cada una) |
| `errorPatterns`       | `["429", "rate limit", "too many requests", "free limit reached", "free usage exceeded", "overloaded"]` | Patrones que detectan rate limit |
| `terminalErrorPatterns` | `["free limit reached", "free usage exceeded"]` | Subconjunto terminal de `errorPatterns`: solo estos disparan el fallback a `localModel` |

### Barrido de exits y fallback a modelo local

Dos opciones más, pensadas para trabajar juntas con `opencode-tor` (ver
arriba) y documentadas en detalle en
`../../docs/superpowers/specs/2026-08-15-exit-sweep-and-local-fallback.md`:

| Opción         | Default                                    | Descripción                                                    |
| -------------- | ------------------------------------------- | ---------------------------------------------------------------- |
| `exitPoolPath` | `~/.opencode-tor/exits-sweep.jsonl`         | JSONL con exits Tor ya probados contra Zen (`verdict: "ok"`/...) |
| `zenBlockPath` | `~/.opencode-tor/zen-block.json`            | Estado global (`{ "until": <epoch ms> }`) del bloqueo de Zen     |
| `localModel`   | *(sin default, opt-in)*                    | `{ providerID, modelID }` del modelo local de fallback           |

`exitPoolPath` es el fichero que mantiene el daemon de barrido (ver abajo): el
rotator lo lee antes de rotar a ciegas y, si hay un exit `ok` que no sea el
actual, lo fuerza vía `SETCONF ExitNodes=<fp> StrictNodes=1` en vez de un
`NEWNYM` a ciegas. Si el fichero no existe, está vacío o el `SETCONF` falla,
cae al comportamiento de rotación ciega ya existente.

`zenBlockPath` guarda el bloqueo global de Zen (compartido entre sesiones) con
la hora exacta de reset, tomada de la cabecera `retry-after`/`retry-after-ms`
que Zen ya devuelve (o un default conservador de 24h si no viene). Mientras
`Date.now() < until`, ninguna sesión con un error terminal (`terminalErrorPatterns`)
intenta rotar: va directa al fallback local si está configurado. Una sesión con
un error transitorio (429/overloaded) durante ese mismo bloqueo sigue
intentando rotar con normalidad — el bloqueo es sobre Zen en general, pero
rotar la IP de esa sesión puede seguir resolviendo su propio error sin tocar
el modelo local.

`localModel` es opcional (`{ providerID: string; modelID: string }`) y activa
el fallback: cuando se agotan las rotaciones de una sesión (o Zen ya está
bloqueado globalmente) y el error es terminal (`FreeUsageLimitError`), el
plugin reenvía el último prompt de la sesión con `model: localModel`, sin
perder el historial. Cuando el bloqueo de Zen expira, todas las sesiones que
cayeron en fallback vuelven automáticamente a su modelo Zen anterior. Si
`localModel` no está configurado, el comportamiento no cambia respecto a la
rotación normal (la sesión queda en su error original tras agotar rotaciones).

`build-install.sh` configura `localModel` automáticamente cuando detecta un
servidor `llama.cpp` corriendo en `127.0.0.1:8080` (o el GGUF ya descargado):
registra el provider `local` en `opencode.json` y añade
`{ "providerID": "local", "modelID": "qwen36" }` a las opciones del plugin. No
hace falta ningún paso manual; ver el runbook completo del modelo local en
`../../docs/superpowers/specs/2026-08-15-local-model-qwen36.md`.

### Daemon de barrido de exits (`exit-sweep-daemon.py`)

`opencode-tor` lanza `plugins/ip-rotate/exit-sweep-daemon.py` en background al
arrancar (detached vía `setsid`, sobrevive al cierre de opencode), en **su
propia instancia de Tor dedicada y aislada** de la que usa la sesión en vivo
(puertos separados, contenedor docker propio) — así el barrido nunca compite
por el mismo exit que está sirviendo tráfico real de Zen. Hace **una pasada
acotada** por presupuesto, en este orden de prioridad:

1. Revalida los exits ya marcados `"ok"` en `exitPoolPath` (los que usa el
   rotator ahora mismo).
2. Prueba exits nuevos (diff contra la lista de Onionoo).
3. Revisa exits `"limited"`/`"unreachable"`/`"mismatch"`/`"error"` (menor
   prioridad).

Termina solo al agotar el presupuesto o la cola de esa pasada (y para su
propio contenedor Tor dedicado); el siguiente lanzamiento de `opencode-tor`
retoma donde lo dejó (el JSONL es mutable por fingerprint, no solo `append`).
Si ya hay un barrido en curso (PID vivo en `exit-sweep.lock`), no lanza uno
nuevo.

Flags de presupuesto (para invocación manual/standalone; `opencode-tor` los
usa con sus defaults):

```bash
exit-sweep-daemon.py --budget-minutes 30 --budget-count 40
```

- `--budget-minutes N` (default 30) y `--budget-count N` (default 40): lo que
  se cumpla primero corta la pasada.
- `--out PATH` / `--lock PATH`: rutas del JSONL y del lock (`opencode-tor` las
  pasa apuntando a `~/.opencode-tor/`).
- `--control-port N` / `--proxy URL`: puerto de control y proxy de la
  instancia de Tor a usar (`opencode-tor` pasa los de su Tor dedicado de
  barrido; por defecto usa los mismos que la sesión en vivo, 9051/8118, para
  invocaciones manuales sueltas).

La variable de entorno `EXIT_SWEEP_DAEMON_CMD` permite sustituir el comando de
lanzamiento (por ejemplo para tests, o para apuntar a otro intérprete/ruta):

```bash
EXIT_SWEEP_DAEMON_CMD="python3 /ruta/alternativa/exit-sweep-daemon.py" opencode-tor
```

Diseño completo (arquitectura, estado en disco, flujo de fallback y revert) en
`../../docs/superpowers/specs/2026-08-15-exit-sweep-and-local-fallback.md`.

### Rotación con verificación

Al detectar un rate limit, el plugin no reanuda a ciegas: rota la IP y prueba
el endpoint real (`probeUrl`/`probeModel`) a través del nuevo exit, sin gastar
apenas tokens (`max_tokens=8`). Solo reanuda la sesión cuando el exit responde;
si está limitado, rota de nuevo hasta `probeMaxAttempts`. Si agota los
intentos, se mantiene el error original (o cae al modelo local si
`localModel` está configurado y el error es terminal).

### Test manual de rotación

Con el plugin registrado (modo dev, `start-tor.sh`) y Tor levantado, para
verificar la rotación de IP a mano:

```bash
# IP actual (por el túnel HTTP de Tor)
curl -s -x http://127.0.0.1:8118 https://api.ipify.org

# NEWNYM manual
printf 'AUTHENTICATE "mi-password-secreto"\r\nSIGNAL NEWNYM\r\nQUIT\r\n' | nc 127.0.0.1 9051

# Espera y verifica el cambio
sleep 12 && curl -s -x http://127.0.0.1:8118 https://api.ipify.org
```

### Cómo añadir otro Rotator

El plugin está descompuesto en módulos independientes e intercambiables
(`detector`, `rotator`, `resumer`, `state`, `config`). Para rotar por otro medio
(proxies SOCKS5 comerciales, VPN de sistema, etc.) solo hay que sustituir el
**módulo `rotator`**, sin tocar `detector` ni `resumer`:

1. Implementa la interfaz en `src/rotator.ts` (o un fichero nuevo):

   ```ts
   export interface Rotator {
     currentIp(): Promise<string | undefined>
     rotate(): Promise<string | undefined>
   }
   ```

   - `currentIp()` devuelve la IP de salida actual (o `undefined` si no se puede).
   - `rotate()` cambia la IP de salida y devuelve la nueva (o `undefined` si falló).
   - **Nunca lances**: devuelve `undefined` y loguea. Un fallo del rotator degrada
     a un aviso, nunca rompe la sesión.

2. Cambia el factory en `src/rotator.ts`:

   ```ts
   export function createRotator(config: Config): Rotator {
     return new MiRotator(config) // en vez de new TorControlRotator(config)
   }
   ```

3. Añade a `config.ts` las opciones que necesite tu rotator.

Nada del resto del plugin (detección de rate limit, cooldown, contador por
sesión, estrategia de reanudación) cambia.

### Troubleshooting

| Síntoma | Causa probable | Solución |
| ------- | -------------- | -------- |
| "rotación fallida" en los logs | Tor caído, puerto control inaccesible | Verifica `nc -z 127.0.0.1 9050` y `9051`; arranca con `start-tor.sh` (dev) u `opencode-tor` |
| `AUTHENTICATE` rechazado (`515`) | `controlPassword` no coincide con el hash de `torrc` | En dev: regenera el hash (`tor --hash-password`) y actualiza `opencode.json`. Con `opencode-tor`, reinstala — el instalador regenera ambos juntos |
| "IP rotada: X -> X" (misma IP) | NEWNYM no garantiza salida distinta al instante | El plugin reintenta una vez y aplica cooldown; repite la rotación más tarde |
| La IP no cambia nunca / Zen sigue bloqueado | El servicio destino bloquea IPs de salida Tor en masa (ver limitación conocida arriba) | Deja que el daemon de barrido amplíe el pool de exits `ok`, o configura `localModel` para el fallback automático |
| `UnsupportedProxyProtocol` | Bun 1.3.14 no soporta proxies `socks5://` | No uses `socks5://`; el plugin usa el túnel HTTP CONNECT (`HTTPTunnelPort 8118`) |
| Rate limits muy frecuentes (p. ej. `session.status: retry` en bucle) | El cooldown corto deja rotar demasiado | Sube `cooldownMs`; el cooldown global es el cortafuegos |
| Las rotaciones se agotan en una sesión | Se alcanzó `maxRotationsPerSession` | Ajusta el límite, espera a que la sesión pase a `idle` (se resetea el contador), o configura `localModel` |
