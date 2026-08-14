# Diseño: `opencode-tor` — lanzador separado con Tor integrado

Fecha: 2026-08-14. Repo: OpenCode (monorepo TypeScript/Bun). Rama base: `ip-rotate-e2e`
(trabajo previo `specs/ip-rotate.md`).

## Contexto

El plugin `plugins/ip-rotate` (ramas `ip-rotate-*`) detecta rate limits por IP en
los modelos gratuitos (provider `opencode`/Zen) y rota la IP de salida vía Tor.
Para usarlo hoy hay que arrancar Tor a mano, registrar el plugin en el config y
exportar el proxy. Este diseño lo envuelve en un comando global `opencode-tor`,
con su propia copia de opencode y su propio contenedor Tor, totalmente aislado
del opencode normal instalado en `~/.opencode/bin`.

## Objetivos

- Instalar un comando global `opencode-tor` con un mecanismo `curl | bash`
  idéntico al instalador oficial de opencode.
- `opencode-tor` arranca el contenedor docker de Tor, espera readiness, exporta
  el proxy HTTP CONNECT y lanza su propia copia de opencode con el plugin
  `ip-rotate` registrado.
- Al salir, para el contenedor Tor.
- No toca el opencode existente (`~/.opencode/bin`) ni el config global de
  opencode (`~/.config/opencode/`).

## Decisiones acordadas

1. Copia propia separada del binario opencode en `~/.opencode-tor/bin/`.
2. Contenedor Tor docker (`dperson/torproxy`): levantar al arrancar, parar al
   salir. Usa `--network host` (validado en el E2E de `specs/ip-rotate.md`; la
   red del usuario bloquea relays en modo bridge).
3. Password del control de Tor: generado aleatorio al instalar, hash-eado, sin
   fricción para el usuario.
4. Config de opencode dedicado (`~/.opencode-tor/opencode.json`) inyectado por
   `OPENCODE_CONFIG`; no se toca el config global.
5. Instalador autocontenido con el plugin embebido, generado por un script del
   repo (siempre sincronizado con el código del plugin).
6. Instalación del binario: descarga del release oficial de opencode (igual que
   `install`), con soporte `--binary` como fallback local.
7. PATH: añade `~/.opencode-tor/bin` a `.bashrc`/`.zshrc` igual que el instalador
   oficial, con flag `--no-modify-path`.

## Arquitectura

```
~/.opencode-tor/
├── bin/
│   ├── opencode              # copia propia del binario opencode
│   └── opencode-tor          # wrapper ejecutable
├── plugins/
│   └── ip-rotate/            # plugin desplegado (index.ts, src/, package.json, node_modules)
├── torrc                     # puertos 9050/8118/9051 + hash del password aleatorio + MaxCircuitDirtiness 86400
└── opencode.json             # {"plugin": [["file://<abs>/plugins/ip-rotate", {"controlPassword": "<aleatorio>"}]]}
```

### Componente 1 — Generador `plugins/ip-rotate/build-install.sh`

Empaqueta el contenido del plugin (index.ts, src/, package.json, torrc de
referencia) en base64/heredoc y emite `install-opencode-tor.sh` autocontenido.
Ese archivo generado es el que se sirve con `curl ... | bash`.

Nota: el `torrc` desplegado no es el de referencia embebido tal cual; el
instalador reemplaza la línea `HashedControlPassword` con el hash del password
aleatorio generado. El generador solo lo empaqueta como plantilla.

### Componente 2 — Instalador `install-opencode-tor.sh` (generado)

1. Detecta OS/arch (idéntico al `install` del repo: `uname`, musl, baseline,
   arm64, etc.), descarga el binario del release oficial de GitHub
   (`opencode-linux-x64.tar.gz`, etc.) a `~/.opencode-tor/bin/opencode`.
   Soporta `--version` y `--binary` como el instalador oficial.
2. Extrae el plugin embebido a `~/.opencode-tor/plugins/ip-rotate/`.
3. `bun install` en el dir del plugin para resolver `@opencode-ai/plugin`.
4. Genera password aleatorio (`openssl rand -hex 16` o fallback a `/dev/urandom`),
   lo hash-ea con `tor --hash-password` (con fallback a ejecutarlo vía el propio
   contenedor docker si `tor` no está en el host), y escribe `~/.opencode-tor/torrc`.
5. Escribe `~/.opencode-tor/opencode.json` con el plugin registrado
   (`file://<abs>/plugins/ip-rotate`) y `controlPassword`.
6. Instala el wrapper `opencode-tor` en `~/.opencode-tor/bin/` y lo hace ejecutable.
7. Añade `export PATH=$HOME/.opencode-tor/bin:$PATH` a `.bashrc`/`.zshrc`
   (misma lógica que el instalador oficial, incluido `--no-modify-path`).

### Componente 3 — Wrapper `opencode-tor`

Recibe los args que se le pasen (p. ej. sin args para el TUI, o `run "..."`,
`serve`, etc.) y:

1. Si no hay contenedor `ip-rotate-tor` corriendo: `docker run -d --rm --network host`
   con la imagen `dperson/torproxy`, entrypoint `tor`, `-f /tmp/torrc`, montando
   el `~/.opencode-tor/torrc` en modo lectura. También soporta el caso de que el
   contenedor exista parado: `docker start` en vez de `docker run`.
2. Espera readiness: poll a `nc -z 127.0.0.1 9050` y al puerto de túnel HTTP
   `8118`, más un margen de bootstrap de red (reusar la lógica de espera
   validada en el E2E).
3. Exporta `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:8118`,
   `ALL_PROXY=http://127.0.0.1:8118`, `NO_PROXY=127.0.0.1,localhost` y
   `OPENCODE_CONFIG=$HOME/.opencode-tor/opencode.json`.
4. Ejecuta `$HOME/.opencode-tor/bin/opencode` con los args recibidos
   (`exec "$@"`).
5. Al salir del proceso de opencode: `docker stop ip-rotate-tor` (trap en EXIT).
   Como `docker run` usa `--rm`, el contenedor además se elimina al parar.

## Detalles técnicos clave

- **`--network host`** es obligatorio (validado en el E2E de `specs/ip-rotate.md`):
  en modo bridge el host de este usuario no alcanza los relays de Tor
  ("No route to host"). Con `--network host` el bootstrap llega al 100%.
- **Bun 1.3.14 no soporta proxies socks5** en `fetch`. El plugin usa el túnel
  HTTP CONNECT que Tor expone en `HTTPTunnelPort 8118`; por eso el wrapper
  exporta `HTTP_PROXY=http://127.0.0.1:8118`, no `socks5://127.0.0.1:9050`.
- El plugin importa `@opencode-ai/plugin` (`workspace:*` en el repo). En la
  instalación aislada no hay workspace: el instalador ejecuta `bun install` en
  `~/.opencode-tor/plugins/ip-rotate/` para resolver la dep publicada.
- El `HashedControlPassword` del `torrc` debe coincidir con `controlPassword`
  del `opencode.json`; ambos los genera el instalador con el mismo valor.
- `MaxCircuitDirtiness 86400` en el `torrc` mantiene la IP sticky entre bloqueos.

## Flujo de uso

```bash
curl -fsSL https://<host>/install-opencode-tor.sh | bash
opencode-tor                    # TUI con Tor + plugin ip-rotate
opencode-tor run "..."          # run headless con Tor
opencode-tor --version          # delega al binario opencode
```

## Alcance fuera (no en este diseño)

- No se publica el instalador a ningún host/CDN; el usuario sirve/hostea el
  `install-opencode-tor.sh` generado donde quiera.
- No se añade el plugin al config global de opencode.
- No se modifica el instalador oficial `install` del repo.
- No se toca `dev`; el trabajo vive en la rama actual `ip-rotate-e2e` o una
  derivada.

## Riesgos

- `tor --hash-password` requiere el binario `tor`; en hosts sin Tor nativo se
  delega al contenedor docker (`docker run --rm --entrypoint tor dperson/torproxy --hash-password ...`).
- Docker no disponible → `opencode-tor` avisa y sale con error claro.
- El binario opencode y el plugin pueden desincronizarse de versiones; el
  instalador siempre empaqueta el plugin desde el repo en el momento de generar.
