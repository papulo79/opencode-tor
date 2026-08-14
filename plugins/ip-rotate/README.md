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
> `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:8118` + `NO_PROXY=127.0.0.1,localhost`.

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
3. Exporta `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:8118` y `NO_PROXY=127.0.0.1,localhost`.
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

*(La tabla de opciones se completa en fases siguientes.)*
