export type SessionEvent = {
  type: string
  properties: Record<string, unknown>
}

function isString(value: unknown): value is string {
  return typeof value === "string"
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object") return undefined
  const record: Record<string, unknown> = {}
  for (const [key, val] of Object.entries(value)) record[key] = val
  return record
}

function extractMessages(event: SessionEvent): string[] {
  if (event.type === "session.error") {
    const error = asRecord(event.properties.error)
    if (!error) return []
    // El schema de opencode serializa los errores como { name, data: { message, ... } }
    // (NamedError), no como { message }. Se extraen ambas formas más el responseBody,
    // donde el provider suele devolver el cuerpo con el 429.
    const data = asRecord(error.data)
    return [error.message, data?.message, data?.responseBody].filter(isString)
  }

  if (event.type === "session.status") {
    const status = asRecord(event.properties.status)
    if (status?.type === "retry" && isString(status.message)) return [status.message]
  }

  return []
}

export function isIpBlocked(event: unknown, patterns: string[]): boolean {
  const record = asRecord(event)
  const type = record?.type
  const props = asRecord(record?.properties)
  if (!isString(type) || !props) return false

  const sessionEvent: SessionEvent = { type, properties: props }
  const haystacks = [sessionEvent.type, ...extractMessages(sessionEvent)].filter(isString)
  if (haystacks.length === 0) return false

  const lower = patterns.map((p) => p.toLowerCase())
  return haystacks.some((haystack) => {
    const h = haystack.toLowerCase()
    return lower.some((p) => h.includes(p))
  })
}

export function extractRetryAfterMs(event: unknown): number | undefined {
  const record = asRecord(event)
  if (!record || record.type !== "session.error") return undefined
  const props = asRecord(record.properties)
  const error = asRecord(props?.error)
  const data = asRecord(error?.data)
  const headers = asRecord(data?.responseHeaders)
  if (!headers) return undefined

  const ms = headers["retry-after-ms"]
  if (isString(ms)) {
    const parsed = Number.parseFloat(ms)
    if (!Number.isNaN(parsed)) return parsed
  }
  const seconds = headers["retry-after"]
  if (isString(seconds)) {
    const parsed = Number.parseFloat(seconds)
    if (!Number.isNaN(parsed)) return parsed * 1000
  }
  return undefined
}
