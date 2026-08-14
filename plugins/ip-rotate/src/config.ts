import type { PluginOptions } from "@opencode-ai/plugin"

export type Config = {
  proxyUrl: string
  controlPort: number
  controlPassword: string
  cooldownMs: number
  maxRotationsPerSession: number
  resume: "reprompt" | "none"
  verifyUrl: string
  errorPatterns: string[]
}

const DEFAULTS: Config = {
  proxyUrl: "http://127.0.0.1:8118",
  controlPort: 9051,
  controlPassword: "",
  cooldownMs: 15000,
  maxRotationsPerSession: 5,
  resume: "reprompt",
  verifyUrl: "https://api.ipify.org",
  errorPatterns: ["429", "rate limit", "too many requests", "free limit reached", "overloaded"],
}

export function parseConfig(options: PluginOptions = {}): Config {
  const str = (key: string) => (typeof options[key] === "string" ? (options[key] as string) : undefined)
  const num = (key: string) => (typeof options[key] === "number" ? (options[key] as number) : undefined)

  const resume = str("resume")
  const patterns = Array.isArray(options.errorPatterns)
    ? options.errorPatterns.filter((p): p is string => typeof p === "string")
    : undefined

  return {
    proxyUrl: str("proxyUrl") ?? DEFAULTS.proxyUrl,
    controlPort: num("controlPort") ?? DEFAULTS.controlPort,
    controlPassword: str("controlPassword") ?? DEFAULTS.controlPassword,
    cooldownMs: num("cooldownMs") ?? DEFAULTS.cooldownMs,
    maxRotationsPerSession: num("maxRotationsPerSession") ?? DEFAULTS.maxRotationsPerSession,
    resume: resume === "reprompt" || resume === "none" ? resume : DEFAULTS.resume,
    verifyUrl: str("verifyUrl") ?? DEFAULTS.verifyUrl,
    errorPatterns: patterns && patterns.length > 0 ? patterns : DEFAULTS.errorPatterns,
  }
}
