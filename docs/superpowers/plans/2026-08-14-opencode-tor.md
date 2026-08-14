# opencode-tor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `opencode-tor`, a separately-installed opencode launcher that manages its own docker Tor container and runs the `ip-rotate` plugin, installable via `curl | bash`.

**Architecture:** A generator script (`plugins/ip-rotate/build-install.sh`) produces a self-contained installer (`install-opencode-tor.sh`) that embeds the plugin + wrapper in base64. The installer downloads the official opencode binary, deploys the plugin, generates a random Tor control password, writes `torrc` + `opencode.json`, and adds `~/.opencode-tor/bin` to PATH. The `opencode-tor` wrapper starts/stops a `dperson/torproxy` docker container (`--network host`), waits for readiness, exports the HTTP CONNECT proxy + `OPENCODE_CONFIG`, and `exec`s its own opencode binary.

**Tech Stack:** Bash (installer/wrapper), docker, `tor --hash-password`, `openssl`, `bun install` (to resolve the plugin's `@opencode-ai/plugin` dep from npm).

---

## Background facts (already verified, do not re-investigate)

- Bun 1.3.14's `fetch` rejects `socks5://` proxies; it only honors `http://`/`https://` (HTTP CONNECT). Tor must expose `HTTPTunnelPort 8118`; the plugin and wrapper use `http://127.0.0.1:8118`.
- `--network host` is required on this user's machine (bridge mode can't reach Tor relays).
- The `ip-rotate` plugin lives at `plugins/ip-rotate/` (index.ts, src/{config,detector,rotator,resumer,state}.ts, package.json, torrc, README.md, test/). The plugin's `package.json` declares `"@opencode-ai/plugin": "workspace:*"` — the installer must rewrite this to an npm version and run `bun install` (fallback `npm install`).
- The official installer (`install`) lives at repo root; its OS/arch detection, release download, `--version`/`--binary` flags, and PATH-append logic are the template to mirror (see `install:1-460`).

## File structure

- Create: `plugins/ip-rotate/opencode-tor` — the wrapper (bash, committed).
- Create: `plugins/ip-rotate/build-install.sh` — generator that emits `install-opencode-tor.sh`.
- Create: `plugins/ip-rotate/test/wrapper.test.sh` — wrapper behavior test with a docker stub.
- Create: `plugins/ip-rotate/test/generator.test.sh` — generator smoke test.
- Create: `plugins/ip-rotate/install-opencode-tor.sh` — committed build output (regenerated, checked in so the design doc's `curl | bash` works from the repo).
- Modify: `plugins/ip-rotate/README.md` — add `opencode-tor` install/usage section.
- The generated installer is written by `build-install.sh`; do NOT hand-edit `install-opencode-tor.sh` — edit `build-install.sh` and regenerate.

All new scripts must pass `bash -n` and, if present, `shellcheck`. No semicolons style does not apply (bash), but keep scripts POSIX-lean (`#!/usr/bin/env bash`, `set -euo pipefail`).

---

### Task 0: Verify baseline

**Files:** none

- [ ] **Step 1: Confirm working state**

Run:
```bash
cd /home/reverendo/Desarrollo/opencode
git branch --show-current        # expect ip-rotate-e2e
bun test                        # from plugins/ip-rotate: expect 13 pass
```

- [ ] **Step 2: Commit (only if clean)**

```bash
git status --short
```

If there are unrelated changes, stash them (`git stash`) before starting.

---

### Task 1: Write the `opencode-tor` wrapper

**Files:**
- Create: `plugins/ip-rotate/opencode-tor`

- [ ] **Step 1: Write the wrapper script**

Write `plugins/ip-rotate/opencode-tor`:

```bash
#!/usr/bin/env bash
set -euo pipefail

OPENCODE_TOR_DIR="${OPENCODE_TOR_DIR:-$HOME/.opencode-tor}"
OPENCODE_TOR_BIN="${OPENCODE_TOR_BIN:-$OPENCODE_TOR_DIR/bin/opencode}"
OPENCODE_TOR_IMAGE="${OPENCODE_TOR_IMAGE:-dperson/torproxy}"
OPENCODE_TOR_CONTAINER="${OPENCODE_TOR_CONTAINER:-ip-rotate-tor}"
OPENCODE_TOR_TORRC="$OPENCODE_TOR_DIR/torrc"
OPENCODE_TOR_CONFIG="$OPENCODE_TOR_DIR/opencode.json"
READY_TIMEOUT="${OPENCODE_TOR_READY_TIMEOUT:-90}"
HTTP_TUNNEL_PORT=8118
SOCKS_PORT=9050

if [ ! -x "$OPENCODE_TOR_BIN" ]; then
  echo "opencode-tor: binario no encontrado: $OPENCODE_TOR_BIN (ejecuta el instalador primero)" >&2
  exit 1
fi
if [ ! -f "$OPENCODE_TOR_TORRC" ] || [ ! -f "$OPENCODE_TOR_CONFIG" ]; then
  echo "opencode-tor: falta torrc o opencode.json en $OPENCODE_TOR_DIR (reinstala)" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "opencode-tor: docker no está instalado" >&2
  exit 1
fi

start_tor() {
  local running
  running=$(docker inspect -f '{{.State.Running}}' "$OPENCODE_TOR_CONTAINER" 2>/dev/null || echo "")
  if [ "$running" = "true" ]; then
    echo "opencode-tor: contenedor Tor ya corriendo"
    return 0
  fi
  echo "opencode-tor: arrancando contenedor Tor ($OPENCODE_TOR_IMAGE)..."
  if docker inspect "$OPENCODE_TOR_CONTAINER" >/dev/null 2>&1; then
    docker start "$OPENCODE_TOR_CONTAINER" >/dev/null
  else
    docker run -d --rm --network host --name "$OPENCODE_TOR_CONTAINER" \
      -v "$OPENCODE_TOR_TORRC:/tmp/torrc:ro" \
      --entrypoint tor "$OPENCODE_TOR_IMAGE" -f /tmp/torrc >/dev/null
  fi
}

wait_ready() {
  local elapsed=0
  echo -n "opencode-tor: esperando a Tor"
  while [ "$elapsed" -lt "$READY_TIMEOUT" ]; do
    if nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null && \
       nc -z 127.0.0.1 "$HTTP_TUNNEL_PORT" 2>/dev/null; then
      # El túnel HTTP responde: considera listo (bootstrap de red puede seguir).
      echo " listo ($elapsed s)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    echo -n "."
  done
  echo " TIMEOUT tras ${READY_TIMEOUT}s" >&2
  docker logs "$OPENCODE_TOR_CONTAINER" 2>&1 | tail -5 >&2
  return 1
}

stop_tor() {
  if [ "${OPENCODE_TOR_KEEP:-}" = "1" ]; then return 0; fi
  echo "opencode-tor: parando contenedor Tor"
  docker stop "$OPENCODE_TOR_CONTAINER" >/dev/null 2>&1 || true
}

trap stop_tor EXIT

start_tor
if [ "${OPENCODE_TOR_SKIP_READY:-}" != "1" ]; then
  wait_ready
fi

export HTTP_PROXY="http://127.0.0.1:$HTTP_TUNNEL_PORT"
export HTTPS_PROXY="$HTTP_PROXY"
export ALL_PROXY="$HTTP_PROXY"
export NO_PROXY="127.0.0.1,localhost"
export OPENCODE_CONFIG="$OPENCODE_TOR_CONFIG"

exec "$OPENCODE_TOR_BIN" "$@"
```

- [ ] **Step 2: Syntax check + make executable**

Run:
```bash
bash -n plugins/ip-rotate/opencode-tor && chmod +x plugins/ip-rotate/opencode-tor && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/ip-rotate/opencode-tor
git commit -m "feat(plugin): add opencode-tor wrapper script"
```

---

### Task 2: Write the `build-install.sh` generator

**Files:**
- Create: `plugins/ip-rotate/build-install.sh`

- [ ] **Step 1: Write the generator**

The generator embeds the plugin directory and the wrapper (base64, one per line via `| base64 | tr -d '\n'`) plus the reference `torrc` template into a `__PAYLOAD__` block, then writes `install-opencode-tor.sh` by combining an embedded preamble (the installer logic, in a heredoc) with the payload.

Write `plugins/ip-rotate/build-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Genera install-opencode-tor.sh autocontenido con el plugin ip-rotate y el
# wrapper opencode-tor embebidos. Ejecuta: ./build-install.sh [output-path]
# (default: plugins/ip-rotate/install-opencode-tor.sh)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN_DIR="$ROOT/plugins/ip-rotate"
OUT="${1:-$PLUGIN_DIR/install-opencode-tor.sh}"

for f in index.ts package.json src/config.ts src/detector.ts src/rotator.ts src/resumer.ts src/state.ts; do
  [ -f "$PLUGIN_DIR/$f" ] || { echo "falta $f" >&2; exit 1; }
done
[ -f "$PLUGIN_DIR/opencode-tor" ] || { echo "falta opencode-tor" >&2; exit 1; }
[ -f "$PLUGIN_DIR/torrc" ] || { echo "falta torrc" >&2; exit 1; }

PLUGIN_B64=$(tar -C "$PLUGIN_DIR" -czf - index.ts package.json src | base64 | tr -d '\n')
WRAPPER_B64=$(base64 < "$PLUGIN_DIR/opencode-tor" | tr -d '\n')
TORRC_B64=$(base64 < "$PLUGIN_DIR/torrc" | tr -d '\n')

cat > "$OUT" <<'INSTALLER_EOF'
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
    -v|--version) requested_version="$2"; shift 2 ;;
    -b|--binary) binary_path="$2"; shift 2 ;;
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
  curl -fsSL -o "$tmp/$filename" "$url"
  if [ "$os" = "linux" ]; then tar -xzf "$tmp/$filename" -C "$tmp"; else unzip -q "$tmp/$filename" -d "$tmp"; fi
  mv "$tmp/opencode" "$BIN_FILE"
  chmod 755 "$BIN_FILE"
  rm -rf "$tmp"
fi

# --- 2. Plugin ---
PLUGIN_B64='__PLUGIN_B64__'
WRAPPER_B64='__WRAPPER_B64__'
TORRC_B64='__TORRC_B64__'

PLUGIN_OUT="$INSTALL_DIR/plugins/ip-rotate"
mkdir -p "$PLUGIN_OUT"
echo "$PLUGIN_B64" | base64 -d | tar -xzf - -C "$PLUGIN_OUT"

# Reescribir la dep workspace por una versión npm y resolverla.
sed -i 's#"@opencode-ai/plugin": "workspace:\*"#"@opencode-ai/plugin": "latest"#' "$PLUGIN_OUT/package.json"
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
HASH="$(hash_password "$CONTROL_PASSWORD")"
if [ "$HASH" = "ERROR_NO_TOR" ] || [ -z "$HASH" ]; then
  echo -e "${RED}Error: no se pudo generar el hash de Tor (instala tor o docker)${NC}"
  exit 1
fi

echo "$TORRC_B64" | base64 -d > "$INSTALL_DIR/torrc"
sed -i "s|^HashedControlPassword .*|HashedControlPassword $HASH|" "$INSTALL_DIR/torrc"

# --- 4. opencode.json ---
cat > "$INSTALL_DIR/opencode.json" <<JSON
{
  "plugin": [["file://$INSTALL_DIR/plugins/ip-rotate", { "controlPassword": "$CONTROL_PASSWORD" }]]
}
JSON

# --- 5. wrapper ---
echo "$WRAPPER_B64" | base64 -d > "$INSTALL_DIR/bin/opencode-tor"
chmod 755 "$INSTALL_DIR/bin/opencode-tor"

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
  case "$current_shell" in
    fish) config_file="$HOME/.config/fish/config.fish" ;;
    zsh) config_file="$HOME/.zshrc" ;;
    *) config_file="$HOME/.bashrc" ;;
  esac
  [ -f "$config_file" ] || config_file=""
  if [ -n "$config_file" ]; then
    add_to_path "$config_file" "export PATH=$INSTALL_DIR/bin:\$PATH"
  else
    echo -e "${ORANGE}No shell config found; add manually: export PATH=$INSTALL_DIR/bin:\$PATH${NC}"
  fi
fi

echo ""
echo -e "${MUTED}Instalado en ${NC}$INSTALL_DIR"
echo -e "${MUTED}Ejecuta: ${NC}opencode-tor${MUTED} (o ${NC}$INSTALL_DIR/bin/opencode-tor${MUTED} si PATH no está actualizado)${NC}"
echo ""
INSTALLER_EOF

# Sustituir los payloads en el instalador generado.
sed -i "s|__PLUGIN_B64__|$PLUGIN_B64|; s|__WRAPPER_B64__|$WRAPPER_B64|; s|__TORRC_B64__|$TORRC_B64|" "$OUT"
chmod 755 "$OUT"
echo "generado: $OUT"
```

- [ ] **Step 2: Syntax check + run the generator**

Run:
```bash
bash -n plugins/ip-rotate/build-install.sh && bash -n plugins/ip-rotate/install-opencode-tor.sh 2>/dev/null || true
cd /home/reverendo/Desarrollo/opencode && ./plugins/ip-rotate/build-install.sh
bash -n plugins/ip-rotate/install-opencode-tor.sh
```
Expected: generator prints `generado: ...`; regenerated `install-opencode-tor.sh` passes `bash -n`.

- [ ] **Step 3: Verify payload substitution worked**

Run:
```bash
grep -c '__PLUGIN_B64__\|__WRAPPER_B64__\|__TORRC_B64__' plugins/ip-rotate/install-opencode-tor.sh || echo "no placeholders left"
```
Expected: `no placeholders left` (or grep returns 0 matches, which prints nothing — confirm with the `||` fallback).

- [ ] **Step 4: Commit**

```bash
git add plugins/ip-rotate/build-install.sh plugins/ip-rotate/install-opencode-tor.sh
git commit -m "feat(plugin): add opencode-tor self-contained installer generator"
```

---

### Task 3: Test the generated installer + wrapper

**Files:**
- Create: `plugins/ip-rotate/test/generator.test.sh`
- Create: `plugins/ip-rotate/test/wrapper.test.sh`

- [ ] **Step 1: Write generator smoke test**

Write `plugins/ip-rotate/test/generator.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/install-opencode-tor.sh"
./build-install.sh "$OUT"
[ -x "$OUT" ] || { echo "FAIL: instalador no ejecutable"; exit 1; }
bash -n "$OUT" || { echo "FAIL: sintaxis"; exit 1; }
# El instalador embebe el plugin: verificar que los payloads son base64 válido.
grep -q '__PLUGIN_B64__' "$OUT" && { echo "FAIL: placeholder plugin sin sustituir"; exit 1; }
grep -q '__WRAPPER_B64__' "$OUT" && { echo "FAIL: placeholder wrapper sin sustituir"; exit 1; }
grep -q '__TORRC_B64__' "$OUT" && { echo "FAIL: placeholder torrc sin sustituir"; exit 1; }
echo "PASS: generator smoke test"
```

- [ ] **Step 2: Write wrapper test (docker stub)**

Write `plugins/ip-rotate/test/wrapper.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub docker que registra las llamadas en un log.
LOG="$WORK/docker.log"
cat > "$WORK/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
case "$1" in
  inspect)
    # Contenedor inexistente: stderr vacío y exit 1 (como docker real).
    echo "" >&2
    exit 1
    ;;
  run)
    # Simula arranque: toca los puertos no se simulan; listo.
    exit 0
    ;;
  stop) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/docker"
: > "$LOG"

# Binario fake + config + torrc mínimos.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode llamado con: $*"
EOF
chmod +x "$WORK/bin/opencode"
cat > "$WORK/torrc" <<'EOF'
SocksPort 9050
HTTPTunnelPort 8118
ControlPort 9051
HashedControlPassword 16:0000000000000000000000000000000000000000000000000000
MaxCircuitDirtiness 86400
EOF
cat > "$WORK/opencode.json" <<'EOF'
{ "plugin": [] }
EOF

# Ejecutar el wrapper con overrides de test y "docker" del stub en PATH.
OPENCODE_TOR_DIR="$WORK" \
OPENCODE_TOR_BIN="$WORK/bin/opencode" \
OPENCODE_TOR_CONTAINER="ip-rotate-tor-test" \
OPENCODE_TOR_SKIP_READY=1 \
OPENCODE_TOR_KEEP=1 \
PATH="$WORK:$PATH" \
"$PWD/opencode-tor" "run" "hola mundo" > "$WORK/out.log" 2>&1 || true

grep -q "opencode llamado con: run hola mundo" "$WORK/out.log" \
  || { echo "FAIL: opencode no ejecutado con args"; cat "$WORK/out.log"; exit 1; }
grep -q "docker run" "$WORK/docker.log" \
  || { echo "FAIL: no se invocó docker run"; cat "$WORK/docker.log"; exit 1; }
echo "PASS: wrapper test"
```

Note: the wrapper's `wait_ready` is skipped via `OPENCODE_TOR_SKIP_READY=1` (no real Tor listens in the test), and `OPENCODE_TOR_KEEP=1` skips `docker stop`. The key assertions are that `docker run` was invoked and the fake opencode received the args. The docker stub's `inspect` returns exit 1 so the wrapper takes the `docker run` branch.

- [ ] **Step 3: Run the tests**

Run:
```bash
chmod +x plugins/ip-rotate/test/*.sh
plugins/ip-rotate/test/generator.test.sh
plugins/ip-rotate/test/wrapper.test.sh
```
Expected: `PASS: generator smoke test` and `PASS: wrapper test`.

- [ ] **Step 4: Commit**

```bash
git add plugins/ip-rotate/test/generator.test.sh plugins/ip-rotate/test/wrapper.test.sh
git commit -m "test(plugin): add opencode-tor generator and wrapper tests"
```

---

### Task 4: End-to-end install into a temp dir

**Files:** none (verification only)

- [ ] **Step 1: Dry-run installer with `--binary`**

Use the locally built dev binary to avoid a full release download:

Run:
```bash
ls packages/opencode/*.bin 2>/dev/null; ls /home/reverendo/.opencode/bin/opencode
```

If no local binary exists, skip to Step 3 (release download test).

- [ ] **Step 2: Install to an isolated HOME**

```bash
FAKE_HOME="$(mktemp -d)"
HOME="$FAKE_HOME" \
  OPENCODE_TOR_DIR="$FAKE_HOME/.opencode-tor" \
  plugins/ip-rotate/install-opencode-tor.sh \
    --binary /home/reverendo/.opencode/bin/opencode \
    --no-modify-path
```
Expected: prints `Instalado en $FAKE_HOME/.opencode-tor`. Then verify:
```bash
ls "$FAKE_HOME/.opencode-tor/bin/opencode" "$FAKE_HOME/.opencode-tor/bin/opencode-tor"
ls "$FAKE_HOME/.opencode-tor/plugins/ip-rotate/index.ts" "$FAKE_HOME/.opencode-tor/plugins/ip-rotate/src/rotator.ts"
grep -q HashedControlPassword "$FAKE_HOME/.opencode-tor/torrc" && echo "torrc ok"
cat "$FAKE_HOME/.opencode-tor/opencode.json"
```
Expected: all paths exist; `torrc` has a real `16:...` hash (not the all-zero template); `opencode.json` references `file://$FAKE_HOME/.opencode-tor/plugins/ip-rotate` and a non-empty `controlPassword`.

- [ ] **Step 3: Full release download test (optional, network)**

```bash
FAKE_HOME="$(mktemp -d)"
HOME="$FAKE_HOME" plugins/ip-rotate/install-opencode-tor.sh --no-modify-path
"$FAKE_HOME/.opencode-tor/bin/opencode" --version
```
Expected: opencode binary installed and `--version` works. (Skip if you don't want a real download.)

---

### Task 5: Update README + docs

**Files:**
- Modify: `plugins/ip-rotate/README.md`

- [ ] **Step 1: Add `opencode-tor` section to README**

Append to `plugins/ip-rotate/README.md`:

```markdown
## opencode-tor (lanzador aislado)

Instala un comando global `opencode-tor` con su propia copia de opencode, su
propio contenedor docker de Tor y el plugin `ip-rotate` ya registrado. No toca
el opencode instalado en `~/.opencode/bin` ni tu config global.

### Instalación

```bash
# Generar el instalador (desde el repo):
./plugins/ip-rotate/build-install.sh

# Servirlo/hostearlo y ejecutarlo:
curl -fsSL https://<host>/install-opencode-tor.sh | bash
# o localmente:
./plugins/ip-rotate/install-opencode-tor.sh
```

Flags: `--version <v>`, `--binary <path>`, `--no-modify-path`.

### Uso

```bash
opencode-tor                    # TUI con Tor + plugin ip-rotate
opencode-tor run "..."          # run headless con Tor
```

El wrapper: arranca el contenedor `ip-rotate-tor` (`dperson/torproxy`,
`--network host`), espera readiness, exporta `HTTP_PROXY`/`HTTPS_PROXY`
`=http://127.0.0.1:8118`, inyecta `OPENCODE_CONFIG` y ejecuta su binario. Al
salir, para el contenedor.

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
```

### Tests

```bash
plugins/ip-rotate/test/generator.test.sh
plugins/ip-rotate/test/wrapper.test.sh
```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/ip-rotate/README.md
git commit -m "docs(plugin): document opencode-tor launcher"
```

---

### Task 6: Final verification

**Files:** none

- [ ] **Step 1: Full check**

Run:
```bash
cd plugins/ip-rotate && bun test     # 13 pass esperados
bash -n opencode-tor build-install.sh install-opencode-tor.sh
plugins/ip-rotate/test/generator.test.sh
plugins/ip-rotate/test/wrapper.test.sh
git status --short
git log --oneline -6
```
Expected: all tests pass, scripts syntactically valid, 4 new commits on `ip-rotate-e2e`.

- [ ] **Step 2: Report**

Summarize: what was built, the install flow, the wrapper lifecycle, and how to use `opencode-tor` (pointing to the README section).
