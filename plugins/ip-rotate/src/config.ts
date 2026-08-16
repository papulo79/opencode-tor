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
  // Subconjunto de errorPatterns que es terminal (el límite gratuito diario de
  // Zen agotado, no un 429/overloaded transitorio): solo estos disparan el
  // fallback a localModel. Ver detector.isIpBlocked, reutilizada con esta lista.
  terminalErrorPatterns: string[]
  probeUrl: string
  probeModel: string
  probeMaxAttempts: number
  exitPoolPath: string
  zenBlockPath: string
  localModel?: { providerID: string; modelID: string }
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
  terminalErrorPatterns: ["free limit reached", "free usage exceeded"],
  probeUrl: "https://opencode.ai/zen/v1/chat/completions",
  probeModel: "big-pickle",
  probeMaxAttempts: 5,
  exitPoolPath: join(homedir(), ".opencode-tor", "exits-sweep.jsonl"),
  zenBlockPath: join(homedir(), ".opencode-tor", "zen-block.json"),
}

function isString(value: unknown): value is string {
  return typeof value === "string"
}

function isNumber(value: unknown): value is number {
  return typeof value === "number"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}

export function parseConfig(options: PluginOptions = {}): Config {
  const str = (key: string) => (isString(options[key]) ? options[key] : undefined)
  const num = (key: string) => (isNumber(options[key]) ? options[key] : undefined)

  const resume = str("resume")
  const patterns = Array.isArray(options.errorPatterns) ? options.errorPatterns.filter(isString) : undefined
  const terminalPatterns = Array.isArray(options.terminalErrorPatterns)
    ? options.terminalErrorPatterns.filter(isString)
    : undefined

  const localModelInput = options.localModel
  const localModel =
    isRecord(localModelInput) && isString(localModelInput.providerID) && isString(localModelInput.modelID)
      ? { providerID: localModelInput.providerID, modelID: localModelInput.modelID }
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
    terminalErrorPatterns:
      terminalPatterns && terminalPatterns.length > 0 ? terminalPatterns : DEFAULTS.terminalErrorPatterns,
    probeUrl: str("probeUrl") ?? DEFAULTS.probeUrl,
    probeModel: str("probeModel") ?? DEFAULTS.probeModel,
    probeMaxAttempts: num("probeMaxAttempts") ?? DEFAULTS.probeMaxAttempts,
    exitPoolPath: str("exitPoolPath") ?? DEFAULTS.exitPoolPath,
    zenBlockPath: str("zenBlockPath") ?? DEFAULTS.zenBlockPath,
    localModel,
  }
}
