# opencode-ip-rotate

Plugin para opencode que detecta rate limits por IP en los modelos gratuitos
(provider `opencode`/Zen) y rota la IP de salida a través de Tor.
El alcance es **app-only**: todo el tráfico del proceso opencode sale por el proxy
Tor; el resto del sistema no se ve afectado.

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

## Requisitos

- Tor instalado: `sudo apt install tor` (Debian/Ubuntu) o tu gestor de paquetes.
- Puertos libres: SOCKS `9050`, túnel HTTP `8118`, control `9051`.

## Generar el password hash

El `torrc` de referencia usa `HashedControlPassword`. Para generar el hash de tu
password:

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

## Uso

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

## Registro del plugin

En `opencode.json` (la ruta se resuelve relativa al archivo de config):

```json
{
  "plugin": ["./plugins/ip-rotate"]
}
```

> Nota: la forma `file://./plugins/ip-rotate` **no** es válida; el loader de plugins
> falla al resolverla (`File URL host must be "localhost" or empty`). Usa la ruta
> relativa `./plugins/ip-rotate` o una URL absoluta `file:///abs/path/plugins/ip-rotate`.

Con opciones:

```json
{
  "plugin": [["file:///abs/path/plugins/ip-rotate", { "controlPassword": "mi-password-secreto" }]]
}
```

## Opciones

| Opción                | Default                         | Descripción                              |
| --------------------- | ------------------------------- | ---------------------------------------- |
| `proxyUrl`            | `http://127.0.0.1:8118`         | Proxy HTTP CONNECT (túnel Tor) de salida |
| `controlPort`         | `9051`                          | Puerto de control de Tor                 |
| `controlPassword`     | `""`                            | Password del control de Tor              |
| `cooldownMs`          | `15000`                         | Mínimo entre rotaciones (NEWNYM ~10s)    |
| `maxRotationsPerSession` | `5`                          | Máximo de rotaciones por sesión          |
| `resume`              | `"reprompt"`                    | Estrategia de reanudación (`"reprompt"` \| `"none"`) |
| `verifyUrl`           | `https://api.ipify.org`         | URL para verificar la IP de salida       |
| `errorPatterns`       | `["429", "rate limit", "too many requests", "free limit reached", "overloaded"]` | Patrones que detectan rate limit |

## Test manual de rotación

Con el plugin registrado y Tor levantado, para verificar la rotación de IP a mano:

```bash
# IP actual (por el túnel HTTP de Tor)
curl -s -x http://127.0.0.1:8118 https://api.ipify.org

# NEWNYM manual
printf 'AUTHENTICATE "mi-password-secreto"\r\nSIGNAL NEWNYM\r\nQUIT\r\n' | nc 127.0.0.1 9051

# Espera y verifica el cambio
sleep 12 && curl -s -x http://127.0.0.1:8118 https://api.ipify.org
```

## Cómo añadir otro Rotator

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

## Troubleshooting

| Síntoma | Causa probable | Solución |
| ------- | -------------- | -------- |
| "rotación fallida" en los logs | Tor caído, puerto control inaccesible | Verifica `nc -z 127.0.0.1 9050` y `9051`; arranca con `start-tor.sh` |
| `AUTHENTICATE` rechazado (`515`) | `controlPassword` no coincide con el hash de `torrc` | Regenera el hash (`tor --hash-password`) y actualiza `opencode.json` |
| "IP rotada: X -> X" (misma IP) | NEWNYM no garantiza salida distinta al instante | El plugin reintenta una vez y aplica cooldown; repite la rotación más tarde |
| La IP no cambia nunca | El servicio destino bloquea IPs de salida Tor | Usa otro `Rotator` (guía de extensión de arriba) |
| `UnsupportedProxyProtocol` | Bun 1.3.14 no soporta proxies `socks5://` | No uses `socks5://`; el plugin usa el túnel HTTP CONNECT (`HTTPTunnelPort 8118`) |
| Rate limits muy frecuentes (p. ej. `session.status: retry` en bucle) | El cooldown corto deja rotar demasiado | Sube `cooldownMs`; el cooldown global es el cortafuegos |
| Las rotaciones se agotan en una sesión | Se alcanzó `maxRotationsPerSession` | Ajusta el límite o espera a que la sesión pase a `idle` (se resetea el contador) |

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

### Tests

```bash
plugins/ip-rotate/test/generator.test.sh
plugins/ip-rotate/test/wrapper.test.sh
```

