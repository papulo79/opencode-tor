import type { Hooks, PluginInput, PluginOptions } from "@opencode-ai/plugin"
import { parseConfig } from "./src/config"
import { isIpBlocked } from "./src/detector"
import type { Rotator } from "./src/rotator"
import { createRotator } from "./src/rotator"
import { createResumer } from "./src/resumer"
import { createState } from "./src/state"

// Seam de test: permite inyectar un Rotator (p. ej. stub) sin tocar detector/resumer.
export type IpRotateOptions = PluginOptions & { rotator?: Rotator }

export const server = async (input: PluginInput, options?: IpRotateOptions): Promise<Hooks> => {
  const config = parseConfig(options)
  const state = createState()
  const rotator = options?.rotator ?? createRotator(config)
  const resumer = createResumer(config, input.client)

  console.log("[ip-rotate] plugin loaded")

  return {
    dispose: async () => {},
    event: async ({ event }) => {
      const properties = (event.properties ?? {}) as Record<string, unknown>
      const sessionID = typeof properties.sessionID === "string" ? properties.sessionID : undefined
      if (!sessionID) return

      // Tras recuperación (idle) se resetea el contador de rotaciones de la sesión.
      if (isIdle(event)) {
        if (state.rotationsBySession.delete(sessionID)) {
          console.log(`[ip-rotate] sesión ${sessionID} idle tras recuperación: contador reseteado`)
        }
        return
      }

      if (!isIpBlocked(event, config.errorPatterns)) return

      const now = Date.now()
      if (now - state.lastRotationAt < config.cooldownMs) {
        console.log(`[ip-rotate] rate limit en sesión ${sessionID} ignorado (cooldown activo)`)
        return
      }

      const used = state.rotationsBySession.get(sessionID) ?? 0
      if (used >= config.maxRotationsPerSession) {
        console.log(`[ip-rotate] rate limit en sesión ${sessionID} ignorado (máximo de rotaciones alcanzado)`)
        return
      }

      state.rotationsBySession.set(sessionID, used + 1)
      state.lastRotationAt = now

      const previous = state.lastKnownIp
      console.log(`[ip-rotate] rate limit detectado en sesión ${sessionID}, rotando IP...`)
      const next = await rotator.rotate()

      if (next === undefined) {
        console.log(`[ip-rotate] rotación fallida en sesión ${sessionID}: se mantiene el error original`)
        return
      }

      state.lastKnownIp = next
      console.log(`[ip-rotate] IP rotada: ${previous ?? "desconocida"} -> ${next}`)
      console.log("[ip-rotate] IP rotada, reanudando sesión")
      await resumer.resume(sessionID)
      try {
        await input.client.app.log({
          body: { service: "ip-rotate", level: "info", message: `IP rotada, reanudando sesión ${sessionID}` },
        })
      } catch {
        // La notificación es best-effort; nunca romper la sesión.
      }
    },
  }
}

function isIdle(event: unknown): boolean {
  if (!event || typeof event !== "object") return false
  const e = event as { type?: string; properties?: Record<string, unknown> }
  if (e.type === "session.idle") return true
  if (e.type !== "session.status") return false
  const status = e.properties?.status
  return isRecord(status) && status.type === "idle"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}
