import { readFileSync, writeFileSync } from "node:fs"

export type State = {
  lastRotationAt: number
  rotationsBySession: Map<string, number>
  lastKnownIp: string | undefined
}

export function createState(): State {
  return {
    lastRotationAt: 0,
    rotationsBySession: new Map(),
    lastKnownIp: undefined,
  }
}

export type ZenModel = { providerID: string; modelID: string }

export type ZenBlockState = {
  isBlocked(): boolean
  until(): number | undefined
  block(untilMs: number): void
  clear(): void
  trackFallback(sessionID: string, previousModel: ZenModel): void
  fallbackSessions(): Map<string, ZenModel>
}

type ZenBlockFile = { until?: number }

export function createZenBlockState(path: string): ZenBlockState {
  let until: number | undefined
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as ZenBlockFile
    if (typeof parsed.until === "number") until = parsed.until
  } catch {
    until = undefined
  }
  const fallbackSessions = new Map<string, ZenModel>()

  const persist = () => {
    try {
      writeFileSync(path, JSON.stringify({ until } satisfies ZenBlockFile))
    } catch {
      // Persistencia best-effort: si falla, el bloqueo sigue activo en memoria para este proceso.
    }
  }

  return {
    isBlocked: () => until !== undefined && Date.now() < until,
    until: () => until,
    block: (untilMs) => {
      if (until !== undefined && until >= untilMs) return
      until = untilMs
      persist()
    },
    clear: () => {
      until = undefined
      fallbackSessions.clear()
      persist()
    },
    trackFallback: (sessionID, previousModel) => fallbackSessions.set(sessionID, previousModel),
    fallbackSessions: () => fallbackSessions,
  }
}
