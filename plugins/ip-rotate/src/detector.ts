export type SessionEvent = {
  type: string
  properties: Record<string, unknown>
}

function extractMessages(event: SessionEvent): string[] {
  if (event.type === "session.error") {
    const error = event.properties?.error as Record<string, unknown> | undefined
    if (error && typeof error.message === "string") return [error.message]
  }

  if (event.type === "session.status") {
    const status = event.properties?.status as Record<string, unknown> | undefined
    if (status?.type === "retry" && typeof status.message === "string") return [status.message]
  }

  return []
}

export function isIpBlocked(event: unknown, patterns: string[]): boolean {
  if (!event || typeof event !== "object") return false
  const e = event as SessionEvent
  if (typeof e.type !== "string" || !e.properties || typeof e.properties !== "object") return false

  const haystacks = [e.type, ...extractMessages(e)].filter((s): s is string => typeof s === "string")
  if (haystacks.length === 0) return false

  const lower = patterns.map((p) => p.toLowerCase())
  return haystacks.some((haystack) => {
    const h = haystack.toLowerCase()
    return lower.some((p) => h.includes(p))
  })
}
