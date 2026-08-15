import type { Hooks, PluginInput, PluginOptions } from "@opencode-ai/plugin"
import { parseConfig } from "./src/config"
import { extractRetryAfterMs, isIpBlocked } from "./src/detector"
import type { Rotator } from "./src/rotator"
import { createRotator } from "./src/rotator"
import { createResumer } from "./src/resumer"
import { createState, createZenBlockState } from "./src/state"

// Seam de test: permite inyectar un Rotator (p. ej. stub) sin tocar detector/resumer.
export type IpRotateOptions = PluginOptions & { rotator?: Rotator }

const DEFAULT_RETRY_AFTER_MS = 24 * 60 * 60 * 1000 // ventana diaria de Zen si el header no viene

export const server = async (input: PluginInput, options?: IpRotateOptions): Promise<Hooks> => {
  const config = parseConfig(options)
  const state = createState()
  const zenBlock = createZenBlockState(config.zenBlockPath)
  const rotator = options?.rotator ?? createRotator(config)
  const resumer = createResumer(config, input.client)

  console.log("[ip-rotate] plugin loaded")

  let revertTimer: ReturnType<typeof setTimeout> | undefined

  const scheduleRevert = () => {
    const until = zenBlock.until()
    if (until === undefined) return
    if (revertTimer) clearTimeout(revertTimer)
    revertTimer = setTimeout(async () => {
      revertTimer = undefined
      const sessions = new Map(zenBlock.fallbackSessions())
      zenBlock.clear()
      for (const [sessionID, model] of sessions) {
        console.log(
          `[ip-rotate] bloqueo de Zen expirado, devolviendo sesión ${sessionID} a ${model.providerID}/${model.modelID}`,
        )
        await resumer.resume(sessionID, model)
      }
    }, Math.max(0, until - Date.now()))
  }

  scheduleRevert() // rehidrata el timer si el proceso arranca con un bloqueo aún vigente

  const fallbackToLocal = async (sessionID: string, event: unknown): Promise<boolean> => {
    if (!config.localModel) return false
    const retryAfterMs = extractRetryAfterMs(event) ?? DEFAULT_RETRY_AFTER_MS
    const until = Date.now() + retryAfterMs
    zenBlock.block(until)
    zenBlock.trackFallback(sessionID, { providerID: "opencode", modelID: config.probeModel })
    scheduleRevert()
    console.log(`[ip-rotate] sin IPs viables: sesión ${sessionID} cae a local hasta ${new Date(until).toISOString()}`)
    await resumer.resume(sessionID, config.localModel)
    return true
  }

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

      if (zenBlock.isBlocked()) {
        console.log(`[ip-rotate] Zen ya sabido bloqueado, sesión ${sessionID} directa a fallback local`)
        await fallbackToLocal(sessionID, event)
        return
      }

      const now = Date.now()
      if (now - state.lastRotationAt < config.cooldownMs) {
        console.log(`[ip-rotate] rate limit en sesión ${sessionID} ignorado (cooldown activo)`)
        return
      }

      const used = state.rotationsBySession.get(sessionID) ?? 0
      if (used >= config.maxRotationsPerSession) {
        console.log(`[ip-rotate] rate limit en sesión ${sessionID}: rotaciones agotadas`)
        await fallbackToLocal(sessionID, event)
        return
      }

      state.rotationsBySession.set(sessionID, used + 1)
      state.lastRotationAt = now

      const previous = state.lastKnownIp
      console.log(`[ip-rotate] rate limit detectado en sesión ${sessionID}, rotando IP...`)
      const next = rotator.rotateUntilClean ? await rotator.rotateUntilClean() : await rotator.rotate()

      if (next === undefined) {
        console.log(`[ip-rotate] rotación fallida en sesión ${sessionID}`)
        if (used + 1 >= config.maxRotationsPerSession) {
          await fallbackToLocal(sessionID, event)
        }
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
