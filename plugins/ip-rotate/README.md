# opencode-ip-rotate

Plugin para opencode que detecta rate limits por IP en los modelos gratuitos
(provider `opencode`/Zen) y rota la IP de salida a través de Tor (SOCKS5 local).
El alcance es **app-only**: todo el tráfico del proceso opencode sale por el proxy
Tor; el resto del sistema no se ve afectado.

## Requisitos

- Tor instalado: `sudo apt install tor` (Debian/Ubuntu) o tu gestor de paquetes.
- El puerto SOCKS5 `9050` y el puerto de control `9051` libres.

## Generar el password hash

El `torrc` de referencia usa `HashedControlPassword`. Para generar el hash de tu
password:

```bash
tor --hash-password "mi-password-secreto"
# 16:7E7DFEAB6CFCB3D1E7B45E5F7B8C5E5B7B7F4F0B3E...  (ejemplo)
```

Copia el hash en `plugins/ip-rotate/torrc`:

```
SocksPort 9050
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
3. Exporta `HTTP_PROXY`/`HTTPS_PROXY=socks5h://127.0.0.1:9050`.
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

Con opciones (se rellenan en fases siguientes):

```json
{
  "plugin": [["file:///abs/path/plugins/ip-rotate", { "cooldownMs": 15000 }]]
}
```

## Opciones

| Opción                | Default                         | Descripción                              |
| --------------------- | ------------------------------- | ---------------------------------------- |
| `socksProxy`          | `socks5h://127.0.0.1:9050`      | Proxy SOCKS5 por el que sale el tráfico  |
| `controlPort`         | `9051`                          | Puerto de control de Tor                 |
| `controlPassword`     | `""`                            | Password del control de Tor              |
| `cooldownMs`          | `15000`                         | Mínimo entre rotaciones (NEWNYM ~10s)    |
| `maxRotationsPerSession` | `5`                          | Máximo de rotaciones por sesión          |
| `resume`              | `"reprompt"`                    | Estrategia de reanudación (`"reprompt"` \| `"none"`) |
| `verifyUrl`           | `https://api.ipify.org`         | URL para verificar la IP de salida       |
| `errorPatterns`       | `["429", "rate limit", "too many requests", "free limit reached", "overloaded"]` | Patrones que detectan rate limit |

*(La tabla se completa en fases siguientes.)*
