export type ExitRecord = {
  fp: string
  ip: string
  verdict: "ok" | "limited" | "unreachable" | "mismatch" | "error"
  checked_at?: number
}

export function parseExitPool(jsonl: string): ExitRecord[] {
  return jsonl
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .flatMap((line) => {
      try {
        const record = JSON.parse(line)
        return isExitRecord(record) ? [record] : []
      } catch {
        return []
      }
    })
}

export function pickKnownGoodExit(records: ExitRecord[], excludeIp?: string): ExitRecord | undefined {
  return records
    .filter((r) => r.verdict === "ok" && r.ip !== excludeIp)
    .sort((a, b) => (b.checked_at ?? 0) - (a.checked_at ?? 0))[0]
}

function isExitRecord(value: unknown): value is ExitRecord {
  if (value === null || typeof value !== "object") return false
  const r = value as Record<string, unknown>
  return typeof r.fp === "string" && typeof r.ip === "string" && typeof r.verdict === "string"
}
