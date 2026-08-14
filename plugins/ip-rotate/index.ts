import type { Hooks, PluginInput, PluginOptions } from "@opencode-ai/plugin"
import { parseConfig } from "./src/config"
import { isIpBlocked } from "./src/detector"
import { createState } from "./src/state"

export const server = async (input: PluginInput, options?: PluginOptions): Promise<Hooks> => {
  const config = parseConfig(options)
  const state = createState()

  console.log("[ip-rotate] plugin loaded")

  return {
    dispose: async () => {},
    event: async ({ event }) => {
      if (!isIpBlocked(event, config.errorPatterns)) return

      const properties = (event.properties ?? {}) as Record<string, unknown>
      const sessionID = typeof properties.sessionID === "string" ? properties.sessionID : undefined
      if (!sessionID) return

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
      console.log(`[ip-rotate] rate limit detectado en sesión ${sessionID}`)
    },
  }
}
