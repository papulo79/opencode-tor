import type { PluginInput } from "@opencode-ai/plugin"
import type { Config } from "./config"

type Client = PluginInput["client"]

export interface Resumer {
  resume(sessionID: string): Promise<void>
}

export function createResumer(config: Config, client: Client): Resumer {
  return config.resume === "reprompt" ? new RepromptResumer(client) : new NoopResumer()
}

class NoopResumer implements Resumer {
  async resume(): Promise<void> {
    // El retry interno de processor.ts (429 reintentables) reintentará solo.
  }
}

class RepromptResumer implements Resumer {
  constructor(private readonly client: Client) {}

  async resume(sessionID: string): Promise<void> {
    try {
      const response = await this.client.session.messages({ path: { id: sessionID } })
      const messages = response.data ?? response
      const lastUser = [...messages].reverse().find((m) => m.info.role === "user")
      if (!lastUser) {
        console.log(`[ip-rotate] sesión ${sessionID} sin mensajes de usuario: no reanudo`)
        return
      }

      const parts = lastUser.parts
        .filter(isTextPart)
        .map((part) => ({ type: "text" as const, text: part.text }))

      if (parts.length === 0) {
        console.log(`[ip-rotate] último mensaje de usuario de ${sessionID} sin texto: no reanudo`)
        return
      }

      await this.client.session.prompt({ path: { id: sessionID }, body: { parts } })
      console.log(`[ip-rotate] sesión ${sessionID} reanudada con el último prompt`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      console.log(`[ip-rotate] no pude reanudar sesión ${sessionID}: ${message}`)
    }
  }
}

function isTextPart(part: unknown): part is { type: "text"; text: string } {
  return (
    typeof part === "object" &&
    part !== null &&
    (part as { type?: unknown }).type === "text" &&
    typeof (part as { text?: unknown }).text === "string"
  )
}
