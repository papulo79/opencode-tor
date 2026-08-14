import type { Config } from "./config"

export interface Rotator {
  currentIp(): Promise<string | undefined>
  rotate(): Promise<string | undefined>
}

export function createRotator(config: Config): Rotator {
  return new TorControlRotator(config)
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

  private async sendNewnym(): Promise<boolean> {
    const { config } = this
    try {
      let buffer = ""
      const pending: Array<(ok: boolean) => void> = []

      const socket = await Bun.connect({
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
      })

      const send = (cmd: string) =>
        new Promise<boolean>((resolve) => {
          pending.push(resolve)
          socket.write(cmd)
        })

      const ok = await send(`AUTHENTICATE "${config.controlPassword || ""}"\r\n`)
      if (!ok) {
        socket.end()
        socket.close()
        return false
      }
      const newnym = await send("SIGNAL NEWNYM\r\n")
      socket.write("QUIT\r\n")
      socket.end()
      socket.close()
      return newnym
    } catch {
      return false
    }
  }
}
