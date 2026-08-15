import type { Config } from "./config"
import { parseExitPool, pickKnownGoodExit } from "./exit-pool"

export interface Rotator {
  currentIp(): Promise<string | undefined>
  rotate(): Promise<string | undefined>
  rotateUntilClean?(): Promise<string | undefined>
  rotateToKnownGood?(excludeIp?: string): Promise<string | undefined>
}

export function createRotator(config: Config): Rotator {
  return new TorControlRotator(config)
}

// Prueba real contra el endpoint del modelo a través del proxy actual, sin
// gastar apenas tokens (max_tokens=8). true = el exit actual NO está limitado.
export async function probeModel(config: Config): Promise<boolean> {
  try {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 30000)
    try {
      const response = await fetch(config.probeUrl, {
        method: "POST",
        // Seam de test: proxyUrl vacío = conexión directa (sin proxy).
        ...(config.proxyUrl ? { proxy: config.proxyUrl } : {}),
        signal: controller.signal,
        headers: {
          Authorization: "Bearer public",
          "Content-Type": "application/json",
          Connection: "close",
        },
        body: JSON.stringify({
          model: config.probeModel,
          messages: [{ role: "user", content: "di hola" }],
          max_tokens: 8,
        }),
      })
      const body = await response.text()
      if (/FreeUsageLimitError|Rate limit|Too Many|429/i.test(body)) return false
      return body.includes("chat.completion")
    } finally {
      clearTimeout(timeout)
    }
  } catch {
    return false
  }
}

async function fetchIp(config: Config): Promise<string | undefined> {
  try {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 10000)
    try {
      // Connection: close para no reutilizar un socket keep-alive que siga
      // atado al circuito anterior y devuelva la misma IP.
      const response = await fetch(config.verifyUrl, {
        proxy: config.proxyUrl,
        signal: controller.signal,
        headers: { Connection: "close" },
      })
      if (!response.ok) return undefined
      const body = await response.text()
      const ip = body.trim()
      return ip.length > 0 ? ip : undefined
    } finally {
      clearTimeout(timeout)
    }
  } catch {
    return undefined
  }
}

class TorControlRotator implements Rotator {
  constructor(private readonly config: Config) {}

  async currentIp(): Promise<string | undefined> {
    return fetchIp(this.config)
  }

  // Rota y verifica contra el endpoint real hasta dar con un exit limpio.
  // Cada intento cuesta ~12 s (NEWNYM va rate-limitado por Tor a ~10 s).
  async rotateUntilClean(): Promise<string | undefined> {
    const current = await this.currentIp()
    if (current !== undefined && (await probeModel(this.config))) return current

    const known = await this.rotateToKnownGood(current)
    if (known !== undefined) {
      console.log(`[ip-rotate] exit conocido probado: ${known}`)
      if (await probeModel(this.config)) return known
      console.log("[ip-rotate] exit conocido ya no sirve, rotando a ciegas")
    }

    for (let attempt = 1; attempt <= this.config.probeMaxAttempts; attempt++) {
      const next = await this.rotate()
      if (next === undefined) continue
      console.log(`[ip-rotate] intento ${attempt}: probando exit ${next} contra ${this.config.probeModel}`)
      if (await probeModel(this.config)) return next
      console.log(`[ip-rotate] intento ${attempt}: exit ${next} limitado, rotando de nuevo`)
    }
    return undefined
  }

  async rotateToKnownGood(excludeIp?: string): Promise<string | undefined> {
    let records
    try {
      records = parseExitPool(await Bun.file(this.config.exitPoolPath).text())
    } catch {
      return undefined
    }
    const candidate = pickKnownGoodExit(records, excludeIp)
    if (!candidate) return undefined

    const previous = await this.currentIp()
    const ok = await this.setExitNode(candidate.fp)
    if (!ok) return undefined

    await new Promise((resolve) => setTimeout(resolve, 10000))
    const next = await this.currentIp()
    if (next === undefined || next === previous || next === excludeIp) return undefined
    return next
  }

  async rotate(): Promise<string | undefined> {
    const previous = await this.currentIp()
    const newnym = await this.sendNewnym()
    if (!newnym) return undefined

    // Esperar a que el nuevo circuito esté activo antes de verificar.
    await new Promise((resolve) => setTimeout(resolve, 10000))
    let next = await this.currentIp()

    // NEWNYM no garantiza IP distinta al instante: un único reintento.
    if (next !== undefined && next === previous) {
      await this.sendNewnym()
      await new Promise((resolve) => setTimeout(resolve, 10000))
      next = await this.currentIp()
    }

    return next
  }

  private setExitNode(fingerprint: string): Promise<boolean> {
    return this.sendCommands([`SETCONF ExitNodes=${fingerprint} StrictNodes=1`, "SIGNAL NEWNYM"])
  }

  private sendNewnym(): Promise<boolean> {
    return this.sendCommands(["SIGNAL NEWNYM"])
  }

  private async sendCommands(cmds: string[]): Promise<boolean> {
    const { config } = this
    try {
      let buffer = ""
      const pending: Array<(ok: boolean) => void> = []

      const socket = await Promise.race([
        Bun.connect({
          hostname: "127.0.0.1",
          port: config.controlPort,
          socket: {
            data(socket, data) {
              buffer += new TextDecoder().decode(data)
              let idx: number
              while ((idx = buffer.indexOf("\r\n")) !== -1) {
                const line = buffer.slice(0, idx)
                buffer = buffer.slice(idx + 2)
                const isOk = line.startsWith("250")
                if (!line.startsWith("250-")) {
                  const resolve = pending.shift()
                  if (resolve) resolve(isOk)
                }
              }
            },
            open() {},
            error() {},
            close() {},
          },
        }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("connect timeout")), 5000)),
      ])

      const send = (cmd: string) =>
        new Promise<boolean>((resolve) => {
          pending.push(resolve)
          socket.write(cmd)
          setTimeout(() => {
            const idx = pending.indexOf(resolve)
            if (idx !== -1) pending.splice(idx, 1)
            resolve(false)
          }, 5000)
        })

      const authOk = await send(`AUTHENTICATE "${config.controlPassword || ""}"\r\n`)
      if (!authOk) {
        socket.end()
        socket.close()
        return false
      }
      let allOk = true
      for (const cmd of cmds) {
        const ok = await send(`${cmd}\r\n`)
        if (!ok) allOk = false
      }
      socket.write("QUIT\r\n")
      socket.end()
      socket.close()
      return allOk
    } catch {
      return false
    }
  }
}
