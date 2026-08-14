import type { Hooks, PluginInput } from "@opencode-ai/plugin"

export const server = async (input: PluginInput): Promise<Hooks> => {
  console.log("[ip-rotate] plugin loaded")
  return {
    dispose: async () => {},
  }
}
