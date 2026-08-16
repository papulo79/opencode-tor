import { describe, expect, test } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createZenBlockState } from "../src/state"

function tmpPath() {
  return join(mkdtempSync(join(tmpdir(), "ip-rotate-state-")), "zen-block.json")
}

describe("createZenBlockState", () => {
  test("no bloqueado por defecto", () => {
    const state = createZenBlockState(tmpPath())
    expect(state.isBlocked()).toBe(false)
  })

  test("bloqueado hasta una hora futura", () => {
    const state = createZenBlockState(tmpPath())
    state.block(Date.now() + 60000)
    expect(state.isBlocked()).toBe(true)
  })

  test("no extiende el bloqueo si la nueva hora es anterior a la ya guardada", () => {
    const path = tmpPath()
    const state = createZenBlockState(path)
    const later = Date.now() + 120000
    state.block(later)
    state.block(Date.now() + 60000)
    expect(state.until()).toBe(later)
  })

  test("clear limpia bloqueo y sesiones en fallback", () => {
    const state = createZenBlockState(tmpPath())
    state.block(Date.now() + 60000)
    state.trackFallback("s1", { providerID: "local", modelID: "qwen36" })
    state.clear()
    expect(state.isBlocked()).toBe(false)
    expect(state.fallbackSessions().size).toBe(0)
  })

  test("persiste y se recarga desde disco", () => {
    const path = tmpPath()
    const until = Date.now() + 60000
    createZenBlockState(path).block(until)
    const reloaded = createZenBlockState(path)
    expect(reloaded.until()).toBe(until)
  })
})
