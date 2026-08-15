import type { PluginOptions } from "@opencode-ai/plugin"
import { homedir } from "node:os"
import { join } from "node:path"

export type Config = {
  proxyUrl: string
  controlPort: number
  controlPassword: string
  cooldownMs: number
  maxRotationsPerSession: number
  resume: "reprompt" | "none"
  verifyUrl: string
  errorPatterns: string[]
  probeUrl: string
  probeModel: string
  probeMaxAttempts: number
  exitPoolPath: string
}

const DEFAULTS: Config = {
  proxyUrl: "http://127.0.0.1:8118",
  controlPort: 9051,
  controlPassword: "",
  cooldownMs: 15000,
  maxRotationsPerSession: 5,
  resume: "reprompt",
  verifyUrl: "https://api.ipify.org",
  errorPatterns: ["429", "rate limit", "too many requests", "free limit reached", "free usage exceeded", "overloaded"],
  probeUrl: "https://opencode.ai/zen/v1/chat/completions",
  probeModel: "big-pickle",
  probeMaxAttempts: 5,
  exitPoolPath: join(homedir(), ".opencode-tor", "exits-sweep.jsonl"),
}

function isString(value: unknown): value is string {
  return typeof value === "string"
}

function isNumber(value: unknown): value is number {
  return typeof value === "number"
}

export function parseConfig(options: PluginOptions = {}): Config {
  const str = (key: string) => (isString(options[key]) ? options[key] : undefined)
  const num = (key: string) => (isNumber(options[key]) ? options[key] : undefined)

  const resume = str("resume")
  const patterns = Array.isArray(options.errorPatterns) ? options.errorPatterns.filter(isString) : undefined

  return {
    proxyUrl: str("proxyUrl") ?? DEFAULTS.proxyUrl,
    controlPort: num("controlPort") ?? DEFAULTS.controlPort,
    controlPassword: str("controlPassword") ?? DEFAULTS.controlPassword,
    cooldownMs: num("cooldownMs") ?? DEFAULTS.cooldownMs,
    maxRotationsPerSession: num("maxRotationsPerSession") ?? DEFAULTS.maxRotationsPerSession,
    resume: resume === "reprompt" || resume === "none" ? resume : DEFAULTS.resume,
    verifyUrl: str("verifyUrl") ?? DEFAULTS.verifyUrl,
    errorPatterns: patterns && patterns.length > 0 ? patterns : DEFAULTS.errorPatterns,
    probeUrl: str("probeUrl") ?? DEFAULTS.probeUrl,
    probeModel: str("probeModel") ?? DEFAULTS.probeModel,
    probeMaxAttempts: num("probeMaxAttempts") ?? DEFAULTS.probeMaxAttempts,
    exitPoolPath: str("exitPoolPath") ?? DEFAULTS.exitPoolPath,
  }
}
